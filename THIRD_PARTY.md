# Third-party code

## wdpassport-utils.py

Vendored and modified. Upstream: https://github.com/0-duke/wdpassport-utils,
licensed GPL-2.0. The copy here is byte-identical to upstream at the time of
vendoring apart from the changes below.

Modifications:

- Read the password from the `WDPASSPORT_PASSWORD` environment variable when
  set, falling back to the interactive prompt. Needed for unattended use from
  systemd.
- Exit non-zero when unlocking fails, instead of swallowing the error, so the
  calling script can detect it.
- Skip optical devices when enumerating. The SanDisk Extreme Pro exposes a
  virtual CD (the bundled unlocker) under the same USB parent as the real disk.
- Match `SanDisk_Extreme` serials in addition to `Western_Digital_My_`.
- Stop at the first matching parent so a single disk is not enumerated twice.

## linux-apfs-rw

Not vendored. `setup-apfs.sh` clones it at a pinned tag from
https://github.com/linux-apfs/linux-apfs-rw, licensed GPL-2.0.

## py_sg

Not vendored. Installed from https://github.com/crypto-universe/py_sg via
`requirements.txt`.
