# SeedSigner OS — Agent Guidelines

## Deterministic & Reproducible Builds (Non-Dev Configs)

Non-dev builds (`pi0-smartcard`, `pi2-smartcard`, `pi4-smartcard`, etc.) are designed to be **deterministic and reproducible**. This means:

* Every build from the same commit must produce byte-identical output images.
* All external assets (firmware, pre-built OS images, tool archives) are downloaded by URL and verified against a hardcoded SHA-256 checksum.
* Never introduce non-deterministic behaviour into post-image or post-build scripts: no timestamps embedded in files, no random data, no host-dependent paths leaking into the image.
* When adding new downloads to a script, always include both the download step **and** a `sha256sum` verification (use the existing `download_and_verify()` helper where available).
* If a change affects only `-dev` configs, keep it out of non-dev scripts entirely.

## Local Testing of Scripts

Wherever possible, validate script changes locally before pushing to CI. The full buildroot build takes 1–2 hours per board; many failures can be caught in seconds with synthetic test data.

### Post-Image / Post-Build Scripts

These scripts operate on disk images produced by `genimage`. You can reproduce their environment without a full build:

1. **Create a synthetic disk image** matching the genimage layout (MBR + FAT32 partition):
   ```bash
   dd if=/dev/zero of=test.img bs=1M count=256 status=none
   sfdisk test.img <<EOF
   label: dos
   unit: sectors
   test.img1 : start=2048, size=204800, type=c
   EOF
   # Format the partition in-place at the correct offset
   dd if=/dev/zero of=boot.vfat bs=512 count=204800 status=none
   mkfs.vfat -n "SEEDSIGNDEV" boot.vfat >/dev/null 2>&1
   dd if=boot.vfat of=test.img bs=512 seek=2048 conv=notrunc status=none
   ```

2. **Extract the partition offset** from the MBR (byte 454, little-endian uint32):
   ```bash
   python3 -c "import struct; print(struct.unpack('<I', open('test.img','rb').read()[454:458])[0] * 512)"
   # → 1048576 (sector 2048 × 512)
   ```

3. **Run the mtools commands** from the script against the synthetic image and verify they succeed or fail as expected:
   ```bash
   MTOOLS_SKIP_CHECK=1 mmd -i "test.img@@1048576" ::javacard-cap
   MTOOLS_SKIP_CHECK=1 mdir -i "test.img@@1048576" ::/
   ```

4. **Negative tests** are equally important — verify that known-bad syntaxes (`::1`, `:p1`, bare image) fail as expected, so regressions are caught early.

See `tests/test_post_image_mtools.sh` for a working example that exercises all five post-image scripts against a synthetic image in under a second.

### Custom Module Downloads & Hash Checks

When a script downloads external assets:
* Verify the SHA-256 checksum matches what you expect by downloading the file locally first and running `sha256sum`.
* If the upstream changes the hash (e.g., a new release), update the constant in the script — never skip verification.

### Buildroot Post-Build / Post-Install Scripts

These run inside the buildroot container with `$TARGET_DIR`, `$STAGING_DIR`, etc. set. To test locally:
* Set the variables to local paths pointing at a minimal rootfs or empty directory.
* Source the script and step through it, checking that file operations target the right locations.

### General Principles

* **Fail fast**: if a tool is missing (e.g., `mtools`, `sfdisk`), skip with a clear message rather than silently passing.
* **Clean up**: use `trap cleanup EXIT` to remove temp directories on failure.
* **Pin versions**: when tests depend on external tools, note the expected version or behaviour so changes in tooling don't silently break things.
