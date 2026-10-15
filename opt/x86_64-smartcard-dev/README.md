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
- **Hybrid BIOS+EFI bootable USB image, running from RAM.** One FAT32 ESP
  (the only partition) carries `/bzImage`, `/rootfs.cpio.gz`,
  `EFI/BOOT/{bootx64.efi,bootia32.efi,grub.cfg}` and `boot/grub/grub.cfg`;
  the MBR gap carries grub's i386-pc core. grub loads the whole rootfs as an
  initrd that is unpacked into RAM, the same "run from RAM" model as the Pi
  and La Frite images, so **the USB stick can be removed once the app is
  up**. Unlike those profiles the cpio is a separate initrd rather than
  embedded in the kernel, which keeps a rootfs of several hundred MB (X11,
  OpenCV, numpy) out of bzImage. The ESP is sized at build time from the
  payload.
- **Display.** The screen stays at its native resolution for compatibility
  (no `video=` override). `xinitrc-seedsigner` sets
  `SEEDSIGNER_DESKTOP_FULLSCREEN=1` as the hook for the app to scale its
  fixed 960×480 desktop layout (240×240 LCD plus button panels) to fill
  the screen. Scaling is app-side work in the seedsigner repo; until an app
  ref honours the variable, the UI is a 960×480 window on the native-
  resolution screen.
- **Card handling.** Before mounting, the udev wrapper runs `fsck.fat -a`
  on FAT cards, which clears the "not properly unmounted" dirty bit every
  reboot leaves. It also lazily unmounts a dead mount left by a yanked
  card, and on removal it only unmounts `/mnt/microsd` if the removed device
  is the one mounted there. Pulling the boot stick never takes the card
  away.
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

## Debug boot log (dev builds only)

For machines with no usable serial port or network: create an empty file
named `seedsigner-bootlog.txt` in the root of the `SEEDSIGNOS` FAT partition
from any PC and boot. The launcher mounts that partition read-write and
appends to `seedsigner-boot.log` on it — full dmesg, the live kernel ring,
launcher output, the SeedSigner app's stdout/stderr — plus a copy of
`/var/log/Xorg.0.log` as `seedsigner-xorg.log` whenever the X session exits,
and a `--- storage at app start ---` block (card mount, settings.json,
fsck/mount logs) just before the app launches
(the key artifact for a black-screen failure). The log survives a hard
power-cut (flushed FAT + a periodic sync). Delete the marker file to turn it
off; nothing is logged when it is absent. This mechanism lives entirely in
this dev profile's board overlay — release profiles never carry it.

## Dev scope caveats

- Dev build only (dropbear/SSH, verbose console). A hardened `x86_64-
  smartcard` release profile and a burnable hybrid ISO come later; until
  then treat this image as a bench tool, not a production air-gap.
- Kernel modules autoload via eudev; exotic GPU/Wi-Fi firmware may need
  `linux-firmware` options added.
- `busybox mount` may not probe exotic filesystems on inserted cards (exfat
  is built into the kernel; very new fs types are out of scope).
