# DIY Tools: Verification & Mount Log

The smartcard profiles ship a `diy-tools.squashfs` on the boot partition containing everything needed
to fabricate and program a Satochip JavaCard at home (Java JDK, Ant, Satochip-DIY source). When a
microSD is inserted, an mdev hook automatically verifies and mounts it at `/mnt/diy`.

## Where the squashfs comes from

The image is built reproducibly by the [`seedsigner-diy-tools`](https://github.com/3rdIteration/seedsigner-diy-tools)
repository and published as a tagged GitHub Release artifact (`diy-tools-<arch>.squashfs`, where `<arch>`
is `armhf` for Raspberry Pi boards or `aarch64` for La Frite). The OS build downloads the pinned release
and verifies it against a hardcoded SHA-256 before placing it on the boot partition.

## Runtime verification (fail-closed)

On every microSD insert, `/etc/mdev/mdev.sh` (source: [`opt/rootfs-overlay/etc/mdev/mdev.sh`](../opt/rootfs-overlay/etc/mdev/mdev.sh)):

1. Mounts the microSD at `/mnt/microsd`.
2. Computes the SHA-256 of `diy-tools.squashfs` **by reading the file directly** (not via a stat/existence
   check — on 32-bit kernels, `stat()` of a FAT file dated after 2038 returns `EOVERFLOW`, which would
   wrongly report the file as missing).
3. Compares it against the pinned hash for this device's architecture in `/etc/diy-tools.sha256`.
4. Mounts the squashfs at `/mnt/diy` **only if the hashes match**. Any other outcome (file absent, hash
   mismatch, missing pin file) refuses to mount — an unverified image is never mounted.

## The log: `/tmp/diy-mount.log`

Every insert/remove appends to `/tmp/diy-mount.log`. Notes for reading it:

- It lives on **tmpfs**, so it is wiped on reboot. A missing file means "no mount events since boot",
  not a failure.
- Human-readable lines are prefixed with a timestamp (e.g. `Thu Aug 27 00:30:11 UTC 2026`).
- Each event ends with one machine-readable result block starting at the marker line
  `=== diy-tools result ===`. The **last complete block** in the file is the current state; earlier
  blocks are history from previous card insertions.
- Block lines are plain `key=value` pairs (no timestamp). Values may contain spaces but never newlines.

### Result fields

| Field | Meaning | Present when |
|---|---|---|
| `status` | One of the statuses below — always present in a complete block | always |
| `reason` | Short human explanation of the outcome | always |
| `arch` | Architecture key used to look up the pinned hash (`armhf` / `aarch64`) | everything except `MICROSD_MOUNT_FAILED` |
| `computed` | SHA-256 of the file actually on the card | whenever the file was readable |
| `pinned` | Expected SHA-256 from `/etc/diy-tools.sha256` | whenever a pinned value exists |
| `detail` | One line of error text (e.g. why the file couldn't be read) | `NOT_PRESENT` only |
| `dev` | The device node that failed to mount | `MICROSD_MOUNT_FAILED` only |
| `mount` | Mount point (`/mnt/diy`) | `OK` only |

### Statuses, in plain English

| status | What happened | What to do about it |
|---|---|---|
| `OK` | Hash matched; squashfs is mounted at `/mnt/diy`. The reason notes it if expected entries (`jdk`, `ant`, `Satochip-DIY`) are missing from inside. | Nothing — DIY tools are available. |
| `REFUSED_HASH_MISMATCH` | A `diy-tools.squashfs` exists on the card but its hash does not match the pinned value, so it was **not** mounted. The block shows both hashes: `computed` (what's on your card) and `pinned` (what this OS expects). Typical causes: a squashfs built for the wrong architecture, a modified/tampered card, or an older image carrying an outdated file. | Re-flash the image, or replace the file with the matching `diy-tools-<arch>.squashfs` from the pinned release of `seedsigner-diy-tools`. Compare `computed` against the release's published hash to see which side is wrong. |
| `NOT_PRESENT` | No readable `diy-tools.squashfs` on the card (`detail` shows the exact read error). | Put a verified squashfs at the root of the boot partition, or re-flash. |
| `HASH_FILE_MISSING` | The OS image itself is missing `/etc/diy-tools.sha256`. This indicates a broken/incomplete image build. | Rebuild/re-flash from a good commit. |
| `NO_PINNED_HASH` | The pin file exists but has no entry for this device's architecture. | Image/build mismatch — rebuild or re-flash. |
| `MOUNT_FAILED` | Hash verified fine, but mounting the squashfs failed (e.g. kernel lacks the needed squashfs compression support). | Check the kernel config (`CONFIG_SQUASHFS_*`) for the board; report if unexpected. |
| `MICROSD_MOUNT_FAILED` | The microSD partition itself could not be mounted at all (`dev` shows which node). | Check the card/partition (FAT32, boot partition) and try another card. |

## Examples

**Success:**

```
Thu Aug 27 00:30:11 UTC 2026 ADD /dev/mmcblk1p1: mounting microsd
=== diy-tools result ===
status=OK
reason=diy-tools verified and mounted at /mnt/diy
arch=armhf
computed=22e289c2caa58ed4d460735b03155a57537fa7e29b354ca4fc72a508fe3bdff8
pinned=22e289c2caa58ed4d460735b03155a57537fa7e29b354ca4fc72a508fe3bdff8
mount=/mnt/diy
```

**Hash mismatch — the file on the card is not the verified one:**

```
Thu Aug 27 01:02:44 UTC 2026 ADD /dev/mmcblk1p1: mounting microsd
=== diy-tools result ===
status=REFUSED_HASH_MISMATCH
reason=diy-tools.squashfs hash does not match the pinned value; refusing to mount an unverified image
arch=armhf
computed=deadbeef0000c0ffee...
pinned=22e289c2caa58ed4d460735b03155a57537fa7e29b354ca4fc72a508fe3bdff8
```

**Multiple events — the last block is the current state** (card removed, re-inserted without the file):

```
Thu Aug 27 00:30:11 UTC 2026 ADD /dev/mmcblk1p1: mounting microsd
=== diy-tools result ===
status=OK
reason=diy-tools verified and mounted at /mnt/diy
arch=armhf
computed=22e289c2caa58ed4d460735b03155a57537fa7e29b354ca4fc72a508fe3bdff8
pinned=22e289c2caa58ed4d460735b03155a57537fa7e29b354ca4fc72a508fe3bdff8
mount=/mnt/diy
Thu Aug 27 00:45:02 UTC 2026 REMOVE /dev/mmcblk1p1: unmounting
Thu Aug 27 00:45:30 UTC 2026 ADD /dev/mmcblk1p1: mounting microsd
=== diy-tools result ===
status=NOT_PRESENT
reason=no readable diy-tools.squashfs on microSD
arch=armhf
detail=sha256sum: can't open '/mnt/microsd/diy-tools.squashfs': No such file or directory
```

## Viewing the log

- **Dev builds** (SSH enabled): `cat /tmp/diy-mount.log` over SSH.
- **Non-dev builds** are headless and air-gapped; the SeedSigner application reads this file itself to
  report the DIY-tools status in the UI, so no shell access is needed.
