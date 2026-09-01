#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${DIR}/venv/bin/python"
TOOL="${DIR}/wdpassport-utils.py"
ENV_FILE="${WD_ENV_FILE:-${DIR}/.env}"

red()   { printf '\033[31m[!]\033[0m %s\n' "$*"; }
green() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
info()  { printf '\033[34m[*]\033[0m %s\n' "$*"; }

usage() {
	cat <<EOF
Usage: sudo $0 [mount|umount|status|health]

  mount    unlock the drive and mount its APFS volume (default)
  umount   unmount the volume
  status   show lock and mount state
  health   recover an absent, stale, or read-only mount (for systemd)

Configuration is read from ${ENV_FILE}. Copy .env.example to .env and
fill it in. Set APFS_READONLY=1 to mount read-only.
EOF
}

load_config() {
	if [[ ! -f "$ENV_FILE" ]]; then
		red "No config at ${ENV_FILE}."
		red "Copy .env.example to .env and fill in your drive serial and password."
		exit 1
	fi

	local perms
	perms="$(stat -c '%a' "$ENV_FILE")"
	if [[ "$perms" != "600" ]]; then
		red "${ENV_FILE} is mode ${perms}; it holds your drive password."
		red "Fix it with: chmod 600 ${ENV_FILE}"
		exit 1
	fi

	local ro_override_set=0 ro_override=
	if [[ -n "${APFS_READONLY+x}" ]]; then
		ro_override_set=1
		ro_override="${APFS_READONLY}"
	fi

	set -a
	# shellcheck disable=SC1090
	source "$ENV_FILE"
	set +a

	if ((ro_override_set)); then
		APFS_READONLY="${ro_override}"
	fi

	: "${DRIVE_SERIAL:?DRIVE_SERIAL is not set in ${ENV_FILE}}"
	: "${WDPASSPORT_PASSWORD:?WDPASSPORT_PASSWORD is not set in ${ENV_FILE}}"

	MNT="${MOUNTPOINT:-/mnt/sandisk}"
	DISK_LINK="/dev/disk/by-id/usb-${DRIVE_SERIAL}"
	PART_LINK="${DISK_LINK}-part1"
}

wait_for() {
	local path="$1" i
	for i in $(seq 1 60); do
		[[ -e "$path" ]] && return 0
		sleep 0.25
	done
	return 1
}

is_mounted() { mountpoint -q "$MNT"; }

mounted_source() { findmnt -no SOURCE "$MNT" 2>/dev/null; }

is_readonly_mount() {
	is_mounted || return 1
	local opts
	opts="$(findmnt -no OPTIONS "$MNT" 2>/dev/null || true)"
	[[ ",${opts}," == *",ro,"* ]]
}

show_mount_users() {
	red "Processes or shells keeping ${MNT} busy:"
	fuser -vm "$MNT" 2>&1 | sed 's/^/    /' || true
}

is_stale_mount() {
	is_mounted || return 1
	local src
	src="$(mounted_source)"
	[[ -z "$src" ]] && return 0
	[[ -b "$src" ]] || return 0
	local want
	want="$(readlink -f "$PART_LINK" 2>/dev/null || true)"
	[[ -n "$want" && "$src" != "$want" ]]
}

clear_stale_mount() {
	is_stale_mount || return 1
	red "Stale mount detected: ${MNT} is backed by $(mounted_source), which is gone or replaced."
	red "The drive re-enumerated (usually an unplug, cable glitch, or USB autosuspend)."
	info "Lazily unmounting ${MNT} ..."
	umount -l "$MNT" || { red "Lazy unmount failed. Close anything sitting in ${MNT} and retry."; exit 1; }
	green "Stale mount cleared."
	return 0
}

do_umount() {
	if ! is_mounted; then
		info "Nothing mounted at ${MNT}."
		return 0
	fi
	if is_stale_mount; then
		clear_stale_mount || true
		return 0
	fi
	info "Unmounting ${MNT} ..."
	sync
	if umount "$MNT" 2>/dev/null; then
		green "Unmounted. (Drive stays unlocked until you unplug it.)"
		return 0
	fi

	red "Target is busy."
	show_mount_users
	red "Close those (a terminal sitting in ${MNT} counts), then retry."
	red "Or force it with a lazy unmount: sudo umount -l ${MNT}"
	return 1
}

do_status() {
	if [[ -e "$DISK_LINK" ]]; then
		green "Drive present: $(readlink -f "$DISK_LINK")"
	else
		red "Drive not detected. Is it plugged in?"
		return 1
	fi
	"$PY" "$TOOL" 2>/dev/null | grep -E "Device:|Security status:" || true
	if is_stale_mount; then
		red "STALE mount at ${MNT}: backed by $(mounted_source), which no longer exists."
		red "Reads will fail with EIO. Fix: sudo $0 umount && sudo $0 mount"
	elif is_mounted; then
		if is_readonly_mount; then
			red "Mounted READ-ONLY at ${MNT} (from $(mounted_source))"
			red "The APFS driver forced this after a failed write transaction."
		else
			green "Mounted READ-WRITE at ${MNT} (from $(mounted_source))"
		fi
		df -h "$MNT" | tail -1
	else
		info "Not mounted."
	fi
}

verify_readwrite() {
	local probe token actual
	probe="${MNT}/.apfs-rw-probe-${BASHPID}"
	token="apfs-rw-probe-${BASHPID}-$(date +%s%N)"

	if is_readonly_mount; then
		red "The APFS mount flags changed to READ-ONLY before the write probe."
		return 1
	fi

	info "Verifying a real write and metadata commit ..."
	if ! (
		set -e
		umask 077
		printf '%s\n' "$token" > "$probe"
		sync -f "$probe"
		[[ "$(<"$probe")" == "$token" ]]
		rm -f "$probe"
		sync -f "$MNT"
	); then
		rm -f "$probe" 2>/dev/null || true
		red "APFS write verification failed. The mount is not safely writable."
		return 1
	fi

	actual="$(findmnt -no OPTIONS "$MNT" 2>/dev/null || true)"
	if [[ ",${actual}," == *",ro,"* ]]; then
		red "The APFS driver switched to READ-ONLY during the write probe."
		return 1
	fi
	green "Write, fsync, read-back, delete, and metadata fsync all passed."
}

do_mount() {
	if ! lsmod | grep -q '^apfs '; then
		info "Loading apfs module ..."
		if ! modprobe apfs 2>/dev/null; then
			red "Could not load the apfs module."
			red "Run ./setup-apfs.sh first (build, sign, Secure Boot key enrolment, reboot)."
			exit 1
		fi
	fi
	green "apfs module loaded."

	clear_stale_mount || true
	if is_mounted; then
		local cur
		cur="$(findmnt -no OPTIONS "$MNT" 2>/dev/null || true)"
		if [[ "${APFS_READONLY:-0}" != "1" ]] && [[ ",${cur}," == *",ro,"* || "${cur}" == ro,* ]]; then
			info "Mounted read-only but writes were requested; remounting."
			do_umount || { red "Could not unmount ${MNT} to remount read-write."; exit 1; }
		else
			green "Already mounted at ${MNT}, nothing to do."
			df -h "$MNT" | tail -1
			return 0
		fi
	fi

	if ! wait_for "$DISK_LINK"; then
		red "Drive not detected at ${DISK_LINK}. Is it plugged in?"
		red "Check that DRIVE_SERIAL in ${ENV_FILE} matches: ls /dev/disk/by-id/"
		exit 1
	fi
	green "Drive detected: $(readlink -f "$DISK_LINK")"

	info "Unlocking ..."
	if ! "$PY" "$TOOL" -u; then
		red "Unlock failed. If the password is right, unplug and replug the"
		red "drive to reset the attempt counter, then try again."
		exit 1
	fi

	if ! wait_for "$PART_LINK"; then
		info "Partition not visible yet, re-scanning ..."
		"$PY" "$TOOL" -m || true
		udevadm settle || true
		if ! wait_for "$PART_LINK"; then
			red "Partition ${PART_LINK} never appeared."
			red "Check 'lsblk' - the drive may be unlocked but unpartitioned."
			exit 1
		fi
	fi

	local part opts uid gid attempt
	uid="${SUDO_UID:-0}"
	gid="${SUDO_GID:-0}"
	opts="uid=${uid},gid=${gid}"
	if [[ "${APFS_READONLY:-0}" == "1" ]]; then
		opts="ro,${opts}"
		info "APFS_READONLY=1 set, mounting read-only."
	else
		opts="readwrite,${opts}"
	fi

	mkdir -p "$MNT"
	for attempt in 1 2 3 4 5; do
		udevadm settle || true
		if ! wait_for "$PART_LINK"; then
			sleep 0.5
			continue
		fi
		part="$(readlink -f "$PART_LINK")"
		[[ -b "$part" ]] || { sleep 0.5; continue; }
		green "Partition ready: ${part}"
		info "Mounting ${part} -> ${MNT} (-o ${opts}) ..."
		if mount -t apfs -o "$opts" "$part" "$MNT"; then
			break
		fi
		if ((attempt == 5)); then
			red "Mount failed. Retry read-only to at least get your data:"
			red "  sudo APFS_READONLY=1 $0 mount"
			exit 1
		fi
		info "Mount attempt ${attempt} failed, retrying ..."
		sleep 0.5
	done

	green "Mounted at ${MNT}"
	df -h "$MNT" | tail -1

	if [[ "${APFS_READONLY:-0}" != "1" ]]; then
		sleep 2
	fi

	local actual
	actual="$(findmnt -no OPTIONS "$MNT" 2>/dev/null)"
	if [[ ",${actual}," == *",ro,"* || "${actual}" == ro,* ]]; then
		if [[ "${APFS_READONLY:-0}" == "1" ]]; then
			info "Mounted READ-ONLY as requested (APFS_READONLY=1). Writes will fail."
			info "For writes, re-run without APFS_READONLY=1."
		else
			red "Mounted READ-ONLY even though writes were requested."
			red "Check: sudo dmesg | grep -i apfs"
			exit 1
		fi
	else
		verify_readwrite || exit 1
		green "Mounted READ-WRITE (experimental), with a successful write probe."
	fi
}

do_health() {
	local busy_marker="/run/sandisk-apfs-health.busy"

	# A disconnected drive is normal. The udev rule will run the mount service
	# when it appears, so the periodic health check should stay quiet.
	if [[ ! -e "$DISK_LINK" ]]; then
		rm -f "$busy_marker"
		return 0
	fi
	if [[ "${APFS_READONLY:-0}" == "1" ]]; then
		rm -f "$busy_marker"
		return 0
	fi

	clear_stale_mount || true
	if ! is_mounted; then
		info "Drive is present but not mounted; mounting it read-write."
		do_mount
		return
	fi

	if ! is_readonly_mount; then
		rm -f "$busy_marker"
		return 0
	fi

	red "APFS changed ${MNT} to READ-ONLY after a failed transaction."
	info "Attempting a clean automatic unmount and read-write recovery ..."
	# The failed transaction is already aborted and the filesystem is read-only,
	# so there are no APFS writes to sync here. A normal unmount is required to
	# rebuild the driver's in-memory container state; this driver cannot remount
	# an aborted transaction from ro back to rw in place.
	if ! umount "$MNT" 2>/dev/null; then
		if [[ ! -e "$busy_marker" ]]; then
			red "Automatic recovery is waiting because the mount is busy."
			show_mount_users
			red "The health timer will retry automatically. Close those shells/apps."
			touch "$busy_marker"
		else
			info "Mount is still busy; automatic read-write recovery will retry."
		fi
		return 75
	fi

	rm -f "$busy_marker"
	green "Read-only mount removed; rebuilding a fresh read-write mount."
	do_mount
}

case "${1:-mount}" in
	-h|--help|help) usage; exit 0 ;;
esac

[[ $EUID -eq 0 ]] || { red "Run as root: sudo $0 ${1:-mount}"; exit 1; }
load_config

# Serialize udev, timer, and manual invocations. Two simultaneous unlock/mount
# attempts can otherwise race while the USB disk is re-enumerating.
exec {LOCK_FD}>/run/lock/sandisk-apfs-mount.lock
flock "$LOCK_FD"

case "${1:-mount}" in
	mount)  do_mount  ;;
	umount|unmount) do_umount ;;
	status) do_status ;;
	health) do_health ;;
	*) usage >&2; exit 1 ;;
esac
