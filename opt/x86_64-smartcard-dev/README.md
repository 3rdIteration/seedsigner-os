# x86_64-smartcard-dev

SeedSigner OS for generic x86_64 PCs and laptops: the app runs in its
desktop mode (pygame display + keyboard/mouse, requirements-desktop.txt
semantics) on a minimal X11 stack, capturing QR codes from a USB/UVC webcam
and talking to CCID smartcard readers over USB.

## What makes this different from the Pi / La Frite profiles

- **Desktop UI instead of SPI LCD + GPIO.** `python-periphery` /
  `python-spidev` are deliberately *absent* so `hardware/buttons.py` and the
  display factory fall back to the pygame code path, and
  `Settings.RUNTIME_PROFILE` resolves to `desktop` (no `io_config.json`
  device-model match).
- **X11 + eudev.** The X server and its libinput driver require udev, so
  `/dev` management is eudev (shared overlay's `S00mdev` is removed in
  post-build); `xinit` starts X around the app.
- **Hotplug storage via udev rules.** `etc/udev/rules.d/99-seedsigner-storage.rules`
  feeds `sd[a-z][0-9]` add/remove events through
  `/usr/lib/udev/seedsigner-storage.sh` into the shared
  `/etc/mdev/mdev.sh` helper (mount at `/mnt/microsd`, `noexec,nosuid,nodev`,
  `/tmp/mdev_fifo` notification), with `SS_SKIP_DIY=1` since x86_64 has no
  pinned diy-tools squashfs.
- **Hybrid BIOS+EFI bootable USB image.** One FAT32 ESP carries `/bzImage`,
  `EFI/BOOT/{bootx64.efi,bootia32.efi,grub.cfg}` and `boot/grub/grub.cfg`;
  the MBR gap carries grub's i386-pc core. Root is ext4 found via
  `root=PARTUUID=ba5eba11-02` (MBR disk signature pinned after genimage)
  because the stick enumerates as `sda`/`sdb`/`sdc` depending on the
  machine's own disks — and because a kernel with no initramfs cannot
  resolve a filesystem `root=UUID=` at all (`early_lookup_bdev` parses only
  `PARTUUID=`/`PARTLABEL=`/`/dev/...`/major:minor; a real device failed to
  boot with "Disabling rootwait; root= is invalid" before this was fixed).
- **Console launcher.** post-build.sh replaces the getty respawn line with
  `/usr/bin/seedsigner-console` (wait for storage, dev-source override,
  clock priming, `startx`), replacing `S02seedsigner`.

## Building

```sh
# from the repo root, matching the other profiles' Docker flow
SS_ARGS="--x86_64 --smartcard --dev" docker compose up
# or CI: workflow_dispatch with board=x86_64, variant=dev
```

Result: `images/seedsigner_os.<branch>.x86_64-smartcard-dev.img` — `dd` to a
USB stick; boots on legacy BIOS, x86_64 EFI, and 32-bit EFI machines.

## Dev scope caveats

- Dev build only (dropbear/SSH, verbose console). A hardened `x86_64-
  smartcard` release profile and a burnable hybrid ISO come later; until
  then treat this image as a bench tool, not a production air-gap.
- Kernel modules autoload via eudev; exotic GPU/Wi-Fi firmware may need
  `linux-firmware` options added.
- `busybox mount` may not probe exotic filesystems on inserted cards (exfat
  is built into the kernel; very new fs types are out of scope).
