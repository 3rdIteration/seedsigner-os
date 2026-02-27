# boot.cmd — SeedSigner OS La Frite (AML-S805X-AC)
#
# Forces U-Boot to boot via the syslinux bootmeth (extlinux.conf) rather than
# the efi_mgr bootmeth, which reads EFI NVRAM boot variables that may have been
# left behind by a previous experiment.
#
# The `script` bootmeth executes this file before efi_mgr or syslinux are
# tried, so we can explicitly load and boot extlinux.conf from the same
# partition this script is on.
#
# Compile with: mkimage -C none -A arm64 -T script -d boot.cmd boot.scr

setenv boot_targets "mmc usb"
sysboot ${devtype} ${devnum}:${distro_bootpart} any ${scriptaddr} /extlinux/extlinux.conf
