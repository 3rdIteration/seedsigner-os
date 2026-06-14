# Agents Guide - Testing Edits in SeedSigner OS

This document provides instructions for AI agents (and developers) on how to quickly test various types of edits in this repository.

## ⚠️ CRITICAL: Never Trigger Full Builds Automatically

**A full build downloads many gigabytes and takes 30 minutes to 2+ hours.** Agents should **never** run a full build as part of testing. All validation must use the lightweight methods described below.

> **Lightweight tests are for validating edits locally. Full builds are tested automatically by GitHub Actions on every PR.** If your lightweight tests pass, commit and push — CI will verify the complete build.

## Project Overview

SeedSigner OS is a Buildroot-based embedded Linux distribution for Raspberry Pi boards. The repo uses Docker to build reproducible microSD card images. Key components:

- **`opt/build.sh`** - Main build script (entrypoint)
- **`Dockerfile`** - Debian 12 container with Buildroot dependencies
- **`docker-compose.yml`** - Mounts `opt/` and `images/` into the container
- **`opt/buildroot/`** - Git submodule (Buildroot itself)
- **`opt/<board>/`** - Board-specific configs (pi0, pi2, pi02w, pi4, lafrite)
- **`opt/external-packages/`** - Custom Buildroot packages not in upstream Buildroot
- **`opt/rootfs-overlay/`** - Files overlaid onto the root filesystem

## Quick Reference: Dev Container

All testing happens inside a Docker container. Start it once in no-op mode:

```bash
# Start container (does nothing but stay alive)
SS_ARGS="--no-op" docker compose up -d --no-recreate

# Shell into the running container
docker exec -it seedsigner-os-build-images-1 bash
cd /opt
```

From here you can run all the lightweight tests below.

## Testing by Edit Type

### 1. Testing `opt/build.sh` Changes (Build Script Logic)

**What it affects:** Build flow, translation compilation, font slimming, repo download, cleanup.

**Lightweight test — syntax check only:**
```bash
# Inside the container at /opt
bash -n build.sh          # Parse-only check (no execution)
shellcheck build.sh       # If available, catches common bash mistakes
```

### 2. Testing New/Modified Buildroot Packages (`opt/external-packages/`) ⭐ Most Common

This is one of the most common tasks and also where agents make the most mistakes (wrong filenames, bad hashes, incorrect variable names). **You can test packages without triggering a full OS build.**

#### Package Structure

Every external package in `opt/external-packages/<pkg>/` needs at minimum:

| File | Required? | Purpose |
|------|-----------|---------|
| `<pkg>.mk` | Yes | Build recipe (version, site, license, etc.) |
| `<pkg>.hash` | Yes | SHA256 checksum of the download tarball |
| `Config.in` | Usually | Kconfig option so it can be selected in defconfig |

Example `.mk` file:
```make
PYTHON_MNEMONIC_VERSION = 0.20
PYTHON_MNEMONIC_SITE = $(call github,trezor,mnemonic,v$(PYTHON_MNEMONIC_VERSION))
PYTHON_MNEMONIC_SETUP_TYPE = setuptools
PYTHON_MNEMONIC_LICENSE = MIT
$(eval $(python-package))
```

Example `.hash` file:
```
# sha256 from https://github.com/trezor/python-mnemonic
sha256  abc123...  python-mnemonic-0.20.tar.gz
```

#### Step-by-Step: Testing a New Package Without Full Build

**Step 1: Get the correct download hash**

Before writing the `.hash` file, download the source tarball and compute its sha256:

```bash
# From inside the container at /opt
cd /tmp
wget "https://github.com/trezor/python-mnemonic/archive/v0.20.tar.gz" -O python-mnemonic-0.20.tar.gz
sha256sum python-mnemonic-0.20.tar.gz
# Copy the hash into your <pkg>.hash file
```

**Step 2: Set up Buildroot for the target board**

```bash
cd /opt/buildroot
make BR2_EXTERNAL="/opt/external-packages" O="/output" -C /opt/buildroot pi0_defconfig
```

**Step 3: Test just source download (fastest validation)**

This verifies the `.mk` file syntax, download URL, and hash are all correct — without compiling anything:

```bash
cd /output
make <pkg-name>-source
```

For example, to test `python-mnemonic`:
```bash
make python-mnemonic-source
```

If this succeeds, your package name, version, site URL, and hash are all correct. If it fails, the error message will tell you exactly what's wrong (bad URL, hash mismatch, syntax error in .mk file, etc.).

**Step 4: Test just the build step (no full OS image)**

Once source download works, test that the package actually builds:

```bash
make <pkg-name>
```

This compiles and installs the package into Buildroot's staging directory without building the entire OS.

**Step 5: Verify the package is in the staging area**

```bash
# Check the package was built
ls /output/staging/usr/lib/python3*/site-packages/<pkg>/

# For Python packages specifically, check pip can find it
/output/host/bin/python3 -c "import <module_name>"
```

#### Common Mistakes When Adding Packages

| Mistake | How to Catch It | Test Command |
|---------|----------------|--------------|
| Wrong `.mk` filename (doesn't match directory) | Buildroot won't find it | `make <pkg>-source` fails with "unknown target" |
| Variable name mismatch (e.g., `PYTHON_FOO_VERSION` vs package name `python-foo`) | Build errors | `make <pkg>-source` |
| Wrong hash in `.hash` file | Download fails | `make <pkg>-source` fails with "hash mismatch" |
| Wrong tarball filename in `.hash` | Download fails | `make <pkg>-source` — compare expected vs actual filename |
| Missing `$(eval $(python-package))` at end of .mk | Package won't build | `make <pkg>` |
| Typo in github user/repo in `$(call github,...)` | 404 download error | `make <pkg>-source` |

#### Adding the Package to a Board Config

After testing, enable the package in the board's defconfig:

1. From `/output` directory (after running defconfig):
```bash
make menuconfig
# Navigate to your package, enable it with 'Y'
# Save and exit
```

2. Then update the defconfig file:
```bash
cp .config /opt/pi0/configs/pi0_defconfig
```

Or manually add `BR2_PACKAGE_<NAME>=y` to the appropriate Config.in or defconfig.

### 3. Testing `opt/rootfs-overlay/` Changes (Filesystem Overlays)

**What it affects:** Files that get copied into the final OS image (boot scripts, configs, etc.).

**Lightweight test — verify file structure and syntax:**
```bash
# Just check files exist and have valid syntax
find /opt/rootfs-overlay -type f | head -20
bash -n /opt/rootfs-overlay/<path>/<script>.sh  # if editing shell scripts
python3 -c "import <module>"                     # if editing python files
```

### 4. Testing Board Config Changes (`opt/pi0/`, `opt/pi2/`, etc.)

**What it affects:** Buildroot defconfigs, kernel configs, post-image scripts.

**Lightweight test — validate defconfig syntax:**
```bash
cd /output
make BR2_EXTERNAL="/opt/external-packages" -C /opt/buildroid pi0_defconfig 2>&1 | tail -5
# If it doesn't error out, the defconfig is valid
```

### 5. Testing `Dockerfile` Changes

**What it affects:** Container environment, available build tools.

**Lightweight test — rebuild container and verify tools:**
```bash
SS_ARGS="--no-op" docker compose up -d --force-recreate --build
docker exec seedsigner-os-build-images-1 which <tool>
docker exec seedsigner-os-build-images-1 python3 --version
```

### 6. Testing `docker-compose.yml` Changes

**What it affects:** Volume mounts, environment variables passed to build.sh.

**Lightweight test — verify mounts:**
```bash
SS_ARGS="--no-op" docker compose up -d --force-recreate
docker exec seedsigner-os-build-images-1 ls /opt/
docker exec seedsigner-os-build-images-1 ls /images/
```

## Workflow Summary

1. **Make your edits** to the relevant files
2. **Run lightweight tests** from the section above that matches your edit type
3. **If tests pass**, commit and push — GitHub Actions will run the full build automatically
4. **If CI fails**, check the GitHub Actions logs, fix the issue locally, and push again

## Common Failure Points

| Error | Likely Cause | Fix |
|-------|-------------|-----|
| "Translation catalog directory not found" | Branch without translations | Normal warning, build continues |
| "Disk full" during mkfs.fat | Partition too small | Edit `post-image-seedsigner.sh`, increase `dd count` |
| Buildroot symlink broken (Windows) | Git autocrlf/symlinks not configured | Reclone with Developer Mode + proper git config |
| Container exits immediately | Missing or invalid SS_ARGS | Use at least `SS_ARGS="--no-op"` |
| `make <pkg>-source` hash mismatch | Wrong sha256 in `.hash` file | Redownload tarball, run `sha256sum`, update `.hash` |
| `make <pkg>` "unknown target" | Package not enabled or .mk has wrong name | Check filename matches package name, verify BR2_EXTERNAL is set |