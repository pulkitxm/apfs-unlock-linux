#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${DIR}/systemd"
ENV_FILE="${WD_ENV_FILE:-${DIR}/.env}"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

if [[ ! -f "$ENV_FILE" ]]; then
	echo "No config at ${ENV_FILE}. Copy .env.example to .env first." >&2
	exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${DRIVE_SERIAL:?DRIVE_SERIAL is not set in ${ENV_FILE}}"

TARGET_UID="${SUDO_UID:-$(stat -c '%u' "$DIR")}"
TARGET_GID="${SUDO_GID:-$(stat -c '%g' "$DIR")}"

render() {
	sed -e "s|@DIR@|${DIR}|g" \
	    -e "s|@UID@|${TARGET_UID}|g" \
	    -e "s|@GID@|${TARGET_GID}|g" \
	    -e "s|@SERIAL@|${DRIVE_SERIAL}|g" \
	    "$1"
}

render "${SRC}/sandisk-apfs-mount.service.in" > /etc/systemd/system/sandisk-apfs-mount.service
render "${SRC}/99-sandisk-apfs.rules.in" > /etc/udev/rules.d/99-sandisk-apfs.rules
chmod 0644 /etc/systemd/system/sandisk-apfs-mount.service /etc/udev/rules.d/99-sandisk-apfs.rules

systemctl daemon-reload
udevadm control --reload-rules
udevadm trigger --subsystem-match=block --action=add

echo "Installed for uid ${TARGET_UID}, serial ${DRIVE_SERIAL}."
echo "Watch it with: journalctl -u sandisk-apfs-mount.service -f"
