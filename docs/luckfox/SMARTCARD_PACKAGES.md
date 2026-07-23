# Smartcard Support Packages

This directory contains external buildroot packages for smartcard hardware wallet support in SeedSigner.

## Packages Included

### python-pyscard v2.3.1

**Description:** Python wrapper for PC/SC (Personal Computer/Smart Card) API  
**Purpose:** Low-level smartcard communication interface  
**Source:** https://github.com/LudovicRousseau/pyscard  
**License:** LGPL  
**Build System:** setuptools  

**Dependencies:**
- host-swig (build-time, for C wrapper generation)
- PC/SC middleware (runtime, provided by pcscd)

**Files:**
- `python-pyscard/Config.in` - Buildroot configuration option
- `python-pyscard/python-pyscard.mk` - Buildroot package makefile
- `python-pyscard/python-pyscard.hash` - Package integrity verification
- `python-pyscard/0001-drop-swig-from-pyproject.patch` - Remove swig from Python deps
- `python-pyscard/0002-skip-swig-check.patch` - Skip swig presence check

**Patches Explained:**

The pyscard package requires SWIG to generate Python-C bindings. However, it incorrectly tries to install swig as a Python package (which doesn't exist). The patches fix this:

1. **0001-drop-swig-from-pyproject.patch:** Removes swig from pyproject.toml build requirements since buildroot provides host-swig as a native tool
2. **0002-skip-swig-check.patch:** Skips the runtime check for swig on PATH, trusting buildroot's dependency management

### python-pysatochip v0.5-alpha

**Description:** Python API for Satochip hardware wallet devices  
**Purpose:** High-level interface for Satochip, Satodime, and Seedkeeper devices  
**Source:** https://github.com/3rdIteration/pysatochip  
**License:** LGPL  
**Build System:** setuptools  

**Dependencies:**
- python-pyscard (runtime, for smartcard communication)

**Files:**
- `python-pysatochip/Config.in` - Buildroot configuration option
- `python-pysatochip/python-pysatochip.mk` - Buildroot package makefile
- `python-pysatochip/python-pysatochip.hash` - Package integrity verification

## How External Packages Work

### Directory Structure

External packages in buildroot follow this structure:
```
external-packages/
├── python-pyscard/
│   ├── Config.in              # Menu configuration
│   ├── python-pyscard.mk      # Build instructions
│   ├── python-pyscard.hash    # SHA256 checksum
│   └── *.patch                # Source code patches
└── python-pysatochip/
    ├── Config.in
    ├── python-pysatochip.mk
    └── python-pysatochip.hash
```

### Integration with Build System

**1. Package Discovery:**

Buildroot discovers external packages through the `BR2_EXTERNAL_SEEDSIGNER_PATH` variable which points to this directory. The build scripts add menu entries:

```makefile
menu "SeedSigner"
    source "$BR2_EXTERNAL_SEEDSIGNER_PATH/package/python-pyscard/Config.in"
    source "$BR2_EXTERNAL_SEEDSIGNER_PATH/package/python-pysatochip/Config.in"
endmenu
```

**2. Configuration:**

In `buildroot/configs/luckfox_pico_defconfig`:
```
BR2_PACKAGE_PYTHON_PYSCARD=y
BR2_PACKAGE_PYTHON_PYSATOCHIP=y
```

**3. Build Process:**

When enabled, buildroot:
1. Downloads source from GitHub
2. Verifies SHA256 hash
3. Applies patches (if any)
4. Builds using setuptools
5. Installs to target rootfs

### Package Makefiles

The `.mk` files define how to build each package:

**python-pyscard.mk:**
```makefile
PYTHON_PYSCARD_VERSION = 2.3.1
PYTHON_PYSCARD_SITE = $(call github,LudovicRousseau,pyscard,$(PYTHON_PYSCARD_VERSION))
PYTHON_PYSCARD_SETUP_TYPE = setuptools
PYTHON_PYSCARD_LICENSE = LGPL
PYTHON_PYSCARD_DEPENDENCIES += host-swig
PYTHON_PYSCARD_ENV += SWIG="$(HOST_DIR)/bin/swig"

$(eval $(python-package))
```

**python-pysatochip.mk:**
```makefile
PYTHON_PYSATOCHIP_VERSION = 0.5-alpha
PYTHON_PYSATOCHIP_SITE = $(call github,3rdIteration,pysatochip,$(PYTHON_PYSATOCHIP_VERSION))
PYTHON_PYSATOCHIP_SETUP_TYPE = setuptools
PYTHON_PYSATOCHIP_LICENSE = LGPL

$(eval $(python-package))
```

## Installation Verification

After a successful build, verify the packages are installed:

**Check pyscard:**
```bash
# On the device
python3 -c "import smartcard; print(smartcard.__version__)"
python3 -c "from smartcard.System import readers; print(len(readers()))"
```

**Check pysatochip:**
```bash
# On the device
python3 -c "import pysatochip; print('pysatochip loaded successfully')"
```

**Verify file locations:**
```bash
# On the device
ls -la /usr/lib/python3.*/site-packages/smartcard/
ls -la /usr/lib/python3.*/site-packages/pysatochip/
```

## Troubleshooting

### Build Failures

**Error: "swig not found"**
- Cause: host-swig dependency missing
- Solution: Ensure `PYTHON_PYSCARD_DEPENDENCIES += host-swig` is in .mk file

**Error: "SHA256 mismatch"**
- Cause: Source tarball doesn't match expected hash
- Solution: Update hash in .hash file or verify source URL

**Error: "Cannot import smartcard"**
- Cause: Package not built or not installed to rootfs
- Solution: Check build logs, verify BR2_PACKAGE_PYTHON_PYSCARD=y in defconfig

### Runtime Issues

**Error: "No readers found"**
- Cause: PC/SC daemon (pcscd) not running or no smartcard reader connected
- Solution: Ensure hardware is connected and pcscd service is running

**Error: "SCardEstablishContext failed"**
- Cause: PC/SC middleware not available
- Solution: Install and start pcscd service (may need additional packages)

## Adding New External Packages

To add a new external package:

1. **Create package directory:**
   ```bash
   mkdir buildroot/external-packages/python-mypackage
   ```

2. **Create Config.in:**
   ```
   config BR2_PACKAGE_PYTHON_MYPACKAGE
       bool "python-mypackage"
       help
         Description of package
         https://github.com/user/repo
   ```

3. **Create package.mk:**
   ```makefile
   PYTHON_MYPACKAGE_VERSION = 1.0.0
   PYTHON_MYPACKAGE_SITE = $(call github,user,repo,$(PYTHON_MYPACKAGE_VERSION))
   PYTHON_MYPACKAGE_SETUP_TYPE = setuptools
   PYTHON_MYPACKAGE_LICENSE = MIT
   
   $(eval $(python-package))
   ```

4. **Create package.hash:**
   ```
   # From GitHub release or PyPI
   sha256 abc123... python-mypackage-1.0.0.tar.gz
   ```

5. **Add to defconfig:**
   ```
   BR2_PACKAGE_PYTHON_MYPACKAGE=y
   ```

6. **Add to build script menus:**
   ```
   source "$BR2_EXTERNAL_SEEDSIGNER_PATH/package/python-mypackage/Config.in"
   ```

## References

- **Buildroot Manual:** https://buildroot.org/downloads/manual/manual.html
- **Python Package Infrastructure:** https://buildroot.org/downloads/manual/manual.html#_infrastructure_for_python_packages
- **BR2_EXTERNAL:** https://buildroot.org/downloads/manual/manual.html#outside-br-custom
- **pyscard Documentation:** https://pyscard.sourceforge.io/
- **Satochip Documentation:** https://satochip.io/

## License

These external packages are separately licensed:
- **python-pyscard:** LGPL (see package source)
- **python-pysatochip:** LGPL (see package source)

The integration files (Config.in, .mk files, patches) are part of the seedsigner-luckfox-pico repository.
