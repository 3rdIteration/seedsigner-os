# Reproducible Builds

SeedSigner OS non-dev (production) images are **deterministic and reproducible**: building the same repo
commit in the same build container produces byte-identical output artifacts, on any machine. This page
documents what that guarantee covers, how each hardware platform achieves it, and how to verify it when
something regresses.

Dev profiles (`*-dev`) are explicitly *not* reproducible — they use `genimage`, which embeds build-time
metadata — so nothing on this page applies to them.

## What the guarantee does (and doesn't) cover

**Covered:**

- Same repo commit + same Docker image → byte-identical images and bundles, across machines and host OSes
  (WSL2/Ubuntu/macOS/Linux hosts, CI runners).
- Every external asset is downloaded by URL and verified against a hardcoded SHA-256 checksum before use.

**Not covered (expected differences, not bugs):**

- Different repo commits or different app refs (`--seedsigner-ref` / `seedsigner_branch`) — the image embeds
  the app's commit.
- A changed Dockerfile/build container — reproducibility is only claimed within one image version; re-verify
  with a double build after any Dockerfile change.

## Common principles

1. **Pin time.** `SOURCE_DATE_EPOCH` (default `0`) is exported for the whole build and used by every tool that
   records a timestamp; kernel builds additionally get `KBUILD_BUILD_TIMESTAMP=@$EPOCH`.
2. **No host state in images.** No timestamps, random data, hostnames, unames, build paths, `$USER`, CPU
   counts or locales may leak into an image. When a third-party tool embeds build metadata, patch it out or
   make the build fail loudly (see the OpenCV example under La Frite).
3. **Hash-pin every download** (`download_and_verify()` / `sha256sum -c`). If upstream changes a hash, update
   the constant — never skip verification.
4. **Single-threaded compression where tools are non-deterministic.** Parallel xz and fragment packing in old
   squashfs-tools leak uninitialised memory into the compressed stream; force `-processors 1 -no-fragments`.
5. **Fail loudly, never silently no-op.** Every sed/awk patch is followed by a grep check that the expected
   marker landed; if it didn't, the build fails.

## Raspberry Pi profiles (pi0 / pi02w / pi2 / pi4 smartcard)

Buildroot over the `opt/buildroot` submodule; non-dev images are assembled manually in each profile's
`post-image-seedsigner.sh`:

| Mechanism | Detail |
|---|---|
| Buildroot reproducibility | `BR2_REPRODUCIBLE=y` in every non-dev defconfig; `SOURCE_DATE_EPOCH=0` exported by `opt/build.sh` |
| Python bytecode | compiled in post-build with `SOURCE_DATE_EPOCH=1 PYTHONHASHSEED=0`; a handful of stdlib `.pyc`s and `cryptography`'s dist-info `RECORD` are deleted because they embed build paths/times nondeterministically |
| Disk layout | `dd` + `sfdisk` with fixed label-id `ba5eba11`; FAT32 via `mkfs.vfat --invariant -i ba5eba11 -n SEEDSIGNROS` (no random volume ID, no timestamp) |
| File timestamps | every boot file is `touch`ed to the fixed `disk_timestamp="2023/01/01T12:15:05"` before `mcopy`; directories are copied with sorted shell globs because mcopy's directory recursion isn't deterministic |
| External assets | rpi-firmware, Zulu JDK 8, Apache Ant and the Satochip-DIY source (pinned to commit `b8f1334b…`) all downloaded via `download_and_verify()` / `verify_git_head()`; the four prebuilt 0.8.6 microSD images are SHA-256-pinned |
| Output metadata | final image and any debug rootfs tarball get a fixed mtime (`2025-07-01`); the tarball uses `tar --sort=name --owner=root:0 --group=root:0 --mtime=…` |

## La Frite (lafrite-smartcard)

Same Buildroot base as the Pi profiles, with two platform-specific notes:

- **The rootfs is an initramfs** (`BR2_TARGET_ROOTFS_INITRAMFS=y`, cpio-gzip linked into the kernel `Image`).
  There is no separate rootfs filesystem — which is also why [`tools/imgdiff.py`](../tools/imgdiff.py) can reach
  every rootfs file without a rebuild or debug tarball.
- **OpenCV host-uname leak (fixed 2026-08-22).** OpenCV compiles a build-information block
  (`Host: Linux <uname -r> x86_64`) into `libopencv_core.so`, and Docker does not isolate the host kernel — so
  a WSL2 laptop and an Azure runner produced different images. The fix in
  [`opt/external-packages/opencv4-config/opencv4-config.mk`](../opt/external-packages/opencv4-config/opencv4-config.mk)
  strips the line and **fails the build loudly** if upstream OpenCV moves it, rather than silently regressing.
  When adding a package that embeds build metadata, check for the same class of leak: host uname, hostname,
  build path, timestamp, `$USER`, CPU count, locale.

## Luckfox Pico (Mini / Pro Max / Pico Pi)

The Rockchip SDK leaks host state in ways Buildroot never does, so the pins live in shared `opt/luckfox/*.sh`
scripts that all three build paths — CI (`build-luckfox.yml`), local Docker (`os-build.sh`) and legacy
`build-local.sh` — run identically. **Change the script, never one caller.**

**Prerequisite:** CI and local must use the same Docker image (`opt/luckfox/Dockerfile`). Reproducibility is
only claimed for builds from the same repo commit *and* the same image; a Dockerfile change invalidates prior
hashes until re-verified with a double build.

**Not a leak, deliberately:** `/etc/seedsigner-build-time` is a real date baked into the image — the default
the boot clock is set from, because the RV1106 has no RTC. It comes from the **pinned app commit's** committer
date (`git log -1 --format=%ct`, the same expression `opt/build.sh` uses for the Pi), never from the build's
wall clock, so the same OS commit and the same `--seedsigner-ref` still produce the same byte. It must never
be switched to `SOURCE_DATE_EPOCH`, which is `0`: that would ship a device whose clock reads 1970, stamping
every generated GPG key with a bogus creation date. `opt/luckfox/install-build-time.sh` enforces a year floor
of 2020 so that edit fails the build instead.

### The pins

| # | Leak | Pin | Where |
|---|---|---|---|
| 1 | Host time in every tool that calls `date`/`time(NULL)` | `SOURCE_DATE_EPOCH=0` (default) + `KBUILD_BUILD_TIMESTAMP=@$EPOCH` exported for the whole build | `os-build.sh` env block |
| 2 | ASLR: SDK image tools write uninitialised host memory into FIT `/memreserve/` of uboot.img/boot.img | every SDK stage runs under `setarch $(uname -m) -R` (ASLR off → leaked pointers constant; zeroing the entries would alter image semantics, so the leak is made *constant* instead) | `sdk_build()` in os-build.sh |
| 3 | sdkinfo "Build Time" = build date | sed on the SDK's project/build.sh pins it to `$EPOCH` | os-build.sh |
| 4 | stressapptest embeds `user @ host on $(date)` at configure time | sibling sed (the SDK already seds this pre-generated `configure` for an armv7a fix) pins the timestamp; hostname is fixed by the earlier `--hostname seedsigner-build` | os-build.sh |
| 5 | ubinize bakes a random `image_seq` into every UBI erase-counter header (+ its CRC) | `-Q $EPOCH` injected into mkfs_ubi.sh's echoed fakeroot call | patch-fs-determinism.sh §1 |
| 6 | mksquashfs 4.3-git records source mtimes + superblock `mkfs_time`; multi-threaded xz and fragment packing are non-deterministic (uninitialised tail bytes reach the xz stream) | wrapper normalises all source mtimes to `$EPOCH` before packing, overwrites the superblock time after; `-processors 1 -no-fragments` forced in both mkfs_squashfs.sh and mkfs_ubi.sh's embedded call (time flags are probed first — a future squashfs ≥4.4 gets `-all-time/-mkfs-time`) | patch-fs-determinism.sh §2–§4, ss-fs-normalise.sh `mtimes`/`sqfs-time` |
| 7 | mkfs.ubifs bakes a random UUID into the superblock node and atime/ctime/mtime from stat() into every inode node (ctime can't be touched with touch) | `ss-fs-normalise.sh ubifs` walks each volume node-by-node (magic+len+type+CRC validated), zeroes the uuid, sets times to `$EPOCH`, recomputes mtd_crc32 per touched node; injected right after mkfs.ubifs in mkfs_ubi.sh | patch-fs-determinism.sh §5 |
| 8 | **mkfs.ubifs numbers inodes in `readdir()` order** — host-filesystem-dependent (ext4 vs overlayfs vs tmpfs), so identical trees get different inode numbering → different keys, node layout, sqnums and LPT entries | deterministic rebuild of the SDK's mtd-utils 2.0.1 mkfs.ubifs with `sort-dirents.patch` (`add_directory()` collects + qsorts dirents by name); built to `$LUCKFOX_DIR/output/ss-tools/mkfs.ubifs` and forced on mkfs_ubi.sh via a `MKUBIFS_TOOL=` override (the PATH lookup would pick the SDK's prebuilt static copy) | opt/luckfox/mkfs-ubifs-determinism/, patch-fs-determinism.sh §6 |
| 9 | LDR/RKFW clock stamps: prebuilt boot_merger/rkImageMaker stamp localtime into download.bin/update.img headers + trailer checksum (CRC-32 poly `0x04C10DB7` / MD5 hex) | `ss-fs-normalise.sh bootimg` pins releaseTime to `$EPOCH` and recomputes the trailer, magic-gated; normalise download.bin FIRST, re-run mk-update-pack.sh (update.img embeds a verbatim copy of download.bin), then pin update.img | os-build.sh / build-local.sh after `build.sh firmware` |
| 10 | Provenance: git origin URL differs per clone (trailing slash, `.git`) and leaks into `/etc/seedsigner-os-release` | REPO canonicalised to exactly `https://github.com/<owner>/<repo>`; BRANCH/COMMIT/DATE expressions match what CI records | build.sh + build-local.sh |
| 11 | Bundle tarballs: entry order, mtimes, uid/gid, gzip header timestamp | `ss_tar_deterministic()` — `tar --sort=name --mtime=@$EPOCH --owner=root:0 --group=root:0 --numeric-owner --format=gnu \| gzip -n`, output touched to `$EPOCH` | os-build.sh |
| 12 | `pip install fonttools` was unpinned, and `pyftsubset`'s GPOS output is not stable across releases (4.63.0 vs 4.64.0: JP +532, KR +538, SC +550 bytes, with byte-identical glyf/cmap/GSUB/hmtx) — the changed `head` checkSumAdjustment then cascades into rootfs.img, update.img and the SD images | `fonttools==4.64.0` pinned in both call sites; the venv's `pyftsubset` is invoked by absolute path and its `fontTools.version` verified against the pin first, so a host copy on `PATH` can never silently subset at another version | opt/luckfox/compile-translations.sh, opt/build.sh |
| 13 | **The reused app checkout carried the last build's output.** Local builds keep `seedsigner` in the persistent `seedsigner-repos` Docker volume; prepare-app-checkout.sh reused it whenever HEAD matched the requested ref, which proves the right *commit* but says nothing about the working tree. The build mutates that tree (compiles .mo, slims fonts in the translations submodule), and re-subsetting an already-subset font is a **fixed point** — pyftsubset cannot re-expand a pruned GPOS — so whichever fonttools version first slimmed them stayed frozen into every later local build. CI never sees it: each job clones fresh | every reuse path now runs `restore_pristine()` (`reset --hard` + `clean -fdx`, submodules first — the superproject clean deliberately skips directories containing a `.git`) before handing the tree to the build | opt/luckfox/prepare-app-checkout.sh |

### The deterministic mkfs.ubifs toolchain (pin 8)

The last and most subtle Luckfox leak: stock `mkfs.ubifs` assigns inode numbers in the order `readdir()`
returns directory entries, which depends on the *host file system* (ext4 vs overlayfs vs tmpfs), not on the
tree's contents. Two builds of an identical `/oem` tree on different machines therefore got different inode
numbering — and with it different INO/DATA/DENT keys, physical node layout, sqnums and LPT entries — even
though every file's content was byte-identical. A post-pass normalisation (pin 7) cannot fix this, because the
*layout itself* differs; the traversal order has to be made deterministic inside mkfs.ubifs.

The fix (`opt/luckfox/mkfs-ubifs-determinism/`, applied by `patch-fs-determinism.sh` §6):

1. Rebuild the SDK's mtd-utils 2.0.1 `mkfs.ubifs` from source with `sort-dirents.patch`: `add_directory()`
   collects all dirents first and processes them in strcmp-sorted name order, so traversal — and everything
   downstream of it — is a pure function of the tree's contents.
2. The SDK ships mtd-utils as a git-tracked tarball that its own tools build extracts *after* this step runs;
   on a pristine checkout the script unpacks the tarball into a temp dir instead (the checkout is never
   modified).
3. lzo/uuid headers are vendored next to the script with SHA-256 pins (the build image carries only runtime
   `.so` files, no dev headers); linking is dynamic against the image's own `liblzo2.so.2` / `libuuid.so.1` /
   zlib so the tool runs in exactly the environment that produces the images.
4. The result lands at `$LUCKFOX_DIR/output/ss-tools/mkfs.ubifs` and is forced on `mkfs_ubi.sh` via a
   `MKUBIFS_TOOL=` override — the PATH-based lookup would otherwise pick up the SDK's prebuilt static copy.

### Provenance (pin 10)

The image records where it came from in `/etc/seedsigner-os-release`. The git origin URL differs per clone
(trailing slash, `.git` suffix), so both local build scripts canonicalise REPO to exactly
`https://github.com/<owner>/<repo>` and use the same BRANCH/COMMIT/DATE expressions CI records — otherwise a
clone with a trailing-slash remote would never match CI.

## Verifying reproducibility

### Pi / La Frite: diff, don't rebuild

When two builds of the same commit disagree, run [`tools/imgdiff.py`](../tools/imgdiff.py)
(`python3 tools/imgdiff.py local.img ci.img`). It narrows "the hashes differ" down to the individual file — and
for ELF binaries down to the individual embedded string. Stdlib only; runs on Windows. See
[docs/agents.md](agents.md#verifying-reproducibility) for how to read its output, in particular that differences
**cascade**: the innermost file whose *content* changed is the root cause, everything downstream is shifted
offsets.

### Luckfox: compare sha256 manifests

Luckfox images are NAND layouts (env/idblock/uboot/boot/oem/userdata/rootfs), not SD images — imgdiff.py's
MBR/FAT/squashfs stages don't apply. Instead compare the CI artifact `seedsigner_luckfox_images_sha256` against
a local build's `sha256sums.txt`: every artifact and the final bundle must match byte-for-byte.

### Double-build recipe (any platform)

1. Build twice from the same commit in the same container (or CI + local).
2. Compare hashes; if they differ, **diff before rebuilding** — a rebuild changes both sides at once and
   destroys the evidence.

## What breaks it (maintenance checklist)

| Change | Risk | Required follow-up |
|---|---|---|
| Bump `SDK_COMMIT` (Luckfox) | `sort-dirents.patch` may not apply; sed/awk targets in patch-fs-determinism.sh may have moved — a *changed* target can silently no-op where a missing one fails loudly | Re-run the build, confirm every "pinned" line printed, then double-build and compare sha256sums.txt |
| Edit vendored headers (`mkfs-ubifs-determinism/lzo/*.h`, `uuid.h`) | SHA-256 pins reject them (build fails) — intended; but if the SDK's mtd-utils changes its includes you must update copy *and* hash together | Update both, double-build |
| Change `opt/luckfox/Dockerfile` | Invalidates all prior hashes; also must keep `liblzo2-2` and the explicit `COPY mkfs-ubifs-determinism/` line (`assert_shared_build_files()` fails fast if missing) | Rebuild image, double-build, re-baseline hashes |
| Add a download to any non-dev script | Unpinned downloads break reproducibility immediately | Use `download_and_verify()` (or an equivalent sha256 check); pin the hash |
| Add a package that embeds build metadata | Host uname/hostname/path/timestamp leaks into an image (the OpenCV class of bug) | Strip it or make the build fail loudly; test on two different hosts |
| Change app ref (`--seedsigner-ref`) | Expected: the image embeds the app commit — hashes *should* differ | Not a regression |
