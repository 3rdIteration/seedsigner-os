---
name: release-verify
description: Verify a SeedSigner/SeedSignerOS paired release (tag SeSi-X.Y.Z+ShSi-BN) by rebuilding the Pi/Lafrite and Luckfox Pico images locally and comparing SHA-256 hashes against the GitHub Actions artifacts on the releases. Use when the user mentions a release tag, reproducible builds, hash verification, or "does my local build match CI" for seedsigner-os.
---

# Release Verification (Seedsigner + SeedsignerOS)

A release is a **paired tag** with one name in both repos, e.g. `SeSi-0.8.7+ShSi-B13-pre`:
`3rdIteration/seedsigner` (app) and `3rdIteration/seedsigner-os` (this repo). The OS tag's commit
is what the OS images are built from; the app tag pins the one component this repo does not fix.

The goal: rebuild every image locally from the same inputs CI used, and confirm byte-identical
SHA-256 hashes. **Non-dev** Pi/Lafrite/Luckfox builds are deterministic (see
`docs/reproducibility.md`). **Dev Pi images are NOT reproducible** — build them for functional
testing only; never hash-verify them against CI (they will mismatch, and that is expected).

For Luckfox there are two local build paths: `opt/luckfox/build.sh` (Docker-based, runs the same
`os-build.sh` inside the same container image as CI — **the reproducible one**) and the legacy
host-based `build-local.sh` (not reproducible; host state leaks in). Always use the Docker path.

## The four CI lineages

Dispatching a release runs up to four independent build lineages. **Each has different provenance
inputs, so each needs its own local rebuild.** Provenance lands in `/etc/seedsigner-os-release`
inside every image — one wrong field desyncs the whole hash.

| # | Triggered by | Builds | OS provenance recorded | Uploads to |
|---|--------------|--------|------------------------|------------|
| A | app repo `build-buildroot.yml` dispatch (`os-ref`=tag, `source-ref`=tag) | Pi/Lafrite, variant per `dev` input (release = **non-dev**) | all four fields **`unknown`** (the workflow never sets them) | app release: original filenames + `.zip`, hashes appended to release notes |
| B | OS repo `build.yml` dispatch (`seedsigner_release_tag`=tag, variant per input; pre-releases use **dev**) | Pi/Lafrite (dev images are test-only — not hash-verifiable) | `REPO=https://github.com/3rdIteration/seedsigner-os`, `BRANCH=<dispatch branch>`, `COMMIT=<HEAD sha>`, `DATE=<committer date %cI>` | OS release: renamed `seedsigner_os-<config>.img` |
| C | app repo `build-luckfox.yml` dispatch (workflow_call into this repo's `build-luckfox.yml@main`) | Luckfox, all 5 combos, variant per input (release = **non-dev**, signing on) | same as B but `BRANCH=HEAD` — the tag checkout is detached and CI records `rev-parse --abbrev-ref HEAD` verbatim | app release (`GITHUB_REPOSITORY` = caller in a cross-repo call) |
| D | OS repo `build-luckfox.yml` direct dispatch (ALL/ALL, variant per input) | Luckfox, all 5 combos | same as B with the real branch name | OS release if `release_tag` set |

App fields are identical across lineages: `APP_REPO=https://github.com/3rdIteration/seedsigner`,
`APP_BRANCH=<tag>`, `APP_COMMIT`/`APP_DATE` from the app tag's commit. (Lineage A records APP_REPO
without `.git`; Luckfox lineages record it **with** `.git` — that is correct and expected, they use
different code paths.)

The 5 Luckfox combos: Mini SD_CARD + SPI_NAND, Pro Max SD_CARD + SPI_NAND, Pico Pi EMMC.
Signed builds (default) tag artifacts `-signed-devkey`; the `fit-sign-tree-<model>.zip` assets are
the re-signing key trees and differ between lineages C/D because they embed provenance.

## Step 1 — Establish ground truth from CI

```sh
TAG="SeSi-0.8.7+ShSi-B13-pre"                      # + must be %2B in API URLs
OS_COMMIT=$(git rev-parse "$TAG")                   # this repo, tag == main tip for releases
OS_DATE=$(git show -s --format=%cI "$TAG")

# Runs (inputs are NOT exposed by the API — read them from run/job names and logs):
gh run list --repo 3rdIteration/seedsigner-os --limit 10
gh run list --repo 3rdIteration/seedsigner   --limit 10
gh run view <run-id> --json jobs             # job names reveal variant: "-smartcard-dev" vs "-smartcard"

# Provenance CI actually stamped (gen-os-release.sh cats the file to the log):
gh run view --repo <repo> --job <job-id> --log | grep -A10 "Generated .*seedsigner-os-release"

# Reference hashes = release asset digests:
gh api "repos/3rdIteration/seedsigner/releases/tags/$TAG_ENCODED"   # assets[].digest = sha256:...
gh api "repos/3rdIteration/seedsigner-os/releases/tags/$TAG_ENCODED"
```

Record every asset name + digest you intend to verify. Note which lineages actually ran (a
pre-release typically runs all four; a failed job shows `conclusion: failure` — transient apt-mirror
failures in the Luckfox Dockerfile build are common, just re-run that one job).

## Step 2 — Local builds

Work from a **fresh clone of this repo at the tag** (WSL/ext4 preferred over `/mnt/c`; Docker
Desktop's daemon is shared). Warm caches make cold builds ~3x faster and are determinism-safe:
symlink an old checkout's `.buildroot-ccache` and `buildroot_dl` into the new one.

Pi/Lafrite (lineages A/B) — `launch-pi.sh <tag> <app|osrepo> [dev]`:

```sh
tools/release-verify/launch-pi.sh "$TAG" app      # lineage A: non-dev, OS provenance unknown
tools/release-verify/launch-pi.sh "$TAG" osrepo dev   # lineage B: dev + explicit SEEDSIGNER_OS_* (test-only)
```

Dev builds are for flashing/testing; skip hash verification for them.

It runs `docker compose up -d` (detached — survives WSL idle shutdown) with the exact `SS_ARGS`
and env of the matching CI workflow, then prints how to watch it. Images land in `images/` as
`seedsigner_os.<sanitized-tag>.<board>-smartcard[-dev].img` (`+` → `_`).

Luckfox (lineages C/D) — provenance is resolved from **git checkout state** by
`opt/luckfox/build.sh`, so the checkout must match CI: detached at the tag for lineage C
(`BRANCH=HEAD`), on the dispatch branch for D. `launch-luckfox.sh <tag> [branch]`:

```sh
tools/release-verify/launch-luckfox.sh "$TAG"            # lineage C (detached at tag)
tools/release-verify/launch-luckfox.sh "$TAG" main       # lineage D
```

Runs `opt/luckfox/build.sh build --all --variant non-dev --seedsigner-ref <tag>` with
`SEEDSIGNER_FIT_SIGNATURE=1`. Five sequential builds in one container (~1–2 h each); artifacts +
per-combo `sha256sums.txt` land in the output dir.

**Do not run two Pi/Lafrite compose projects against the same repo dirs concurrently**, and keep
`PARALLEL_JOBS` capped (the script sets 8): the container sees all host cores but the Docker VM's
RAM is finite; job count never affects output bytes.

## Step 3 — Compare

```sh
tools/release-verify/compare-hashes.py images/ --expect expect.txt
# expect.txt lines: "<sha256>  <filename>" (from the release asset digests)
```

(Dev Pi images always "mismatch" — expected; this triage is for non-dev artifacts only.)

On a mismatch, in order of likelihood:
1. **Provenance drift** — extract `/etc/seedsigner-os-release` from both images and diff. For Pi
   images it is inside the rootfs; `grep -a SEEDSIGNER_OS_ <img>` usually finds it directly (ext4
   is uncompressed). Check you matched the lineage's rules above, especially `BRANCH=HEAD` for C
   and `unknown` for A.
2. **App ref drift** — wrong tag/branch changes app code *and* the image filename.
3. Real non-determinism — then use `python3 tools/imgdiff.py local.img ci.img` (Pi/Lafrite only;
   it narrows to the file and, for ELFs, the embedded string). Differences **cascade**: the
   innermost file whose content changed is the root cause. Luckfox NAND layouts are not imgdiff-able:
   compare the per-file `sha256sums.txt` inside the bundles instead.

## Gotchas

- WSL distros shut down when idle and kill backgrounded builds — use detached Docker (the scripts
  do) or a long-lived foreground session, never bare `nohup &`.
- PowerShell→WSL quoting mangles inline commands with pipes/quotes; put logic in script files.
- Tag names contain `+` → `%2B` in URLs; shell-quoting the tag is otherwise fine.
- CI dispatch inputs are not readable via API — derive them from run/job titles, asset filenames
  (`-dev` suffix = dev variant), and the provenance block in job logs.
- The app-side Pi workflow (lineage A) builds each board in its own container; local `--all`
  reuses one clone for boards 2–5 — output is byte-identical either way.
- Re-running a failed CI job after a transient apt-mirror failure produces the same hashes as its
  siblings (determinism), so verify against whichever copy landed on the release.
