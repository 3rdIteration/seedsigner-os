# Luckfox Pico SDK customisation

No patch files live here any more.

The partition layout and the `oem`-partition removal are applied at build time by
[`../../apply-partition-layout.sh`](../../apply-partition-layout.sh) — the single
shared source of truth for the layout, called identically by CI
(`.github/workflows/build-luckfox.yml` via `build.sh`), `os-build.sh` and
`build-local.sh`. Keeping a second copy as an SDK patch caused drift: the two
former patches here (`001-optimize-mini-spi-nand-partitions.patch`,
`002-optimize-max-spi-nand-partitions.patch`) described a layout with no
`userdata` partition and a `20M(oem)`, and were not applied by any build path.

`apply-partition-layout.sh`:
* removes the `oem` element from `RK_PARTITION_CMD_IN_ENV` on all five boards
  (SPI-NAND Mini/Max, SD_CARD Mini/Max, eMMC Pi) and adds its size to the last
  `rootfs` partition;
* removes `oem@/oem@<fstype>` from `RK_PARTITION_FS_TYPE_CFG`;
* sets `RK_BUILD_APP_TO_OEM_PARTITION=n` so the SDK's `build_firmware()` folds the
  (pruned) `oem` tree into the signed rootfs squashfs at `/oem` instead of
  building a separate, unsigned partition;
* hard-fails the build if any table still declares `(oem)`, any fs config still
  mounts `oem@`, `userdata` is missing, `rootfs` is not last, or the fold flag is
  not `n`.

See the header of that script for the full rationale (the 2026-09-23 PoC: an
attacker who can write the unsigned `oem` partition gets root code execution on a
fully fused board), and `../../../docs/luckfox/secure-boot.md`.

Other SDK source edits (determinism, signing hooks, `sdkinfo` timestamp,
stressapptest timestamp) live in `os-build.sh` / `patch-fs-determinism.sh` /
`secure-boot/patch-*.sh`, not here.
