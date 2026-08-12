# apfs-unlock-linux

Unlock a hardware-encrypted SanDisk Extreme Pro (or WD My Passport) on Linux
and mount its APFS volume, optionally automatically on plug-in.

Two things have to happen before a macOS-formatted, hardware-locked drive is
readable on Linux:

1. The drive is locked at the firmware level. Until it is sent the right SCSI
   unlock command, the real partition does not even appear as a block device.
2. The volume is APFS, which mainline Linux cannot read. That needs an
   out-of-tree kernel module, which under Secure Boot must be signed with a key
   enrolled in your firmware.

`setup-apfs.sh` handles both, once. After that `apfs-mount.sh` is all you need.

## Warning

APFS write support in the driver is experimental. `apfs-mount.sh` mounts
read-write by default because that is usually what you want, but do not trust
it with data you have not backed up. Set `APFS_READONLY=1` for a read-only
mount, which is the safe choice.

## Requirements

Ubuntu or Debian, Secure Boot optional:

```
sudo apt install git build-essential openssl mokutil python3-venv \
                 linux-headers-$(uname -r)
```

## Setup

```
git clone https://github.com/pulkitxm/apfs-unlock-linux.git
cd apfs-unlock-linux
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set:

- `DRIVE_SERIAL` — find it with `ls /dev/disk/by-id/`. Take the name of your
  drive's entry and drop the leading `usb-`. For example
  `usb-SanDisk_Extreme_Pro_1234_ABCDEF-0:0` means
  `DRIVE_SERIAL=SanDisk_Extreme_Pro_1234_ABCDEF-0:0`.
- `WDPASSPORT_PASSWORD` — the drive's unlock password.
- `MOUNTPOINT` — defaults to `/mnt/sandisk`.

`.env` holds your drive password in plaintext. It is gitignored, and
`apfs-mount.sh` refuses to run unless it is mode 600.

Then:

```
sudo ./setup-apfs.sh
```

This creates the virtualenv, clones and builds the APFS driver, generates a
signing key under `mok/` if there is none, signs the module when Secure Boot is
enabled, and installs it.

If Secure Boot is on and the key is not yet enrolled, the script queues it with
`mokutil` and prints what to do. **The easy step to miss:** on the next boot,
right after the vendor logo and before the distro splash, a black screen offers
*"Press any key to perform MOK management"* for about ten seconds. Miss it and
the pending key is silently discarded and you have to re-run the script.

## Usage

```
sudo ./apfs-mount.sh mount     # unlock and mount (default)
sudo ./apfs-mount.sh umount    # unmount
sudo ./apfs-mount.sh status    # show lock and mount state
```

`mount` is idempotent. It also detects a *stale* mount, where the drive
re-enumerated after an unplug or USB autosuspend and the old mount still looks
mounted to the kernel while every read returns `EIO`, and clears it before
remounting.

The drive stays unlocked until it is physically unplugged, so unmounting does
not re-lock it.

## Mount on plug-in

```
sudo ./install-autorun.sh
```

Renders a udev rule and a systemd unit from your `.env` and the repo's actual
path, so plugging the drive in unlocks and mounts it automatically.

```
journalctl -u sandisk-apfs-mount.service -f
```

To remove it:

```
sudo rm /etc/udev/rules.d/99-sandisk-apfs.rules \
        /etc/systemd/system/sandisk-apfs-mount.service
sudo systemctl daemon-reload && sudo udevadm control --reload-rules
```

## Troubleshooting

**Unlock fails with the right password.** The drive has a failed-attempt
counter. Unplug it, plug it back in, try again.

**Mounted read-only when you asked for read-write.** The driver refused. Check
`sudo dmesg | grep -i apfs`.

**Module will not load after a kernel upgrade.** The module is built against
one kernel version. Re-run `sudo ./setup-apfs.sh`. The enrolled key persists,
so no second reboot dance.

**Drive not detected.** Confirm `DRIVE_SERIAL` matches an entry in
`/dev/disk/by-id/`.

## Pinning the driver version

`setup-apfs.sh` checks out tag `v0.3.20` by default. Override with
`APFS_VERSION=v0.3.21 sudo -E ./setup-apfs.sh`.

## Licensing

GPL-2.0, inherited from the vendored `wdpassport-utils.py`. See
[THIRD_PARTY.md](THIRD_PARTY.md) for what is vendored, what is fetched at setup
time, and what was modified.

Not affiliated with SanDisk, Western Digital, or Apple.
