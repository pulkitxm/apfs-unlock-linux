#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER="$(uname -r)"
MODDIR="/lib/modules/${KVER}/extra"
SRCDIR="${DIR}/linux-apfs-rw"
MOKDIR="${DIR}/mok"
VENV="${DIR}/venv"

APFS_REPO="${APFS_REPO:-https://github.com/linux-apfs/linux-apfs-rw.git}"
APFS_VERSION="${APFS_VERSION:-v0.3.21}"
SIGN_FILE="/usr/src/linux-headers-${KVER}/scripts/sign-file"

if [[ $EUID -ne 0 ]]; then
	echo "Run as root: sudo $0" >&2
	exit 1
fi

RUN_UID="${SUDO_UID:-$(stat -c '%u' "$DIR")}"
RUN_GID="${SUDO_GID:-$(stat -c '%g' "$DIR")}"
as_user() { setpriv --reuid "$RUN_UID" --regid "$RUN_GID" --clear-groups "$@"; }

echo "==> Checking build dependencies"
missing=()
for c in git make gcc openssl mokutil; do
	command -v "$c" >/dev/null || missing+=("$c")
done
[[ -d "/lib/modules/${KVER}/build" ]] || missing+=("linux-headers-${KVER}")
if ((${#missing[@]})); then
	echo "Missing: ${missing[*]}" >&2
	echo "Install them, e.g.: sudo apt install git build-essential openssl mokutil linux-headers-${KVER}" >&2
	exit 1
fi

echo "==> Setting up the Python environment"
if [[ ! -x "${VENV}/bin/python" ]]; then
	as_user python3 -m venv "$VENV"
fi
as_user "${VENV}/bin/pip" install --quiet --upgrade pip
as_user "${VENV}/bin/pip" install --quiet -r "${DIR}/requirements.txt"

echo "==> Fetching the APFS driver (${APFS_VERSION})"
if [[ ! -d "${SRCDIR}/.git" ]]; then
	as_user git clone --quiet "$APFS_REPO" "$SRCDIR"
fi
as_user git -C "$SRCDIR" fetch --quiet --tags
as_user git -C "$SRCDIR" checkout --quiet "$APFS_VERSION"
as_user git -C "$SRCDIR" reset --hard --quiet "$APFS_VERSION"
as_user git -C "$SRCDIR" clean -fdq
shopt -s nullglob
for patch in "${DIR}/patches/"*.patch; do
	echo "    Applying $(basename "$patch")"
	as_user git -C "$SRCDIR" apply --whitespace=nowarn "$patch"
done
shopt -u nullglob

echo "==> Building apfs.ko"
as_user make -C "$SRCDIR" -j"$(nproc)"

if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
	echo "==> Secure Boot is on, signing the module"
	if [[ ! -f "${MOKDIR}/MOK.priv" ]]; then
		echo "    Generating a signing key in ${MOKDIR}"
		install -d -m 0700 -o "$RUN_UID" -g "$RUN_GID" "$MOKDIR"
		as_user openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
			-subj "/CN=$(hostname) APFS module signing key/" \
			-outform DER -out "${MOKDIR}/MOK.der" -keyout "${MOKDIR}/MOK.priv" 2>/dev/null
		chmod 600 "${MOKDIR}/MOK.priv"
	fi
	"$SIGN_FILE" sha256 "${MOKDIR}/MOK.priv" "${MOKDIR}/MOK.der" "${SRCDIR}/apfs.ko"
fi

echo "==> Installing apfs.ko into ${MODDIR}"
install -d "${MODDIR}"
install -m 0644 "${SRCDIR}/apfs.ko" "${MODDIR}/apfs.ko"
DKMS_DIR="/lib/modules/${KVER}/updates/dkms"
if [[ -d "$DKMS_DIR" ]]; then
	echo "==> Also installing over DKMS module at ${DKMS_DIR}"
	install -m 0644 "${SRCDIR}/apfs.ko" "${DKMS_DIR}/apfs.ko"
	if command -v zstd >/dev/null && [[ -f "${DKMS_DIR}/apfs.ko.zst" || ! -f "${DKMS_DIR}/apfs.ko" ]]; then
		zstd -f -q -o "${DKMS_DIR}/apfs.ko.zst" "${DKMS_DIR}/apfs.ko"
		rm -f "${DKMS_DIR}/apfs.ko"
	fi
fi
depmod -a "${KVER}"

if mountpoint -q /mnt/sandisk 2>/dev/null; then
	echo "==> /mnt/sandisk is mounted; unload skipped. Remount after: sudo ./apfs-mount.sh umount && sudo rmmod apfs && sudo modprobe apfs && sudo ./apfs-mount.sh mount"
elif lsmod | grep -q '^apfs '; then
	rmmod apfs 2>/dev/null || true
fi

if modprobe apfs 2>/dev/null; then
	echo "==> apfs module loaded successfully. Setup complete, no reboot needed."
	exit 0
fi

echo
echo "==> The module could not load, which is expected if the signing key is"
echo "    not yet enrolled with Secure Boot."
echo
echo "    You will now be asked to create a ONE-TIME password. It is used only"
echo "    at the blue MOK Manager screen during the next boot, and is unrelated"
echo "    to your login or drive password. Pick something simple; you type it"
echo "    once and never need it again."
echo
mokutil --import "${MOKDIR}/MOK.der"

cat <<'EOF'

==> Key queued for enrolment. Next steps:

    1. Reboot.

    2. *** THE EASY STEP TO MISS ***
       Right after the vendor logo, BEFORE the Ubuntu splash, a black
       screen says:

           Press any key to perform MOK management

       You get about 10 SECONDS. If you do not press a key, the machine
       boots normally AND DISCARDS the pending key. Watch for it and
       press a key immediately.

    3. The blue "MOK Management" menu then appears:
         Enroll MOK  ->  Continue  ->  Yes  ->  one-time password  ->  Reboot

    4. Run: sudo ./apfs-mount.sh mount

    If it did not work, the key was silently discarded. Re-run this
    script to queue it again.
EOF
