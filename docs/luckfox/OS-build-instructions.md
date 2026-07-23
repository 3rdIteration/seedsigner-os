# OS Build Instructions

## Build with GitHub Actions (Easiest Method)

For most users, building with GitHub Actions is the easiest and most reliable method. This approach builds directly on GitHub's infrastructure without using Docker:

### Using GitHub Actions
1. Fork this repository to your GitHub account
2. Go to the "Actions" tab in your fork
3. Select the "Build SeedSigner OS" workflow
4. The workflow runs automatically on every push to `main`, `develop`, or `master` branches
5. Wait for the build to complete (60-120 minutes)
6. Download the artifacts from the completed workflow run

The workflow automatically:
- Installs all required build dependencies on Ubuntu 22.04
- Clones all required repositories:
  - `luckfox-pico` SDK (customized fork with SeedSigner modifications)
  - `seedsigner` code (dev branch)
  - `seedsigner-os` packages
- Configures buildroot with SeedSigner-specific packages
- Builds for both hardware targets:
  - LuckFox Pico Mini (RV1103)
  - LuckFox Pico Pro Max (RV1106)
- Creates flashable SD card images and NAND flash bundles (for SD_CARD and SPI_NAND boot media)
- Provides detailed instructions for flashing both SD card images and NAND flash bundles

**Note**: The GitHub Actions workflow does NOT use Docker - it builds directly on the runner, following the same approach as the stock LuckFox Pico SDK.

---

## Build Locally with Docker (Simple Method)

The Docker build is fully self-contained and handles all repository cloning and setup automatically. This is the easiest local build option.

### Quick Start with build.sh

From the `buildroot/` directory, simply run:

```bash
./build.sh build --microsd
```

Build artifacts will be automatically available in `buildroot/build-output/` when the build completes.

**Common Build Commands:**
```bash
# Build SD card images for both Mini and Max
./build.sh build --microsd

# Build NAND flash bundles
./build.sh build --nand

# Build both SD and NAND artifacts
./build.sh build --microsd --nand

# Build only Mini hardware
./build.sh build --microsd --model mini

# Build only Max hardware
./build.sh build --microsd --model max

# Use 8 parallel jobs for faster builds
./build.sh build --microsd --jobs 8

# Interactive mode for debugging
./build.sh interactive

# Check build system status
./build.sh status
```

**Key Features:**
- Automatically builds Docker image if needed
- Uses persistent Docker volume for repository caching (faster subsequent builds)
- First build: 30-90 minutes (clones repos)
- Later builds: 15-45 minutes (reuses cached repos)
- Artifacts automatically exported to `build-output/` directory

**Output Location:**
- Default: `buildroot/build-output/`
- Custom: `./build.sh build --microsd --output /path/to/output`

### Alternative: Direct Docker Commands

If you prefer to use Docker commands directly (note: uses different output directory than build.sh):

```bash
# Build the Docker image
docker build -t foxbuilder:latest .

# Run the automated build (creates SD card images for both Mini and Max)
# Note: Artifacts will be in buildroot/output/ (not build-output/)
docker run --rm -v $(pwd)/output:/build/output foxbuilder:latest auto

# Or with NAND flash bundles included
docker run --rm -v $(pwd)/output:/build/output foxbuilder:latest auto-nand
```

**Customize with environment variables:**
```bash
# Build only Mini hardware
docker run --rm -v $(pwd)/output:/build/output -e BUILD_MODEL=mini foxbuilder:latest auto

# Build only Max hardware  
docker run --rm -v $(pwd)/output:/build/output -e BUILD_MODEL=max foxbuilder:latest auto

# Adjust Mini CMA memory size
docker run --rm -v $(pwd)/output:/build/output -e MINI_CMA_SIZE=2M foxbuilder:latest auto
```

---

## Build Locally Without Docker (Advanced/Development Users)

This method builds directly on your host system, mirroring the GitHub Actions workflow. **Tested with Ubuntu 22.04.**

### Quick Start with build-local.sh

For the easiest non-Docker build experience, use the automated build script:

```bash
cd buildroot/

# Install dependencies (first time only)
./build-local.sh --check-deps

# Build for Mini with SD card (default)
./build-local.sh

# Build for Max with SD card
./build-local.sh --hardware max --boot sd

# Build for Mini with NAND
./build-local.sh --hardware mini --boot nand

# Just clone repositories
./build-local.sh --clone-only

# Clean build artifacts
./build-local.sh --clean
```

The script automates all the manual steps below and produces flashable images in `luckfox-pico/output/image/`.

**Build time:** 60-120 minutes for first build, 30-60 minutes for subsequent builds.

### Manual Build Process (Step-by-Step)

If you prefer to run each step manually or need more control, follow these detailed instructions:

### Prerequisites

Install required dependencies:
```bash
sudo apt-get update
sudo apt-get install -y \
  git ssh make gcc gcc-multilib g++-multilib \
  module-assistant expect g++ gawk texinfo \
  libssl-dev bison flex fakeroot cmake unzip \
  gperf autoconf device-tree-compiler \
  libncurses5-dev pkg-config bc python-is-python3 \
  passwd openssl openssh-server openssh-client \
  vim file cpio rsync
```

### Clone Required Repositories

Clone all required repositories into your working directory:

```bash
# Clone the LuckFox Pico SDK (customized fork with SeedSigner modifications)
git clone https://github.com/3rdIteration/luckfox-pico.git --depth=1 --single-branch

# Clone SeedSigner OS packages (buildroot package definitions)
git clone https://github.com/3rdIteration/seedsigner-os.git --depth=1 --single-branch

# Clone SeedSigner application code
git clone https://github.com/3rdIteration/seedsigner.git --depth=1 -b dev --single-branch --recurse-submodules

# Clone this repository (if not already)
git clone https://github.com/3rdIteration/seedsigner-luckfox-pico.git --depth=1 --single-branch
```

### Set Up Build Environment

```bash
cd luckfox-pico

# Source the toolchain environment
cd tools/linux/toolchain/arm-rockchip830-linux-uclibcgnueabihf
source env_install_toolchain.sh
cd ../../../..

# Verify toolchain is accessible
which arm-rockchip830-linux-uclibcgnueabihf-gcc
```

### Configure Board

Choose your hardware type and boot medium:

```bash
# For LuckFox Pico Mini with SD Card:
# Hardware index: 1 (RV1103_Luckfox_Pico_Mini)
# Boot index: 0 (SD_CARD)
# System index: 0 (Buildroot)
printf "1\n0\n0\n" | ./build.sh lunch

# For LuckFox Pico Pro Max with SD Card:
# Hardware index: 4 (RV1106_Luckfox_Pico_Pro_Max)
# Boot index: 0 (SD_CARD)
# System index: 0 (Buildroot)
printf "4\n0\n0\n" | ./build.sh lunch

# For SPI NAND boot, use boot index 1 instead of 0
```

### Apply CMA Memory Configuration (Mini Only)

If building for Mini hardware, apply CMA memory configuration:

```bash
# Find the board config file
BOARD_CONFIG=$(find project/cfg/BoardConfig_IPC -name "BoardConfig-*-Buildroot-RV1103_Luckfox_Pico_Mini-IPC.mk" | head -n 1)

# Set CMA size to 1M (recommended for Mini)
if grep -q '^export RK_BOOTARGS_CMA_SIZE=' "$BOARD_CONFIG"; then
  sed -i 's|^export RK_BOOTARGS_CMA_SIZE=.*|export RK_BOOTARGS_CMA_SIZE="1M"|' "$BOARD_CONFIG"
else
  echo 'export RK_BOOTARGS_CMA_SIZE="1M"' >> "$BOARD_CONFIG"
fi
```

### Prepare Buildroot Source Tree

```bash
make buildroot_create -C sysdrv
```

### Install SeedSigner Packages

```bash
# Auto-detect buildroot directory
BUILDROOT_DIR=$(find sysdrv/source/buildroot -maxdepth 1 -type d -name 'buildroot-*' | sort | tail -n 1)
PACKAGE_DIR="${BUILDROOT_DIR}/package"

# Copy SeedSigner packages from seedsigner-os
cp -rv ../seedsigner-os/opt/external-packages/* "$PACKAGE_DIR/"

# Add SeedSigner menu to buildroot Config.in
CONFIG_IN="${PACKAGE_DIR}/Config.in"
if ! grep -q '^menu "SeedSigner"$' "$CONFIG_IN"; then
  cat >> "$CONFIG_IN" << 'EOF'
menu "SeedSigner"
	source "package/python-urtypes/Config.in"
	source "package/python-pyzbar/Config.in"
	source "package/python-mock/Config.in"
	source "package/python-embit/Config.in"
	source "package/python-pillow/Config.in"
	source "package/zbar/Config.in"
	source "package/jpeg-turbo/Config.in.options"
	source "package/jpeg/Config.in"
	source "package/python-qrcode/Config.in"
	source "package/python-pyqrcode/Config.in"
endmenu
EOF
fi
```

### Apply SeedSigner Buildroot Configuration

```bash
# Copy SeedSigner defconfig
cp -v ../seedsigner-os/opt/luckfox/configs/luckfox_pico_defconfig "$BUILDROOT_DIR/configs/luckfox_pico_defconfig"
cp -v ../seedsigner-os/opt/luckfox/configs/luckfox_pico_defconfig "$BUILDROOT_DIR/.config"

# Update pyzbar patch with Python version
PYZBAR_PATCH="${PACKAGE_DIR}/python-pyzbar/0001-PATH-fixed-by-hand.patch"
if [ -f "$PYZBAR_PATCH" ] && [ -f "$BUILDROOT_DIR/.config" ]; then
  PYTHON_VER=$(grep -oP 'BR2_PACKAGE_PYTHON3_VERSION="\K[^"]+' "$BUILDROOT_DIR/.config" 2>/dev/null || echo "3.11")
  sed -i "s|path = \".*/site-packages/zbar.so\"|path = \"/usr/lib/python${PYTHON_VER}/site-packages/zbar.so\"|" "$PYZBAR_PATCH"
  echo "Updated pyzbar patch for Python ${PYTHON_VER}"
fi
```

### Build System

```bash
./build.sh uboot
./build.sh kernel
./build.sh rootfs
./build.sh media
./build.sh app
```

### Install SeedSigner Application

```bash
# Find rootfs directory
ROOTFS_DIR=$(find output/out -maxdepth 1 -type d -name "rootfs_uclibc_*" | head -n 1)

# Copy SeedSigner code
cp -rv ../seedsigner/src/ "$ROOTFS_DIR/seedsigner"

# Patch settings.json for Mini hardware (if applicable)
# For Mini, change FOX_40 to FOX_22
SETTINGS_JSON="$ROOTFS_DIR/seedsigner/settings.json"
if [ -f "$SETTINGS_JSON" ]; then
  # Uncomment the following line if building for Mini:
  # sed -i 's/"hardware_config":[[:space:]]*"FOX_40"/"hardware_config": "FOX_22"/g' "$SETTINGS_JSON"
  echo "Settings.json ready"
fi

# Fix pyzbar library path
PYTHON_VERSION=$(ls "$ROOTFS_DIR/usr/lib/" | grep -E '^python3\.[0-9]+$' | head -n 1)
if [ -n "$PYTHON_VERSION" ]; then
  SITE_PACKAGES="$ROOTFS_DIR/usr/lib/$PYTHON_VERSION/site-packages"
  if [ -f "$SITE_PACKAGES/zbar.so" ]; then
    ln -sf "$PYTHON_VERSION/site-packages/zbar.so" "$ROOTFS_DIR/usr/lib/zbar.so"
    echo "Created zbar.so symlink for pyzbar"
  fi
fi

# Copy configuration files
cp -v ../seedsigner-os/opt/luckfox/files/luckfox.cfg "$ROOTFS_DIR/etc/luckfox.cfg"
cp -v ../seedsigner-os/opt/luckfox/files/nv12_converter "$ROOTFS_DIR/"
cp -v ../seedsigner-os/opt/luckfox/files/start-seedsigner.sh "$ROOTFS_DIR/"
cp -v ../seedsigner-os/opt/luckfox/files/S99seedsigner "$ROOTFS_DIR/etc/init.d/"
```

### Package Firmware

```bash
./build.sh firmware
```

### Create Flashable SD Image

For SD card boot configurations:

```bash
cd output/image

# Determine board label (mini or max based on your build)
BOARD_LABEL="mini"  # or "max"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
IMAGE_NAME="seedsigner-luckfox-pico-${BOARD_LABEL}-sd-${TIMESTAMP}.img"

# Use blkenvflash to create the SD image
../../seedsigner-os/opt/luckfox/blkenvflash "$IMAGE_NAME"

echo "SD card image created: $IMAGE_NAME"
```

### Create NAND Flash Bundle (Optional)

For SPI NAND boot configurations:

```bash
cd output/image

BOARD_LABEL="mini"  # or "max"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NAND_BUNDLE_DIR="seedsigner-luckfox-pico-${BOARD_LABEL}-nand-files-${TIMESTAMP}"

mkdir -p "$NAND_BUNDLE_DIR"

# Copy required NAND flashing files
cp update.img download.bin env.img idblock.img uboot.img boot.img \
   oem.img userdata.img rootfs.img sd_update.txt tftp_update.txt \
   "$NAND_BUNDLE_DIR/"

# Create tar.gz archive
tar -czf "seedsigner-luckfox-pico-${BOARD_LABEL}-nand-bundle-${TIMESTAMP}.tar.gz" "$NAND_BUNDLE_DIR"

echo "NAND bundle created: seedsigner-luckfox-pico-${BOARD_LABEL}-nand-bundle-${TIMESTAMP}.tar.gz"
```

---

## Advanced Docker Build (Legacy Method)

For advanced users who want more control over the Docker build process, follow these instructions:
Run these commands from `buildroot` directory.

Build the builder image:
```bash
cd buildroot/
docker build -t foxbuilder:latest .
```

*IMPORTANT* We need all of these directories to be setup, and cloned in our `$HOME` directory:
```bash
ls ~
luckfox-pico  seedsigner  seedsigner-luckfox-pico  seedsigner-os
```
The `seedsigner-luckfox-pico` directory is this repo we are already in!


Clone the Luckfox SDK repo:
```bash
git clone https://github.com/3rdIteration/luckfox-pico.git \
    --depth=1 --single-branch
```

Clone the Seedsigner OS repo:
```bash
git clone https://github.com/3rdIteration/seedsigner-os.git \
    --depth=1 --single-branch
```

Clone the Seedsigner repo:
```bash
git clone https://github.com/3rdIteration/seedsigner.git \
    --depth=1 -b dev --single-branch --recurse-submodules
```


## Run OS Build

Run these commands from `buildroot/` directory. This is the directory/repo we cloned above.

```bash
LUCKFOX_SDK_DIR=$HOME/luckfox-pico
SEEDSIGNER_CODE_DIR=$HOME/seedsigner
LUCKFOX_BOARD_CFG_DIR=$HOME/seedsigner-luckfox-pico
SEEDSIGNER_OS_DIR=$HOME/seedsigner-os

# TODO check all these above paths exist

docker run -d --name luckfox-builder \
    -v $LUCKFOX_SDK_DIR:/mnt/host \
    -v $SEEDSIGNER_CODE_DIR:/mnt/ss \
    -v $LUCKFOX_BOARD_CFG_DIR:/mnt/cfg \
    -v $SEEDSIGNER_OS_DIR:/mnt/ssos \
    foxbuilder:latest
```

These below commands are run INSIDE of the docker image.

Enter the container:
```bash
docker exec -it luckfox-builder bash
```

Start the build:
```bash
/mnt/cfg/buildroot/add_package_buildroot.sh
```


This commands sets the build targets:
Select, Pico Pro Max, buildroot, and SPI.
```bash
# set build configuration
./build.sh lunch
```

This command allows us to choose what packages to install into our OS image.
```bash
# configure packages to install in buildroot
./build.sh buildrootconfig
```

![Buildroot Setup](../img/seedsigner-buildroot-setup.webp)


![Buildroot Package Selection](../img/seedsigner-buildroot-select.webp)

After selecting all the above packages, SAVE the configuration.
The configuration is saved at: `sysdrv/source/buildroot/buildroot-2023.02.6/.config`

You can sanity check your configuration to ensure the selected packages have been enabled like so:
```bash
cat sysdrv/source/buildroot/buildroot-2023.02.6/.config | grep "ZBAR"
cat sysdrv/source/buildroot/buildroot-2023.02.6/.config | grep "LIBJPEG"
...
```

A final sanity check, this shows all enabled packages... This might be useful as we try and remove any unnecessary packages from the build:
```bash
cat sysdrv/source/buildroot/buildroot-2023.02.6/.config | grep -v "^#"
```

### Adding Custom Packages
If you need to add custom packages to the buildroot configuration, you can use the `add_package_buildroot.sh` script. This script:
1. Adds SeedSigner-specific packages to the buildroot configuration
2. Copies necessary package files from the seedsigner-os repository
3. Updates Python paths and configurations
4. Adds required dependencies like python-pyzbar, python-embit, and camera-related packages

To use the script:
```bash
# From the buildroot directory
./add_package_buildroot.sh
```

This command will use one of the saved configurations for the build:
```bash
# Use config from repo
cp ../configs/config_20241218184332.config sysdrv/source/buildroot/buildroot-2023.02.6/.config

# Sanity check the configuration was loaded properly
# Selected packages like ZBAR should be listed as enabled here
./build.sh buildrootconfig
```

Start the image compilation process:
```bash
./build.sh uboot
./build.sh kernel
./build.sh rootfs
# needed for camera libs
./build.sh media
```

Verify all of the .img files are there:
```bash
$ ls /mnt/host/output/out/           
S20linkmount  media_out  rootfs_uclibc_rv1106  sysdrv_out

$ ls /mnt/host/output/image/
boot.img  download.bin  idblock.img  uboot.img
```

Copy over app code and pin configs
```bash
# Pin configs
cp /mnt/cfg/config/luckfox.cfg /mnt/host/output/out/rootfs_uclibc_rv1106/etc/luckfox.cfg

# Seedsigner code
cp -r /mnt/ss/src/ /mnt/host/output/out/rootfs_uclibc_rv1106/seedsigner
```

Package:
```bash
# Package up the pieces
./build.sh firmware
```

Double check the output, now all of the expected .img files are there:
```bash
$ ls /mnt/host/output/image/
boot.img  download.bin  env.img  idblock.img  oem.img  rootfs.img  sd_update.txt  tftp_update.txt  uboot.img  update.img  userdata.img
```

Final Piece of Sanity Checking:
```bash
dbg='yes' ./tools/linux/Linux_Upgrade_Tool/rkdownload.sh -d output/image/
```

Package into single flashable ISO image:
```bash
cd /mnt/host/output/image
/mnt/cfg/buildroot/blkenvflash seedsigner-luckfox-pico.img
```

Send back to dev machine (if building on a remote X86 machine):
```bash
scp ubuntu@11.22.33.44:/home/ubuntu/seedsigner-os/opt/luckfox/luckfox-pico/output/image/seedsigner-luckfox-pico.img ~/Downloads
```

Flash to MicroSD Card:
```bash
sudo dd bs=4M \
    status=progress \
    if=/Users/lightningspore/Downloads/seedsigner-luckfox-pico.img \
    of=/dev/disk8
```

Put MicroSD Card into Luckfox Pico Device.

```bash
adb shell
```

TODO: Link to next steup in the install/setup process

## Official resources

[Luckfox Pico Official Flashing Guide](https://wiki.luckfox.com/Luckfox-Pico/Linux-MacOS-Burn-Image/) - Official documentation for flashing images to the Luckfox Pico device on Linux and macOS systems



## Hardware Device Overlay Config
```
cat luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1103g-luckfox-pico.dts
cat luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1103.dtsi
cat luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1103-luckfox-pico-ipc.dtsi
cat luckfox-pico/sysdrv/source/kernel/arch/arm/boot/dts/rv1106-evb.dtsi
```