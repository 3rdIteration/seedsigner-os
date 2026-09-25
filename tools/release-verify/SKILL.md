---
name: release-verify
description: Cut and verify a paired SeedSigner/SeedSignerOS release (tag SeSi-X.Y.Z+ShSi-Bnn[-pre]) end to end — version bump, submodule pin, docs/screenshots, prereleases + tags, CI dispatch, and local rebuild with byte-identical SHA-256 verification. Use when the user mentions a release tag, cutting/making a release, reproducible builds, hash verification, or "does my local build match CI" for seedsigner-os.
---

# SeedSigner / SeedSignerOS Release Ceremony & Verification

A release is a **paired tag** with one name in both repos, e.g. `SeSi-0.8.7+ShSi-B13-pre`:
`3rdIteration/seedsigner` (app) and `3rdIteration/seedsigner-os` (this repo). The OS tag's commit is
what the OS images are built from; the app tag pins the one component this repo does not fix.

**Production vs dev artifacts.** The **app release** is the only production distribution — it must be
fully reproducible. The **OS repo release** carries *dev/test builds* (Pi dev images, bench Luckfox
images) for flashing and debugging; they are **never hash-gated** (Pi dev builds are non-reproducible
by design). Keep this split in mind in every phase below.

Release branches: OS repo tags on **main**, app repo tags on **dev**. Bumps are committed directly to
the release branch (no PR) except the docs/screenshots PR (Phase 4).

Prerequisites: `gh` authenticated to both repos; for Phase 7 a WSL2 Ubuntu + Docker Desktop host with
~150 GB free and (optionally) warm caches from a previous release clone.

## Phase 0 — Pick the version and diff features

`SeSi-X.Y.Z+ShSi-Bnn[-pre]`: X.Y.Z = app version, Bnn = OS build number, `-pre` marks a pre-release
(the suffix lives **only in the tag name**, never in the in-code version string).

```sh
PREV_TAG=<previous tag>
git fetch --tags && git log --oneline "$PREV_TAG"..main        # OS features -> release notes + docs list
gh api repos/3rdIteration/seedsigner/compare/"$PREV_TAG"...dev --jq '.commits[].commit.message'
```

Draft the release notes here; the feature list drives the Phase 4 docs audit and the Phase 5 notes.

## Phase 1 — App VERSION bump (direct push to dev)

`src/seedsigner/controller.py` → `VERSION = "SeSi-X.Y.Z+ShSi-Bnn"` — **no `-pre`** in the string
(matches every release since pairing began). The OS repo has no in-code version; its tag *is* the
version.

```sh
# in a seedsigner checkout on dev
git pull && sed -i 's/VERSION = "SeSi-.*/VERSION = "SeSi-X.Y.Z+ShSi-Bnn"/' src/seedsigner/controller.py
git commit -am "chore: bump VERSION to SeSi-X.Y.Z+ShSi-Bnn" && git push origin dev
```

## Phase 2 — OS tag + prerelease (dev-artifact target)

The CI upload steps only upload to a **pre-existing** release, so create it first.

```sh
git checkout main && git pull
git tag "$TAG" && git push origin "$TAG"
gh release create "$TAG" --repo 3rdIteration/seedsigner-os --target main --prerelease \
  --title "SeedSigner OS $TAG" --notes "Dev/test builds. Production images: 3rdIteration/seedsigner release $TAG."
```

## Phase 3 — Pin the OS submodule in the app repo (direct push to dev)

Follow the app repo's `AGENTS.md` "seedsigner-os submodule (release pin)" section — `update = none` is
load-bearing, pin only at release, never `--remote`:

```sh
git -C seedsigner-os fetch --tags
git -C seedsigner-os checkout "$TAG"
git add seedsigner-os
git commit -m "chore: pin seedsigner-os to $TAG for release X.Y.Z" && git push origin dev
```

## Phase 4 — Docs & screenshots PR (merge before the app tag)

Audit `docs/` in the app repo against the Phase 0 feature diff; fix drift, add pages for new features.
Screenshots: regenerate with the screenshot generator, then curate into the docs tree —

```sh
python tools/collect_docs_screenshots.py <generator-root>/en      # copies the referenced subset to docs/img/guide
# smartcard card-data shots come from the jcardsim capture in tests/docs_screenshots
```

Update `docs/repositories.md` "Current Pin" pairing table (OS tag + commit) and `CHANGELOG.md`. Open a
PR into dev, review, merge — it must land before Phase 5 so the tag carries the docs.

## Phase 5 — App tag + prerelease (production target)

```sh
git checkout dev && git pull          # now carries VERSION bump + pin (+ merged docs PR)
git tag "$TAG" && git push origin "$TAG"
gh release create "$TAG" --repo 3rdIteration/seedsigner --target dev --prerelease \
  --title "SeedSigner $TAG" --notes-file notes.md
```

## Phase 6 — Dispatch the CI builds

Two groups. **Pass every build-shaping input explicitly** (commands below match current UI defaults)
and **record the exact dispatch inputs at dispatch time** — see the gotcha about API input reporting.

### Production (app repo) — these images ship and get the Phase 7 hash gate

```sh
# A: Pi + La Frite, non-dev, all boards, upload to the app release
gh workflow run build-buildroot.yml --repo 3rdIteration/seedsigner \
  -f os-repo=3rdIteration/seedsigner-os -f os-ref="$TAG" \
  -f app-repo=3rdIteration/seedsigner   -f source-ref="$TAG" \
  -f target=all -f smartcard=true -f dev=false -f upload-release=true

# C: Luckfox, all 5 combos, non-dev, signed, upload to the app release
gh workflow run build-luckfox.yml --repo 3rdIteration/seedsigner \
  -f hardware_type=ALL -f boot_medium=ALL -f build_variant=non-dev \
  -f usb_mode=auto -f debug_network=auto -f disable_uart2_console_debug=auto \
  -f harden_adb=on -f readonly_rootfs=auto -f boot_log=off -f testing-build=off \
  -f source-ref="$TAG" -f app-repo=3rdIteration/seedsigner \
  -f os-repo=3rdIteration/seedsigner-os -f os-ref="$TAG" -f release_tag="$TAG"
```

### Dev (OS repo) — bench/test images, uploaded for convenience, never hash-gated

```sh
# B: Pi + La Frite dev images -> OS release (renamed seedsigner_os.<tag>.<board>-dev.img)
gh workflow run build.yml --repo 3rdIteration/seedsigner-os --ref main \
  -f app_repo=https://github.com/3rdIteration/seedsigner \
  -f seedsigner_release_tag="$TAG" -f seedsigner_os_release_tag="$TAG" \
  -f upload_to_release=true -f board=all -f variant=dev

# D: Luckfox dev variants -> OS release. Dispatch on main (--ref main) so the OS
# checkout is the branch tip — provenance records BRANCH=main; only correct while
# main's tip == the tag's commit (true at cut time).
gh workflow run build-luckfox.yml --repo 3rdIteration/seedsigner-os --ref main \
  -f hardware_type=ALL -f boot_medium=ALL -f build_variant=dev \
  -f usb_mode=auto -f debug_network=auto -f disable_uart2_console_debug=auto \
  -f seedsigner_branch="$TAG" -f release_tag="$TAG"
```

Track: `gh run watch <id>` / `gh run list --limit`. A transient apt-mirror failure in the Luckfox
Dockerfile build kills one matrix job — just **Re-run failed jobs**; determinism means the re-run's
hashes match its siblings. Uploads use `--clobber`, so re-runs are safe.

## Phase 7 — Local rebuild & hash gate (production artifacts only)

**Scope:** the 5 app-release Pi/Lafrite images (A) + 5 app-release Luckfox artifacts (C). OS-repo dev
assets are out of scope (dev Pi builds embed build-time metadata; that is expected, not a failure).

### The four CI build paths and their provenance

Provenance lands in `/etc/seedsigner-os-release` inside every image — one wrong field desyncs the
whole hash chain.

| # | Triggered by | Builds | OS provenance recorded | Uploads to | Gate |
|---|--------------|--------|------------------------|------------|------|
| A | app repo `build-buildroot.yml` dispatch | Pi/Lafrite non-dev | all four fields **`unknown`** (the workflow never sets them) | app release | **hash gate** |
| B | OS repo `build.yml` dispatch | Pi/Lafrite dev | `REPO=https://github.com/3rdIteration/seedsigner-os`, `BRANCH=<dispatch branch>`, `COMMIT=<sha>`, `DATE=%cI` | OS release | none (dev) |
| C | app repo `build-luckfox.yml` dispatch (workflow_call into this repo's `build-luckfox.yml@main`) | Luckfox, 5 combos, non-dev, signed | like B but `BRANCH=HEAD` (the tag checkout is detached) | app release | **hash gate** |
| D | OS repo `build-luckfox.yml` direct dispatch | Luckfox, any combo | like B with the real branch name | OS release | none (dev) |

App fields match across lineages: `APP_REPO=https://github.com/3rdIteration/seedsigner`,
`APP_BRANCH=<tag>`, `APP_COMMIT`/`APP_DATE` from the app tag's commit. Since the URL
canonicalisation PR, every lineage records the canonical no-`.git` form; images built **before** that
change recorded the Luckfox lineages' URL **with** `.git` — when reproducing those older releases the
local rebuild must match the recorded spelling (the launch scripts below set it per lineage).

**Build-shaping inputs also change bytes.** The `dispatch` jobs pass the dispatcher's choices
through; the non-dispatch `ci-pico-mini` job (PR/push CI) pins the hardening levers explicitly.
Nothing else in the pipeline should alter build-shaping inputs — a dispatch with a non-default
`disable_uart2_console_debug`, `usb_mode`, `debug_network`, `readonly_rootfs`, `boot_log`,
`testing_build`, `signing`, or `rootfs_verify_unfused` produces images that **legitimately differ**
from a defaults build (e.g. console-on keeps the FIQ debugger in the kernel and changes
fdt/ramdisk/resource too).

### Step 1 — Establish ground truth from CI

```sh
TAG_ENCODED=${TAG//+/%2B}
OS_COMMIT=$(git rev-parse "$TAG")                   # this repo; tag == main tip for releases

gh api "repos/3rdIteration/seedsigner/releases/tags/$TAG_ENCODED"     # assets[].digest = sha256:...
gh api "repos/3rdIteration/seedsigner-os/releases/tags/$TAG_ENCODED"  # dev assets — informational only

# Effective build inputs are NOT reliably reported by the API — confirm them from the logs:
gh run view <run-id> --log | grep -E '\[SUCCESS\] (SEEDSIGNER_|DISABLE_)|\[INFO\] UART2|Generated .*seedsigner-os-release'
```

Record every production asset name + digest you intend to verify.

### Step 2 — Local builds (fresh clone at the tag, Docker paths only)

Work from a **fresh clone of this repo at the tag** (WSL/ext4, Docker Desktop). Warm caches
(symlink an old clone's `.buildroot-ccache` + `buildroot_dl`) are ~3x faster and determinism-safe.
Never use the legacy host-based `build-local.sh` for verification — host state leaks in.

```sh
tools/release-verify/launch-pi.sh "$TAG" app        # lineage A: non-dev, OS provenance unknown
tools/release-verify/launch-luckfox.sh "$TAG"       # lineage C: detached at tag (BRANCH=HEAD)
```

Luckfox provenance is resolved from the **git checkout state** by `opt/luckfox/build.sh`, so the
checkout must match CI (detached at the tag for C; pass a branch name as arg 2 to reproduce lineage
D). `launch-pi.sh` runs detached (`docker compose up -d`) and prints how to watch; 
`launch-luckfox.sh` **blocks** (five sequential SDK builds, ~1-2 h each with warm caches) — run it in
a `tmux`/long-lived session or wrap the `docker run` yourself in detached mode. Cap `PARALLEL_JOBS`
(the scripts set 8); job count never affects output bytes. Do not run two Pi compose projects against
the same repo dirs concurrently.

### Step 3 — Compare

```sh
# Pi/Lafrite images vs the app-release asset digests:
gh api "repos/3rdIteration/seedsigner/releases/tags/$TAG_ENCODED" \
  | jq -r '.assets[] | select(.name | endswith(".img")) | (.digest | sub("sha256:";"")) + "  " + .name' > expect.txt
tools/release-verify/compare-hashes.py images/ --expect expect.txt

# Luckfox bundles vs CI's merged manifest artifact (seedsigner_luckfox_images_sha256):
tools/release-verify/compare-hashes.py --manifest-ci ci.sha256 --manifest-local luckfox-out/sha256sums.txt
```

On a production mismatch, in order of likelihood:
1. **Provenance drift** — extract `/etc/seedsigner-os-release` from both images and diff (Pi:
   `grep -a SEEDSIGNER_OS_ <img>`; Luckfox NAND: UBI-wrapped squashfs). Check the lineage rules
   above, especially `BRANCH=HEAD` for C and `unknown` for A. One provenance byte desyncs the
   *entire signed chain*: rootfs.img → its minisign signature (`rootfs.sig`, embedded in the
   initramfs) → boot.img's FIT hash + RSA-PSS signature → update.img / SD image. Verify by
   extracting both squashfs trees file-by-file — expect exactly one differing file, and the
   ramdisk's only differing entry to be `rootfs.sig`.
2. **Input drift** — compare recorded inputs (Phase 6 record + Step 1 log grep) against your local
   env; non-default levers legitimately change bytes.
3. **App ref drift** — wrong tag/branch changes app code *and* image filenames.
4. Real non-determinism — `python3 tools/imgdiff.py local.img ci.img` (Pi/Lafrite only; NAND is not
   imgdiff-able — compare the per-file `sha256sums.txt` inside the bundles).

## Gotchas

- **API input reporting is unreliable for manual dispatches.** `runs/<id>.inputs` was observed as
  `null` while the job log proved an explicit non-default override. Always capture dispatch inputs
  yourself (keep the `gh workflow run` commands / note UI selections) and confirm effective values
  via the `[SUCCESS] VAR=...` / `[INFO]` lines in the build log.
- `uboot.img` ends with "boot.img" — `endswith('boot.img')` style filters silently hash the wrong
  image. Match exact basenames.
- Luckfox `boot.img` is a raw U-Boot FIT at offset 0 (FDT magic `d0 0d fe ed`, big-endian);
  `opt/luckfox/secure-boot/verify-fit-payloads.py payloads|compare <img>` shows which of
  kernel/fdt/ramdisk/resource moved.
- WSL distros shut down when idle and kill backgrounded builds — `launch-pi.sh` is detached; run
  `launch-luckfox.sh` (blocking) inside `tmux`. Never bare `nohup &`.
- PowerShell→WSL quoting mangles inline commands with pipes/quotes; put logic in script files.
- Tag names contain `+` → `%2B` in API URLs.
- CI upload steps require the GitHub release to **already exist** (that's why Phase 2/5 precede 6).
- Re-running a failed CI job after a transient failure produces the same hashes as its siblings;
  uploads `--clobber`, so late re-runs safely replace assets.
- Dev Pi images (B) always "mismatch" hashes — expected; they are for flashing, not verification.