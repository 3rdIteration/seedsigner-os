#!/usr/bin/env bash
#
# rust-toolchain-cache.sh <restore|package> <LUCKFOX_PICO_DIR> <TARBALL>
#
# Save and restore Buildroot's host Rust toolchain across builds. Shared by CI
# (build-luckfox.yml) and both local builds -- change this script, never one
# caller.
#
# WHY THIS EXISTS: python-cryptography needs Rust, and the Luckfox toolchain is
# uclibc, which is a Tier 3 Rust target with no prebuilt std. Buildroot therefore
# builds host-rust FROM SOURCE, which means building LLVM -- comfortably the
# longest single step in the whole build, and enough on its own to push a job
# past the 240-minute CI timeout.
#
# CI has always cached it, but the cache lived as two inline workflow steps, so
# the Docker path had no equivalent: os-build.sh's own header says the Docker
# build "never caches a toolchain the way CI does" and sizes its job count
# around compiling LLVM every time. That is the single biggest reason CI could
# not simply run the Docker build. Extracting it here is what makes that
# possible, and it stops the cache logic from being CI-only knowledge.
#
# The tarball deliberately lives OUTSIDE the SDK tree. prepare-sdk-checkout.sh
# wipes the SDK to a pristine state before every build (see the account there),
# so anything stored inside it would not survive -- and a toolchain that only
# survives by leaving the tree dirty is a reproducibility problem, not a cache.
#
# WHAT IS CACHED is a toolchain BINARY, not build output that lands in the
# image: rustc/cargo, host/lib/rustlib, the shared libs rustc needs at runtime,
# and the Buildroot .stamp_* files that tell Buildroot the package is already
# installed. A given SDK revision pins the Buildroot revision and therefore the
# Rust version, so callers must key the cache on the SDK commit as well as the
# defconfig -- keying on the defconfig alone can serve a toolchain built from a
# different Buildroot.

set -eu

MODE="${1:-}"
LUCKFOX_DIR="${2:-}"
CACHE_TAR="${3:-}"

if [ -z "$MODE" ] || [ -z "$LUCKFOX_DIR" ] || [ -z "$CACHE_TAR" ]; then
    echo "usage: rust-toolchain-cache.sh <restore|package> <LUCKFOX_PICO_DIR> <TARBALL>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_buildroot() {
    if [ -x "$SCRIPT_DIR/resolve-buildroot-dir.sh" ] || [ -f "$SCRIPT_DIR/resolve-buildroot-dir.sh" ]; then
        bash "$SCRIPT_DIR/resolve-buildroot-dir.sh" "$LUCKFOX_DIR" 2>/dev/null && return 0
    fi
    # Same discovery rule as resolve-buildroot-dir.sh, for the case where this
    # script is used standalone.
    find "$LUCKFOX_DIR/sysdrv/source/buildroot" -maxdepth 1 -type d -name 'buildroot-*' 2>/dev/null |
        sort | tail -n 1
}

BUILDROOT_DIR="$(resolve_buildroot || true)"
if [ -z "$BUILDROOT_DIR" ] || [ ! -d "$BUILDROOT_DIR" ]; then
    # Not fatal: a cache is an optimisation. Restoring before `buildroot_create`
    # or packaging after a failed build should skip, not kill the build.
    echo "rust-toolchain-cache: no buildroot tree under $LUCKFOX_DIR -- skipping ($MODE)"
    exit 0
fi

STAMPS=".stamp_downloaded .stamp_extracted .stamp_patched .stamp_configured .stamp_built .stamp_host_installed"

# Buildroot names the Rust package directories after the version, which we do
# not know up front, so every call site globs for them.
rust_pkg_dirs() {
    echo "$BUILDROOT_DIR"/output/build/host-rust-bin-* \
         "$BUILDROOT_DIR"/output/build/host-rust-[0-9]* \
         "$BUILDROOT_DIR"/output/build/host-rustc
}

toolchain_works() {
    [ -x "$BUILDROOT_DIR/output/host/bin/rustc" ] &&
    [ -x "$BUILDROOT_DIR/output/host/bin/cargo" ] &&
    "$BUILDROOT_DIR/output/host/bin/rustc" --version >/dev/null 2>&1
}

case "$MODE" in

restore)
    if [ ! -f "$CACHE_TAR" ]; then
        echo "rust-toolchain-cache: no cache at $CACHE_TAR -- Rust will be built from source"
        exit 0
    fi

    echo "🦀 Restoring cached Rust toolchain into $BUILDROOT_DIR ..."
    mkdir -p "$BUILDROOT_DIR/output"
    if ! tar --zstd -xf "$CACHE_TAR" -C "$BUILDROOT_DIR/output"; then
        echo "⚠️  cache tarball is unreadable -- Rust will be built from source" >&2
        exit 0
    fi

    RUST_VERSION=""
    if [ -x "$BUILDROOT_DIR/output/host/bin/rustc" ]; then
        RUST_VERSION="$("$BUILDROOT_DIR/output/host/bin/rustc" --version 2>/dev/null |
                        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    fi

    # Fabricate the stamp files so Buildroot treats the Rust packages as already
    # built and installed, and skips them entirely.
    PKG_DIRS="$BUILDROOT_DIR/output/build/host-rustc"
    if [ -n "$RUST_VERSION" ]; then
        PKG_DIRS="$PKG_DIRS $BUILDROOT_DIR/output/build/host-rust-bin-$RUST_VERSION"
        PKG_DIRS="$PKG_DIRS $BUILDROOT_DIR/output/build/host-rust-$RUST_VERSION"
    fi
    for pkg_dir in $PKG_DIRS; do
        if [ -d "$pkg_dir" ] && [ -f "$pkg_dir/.stamp_host_installed" ]; then
            echo "  stamps already present in $(basename "$pkg_dir")"
            continue
        fi
        mkdir -p "$pkg_dir"
        for s in $STAMPS; do : > "$pkg_dir/$s"; done
        echo "  created stamps for $(basename "$pkg_dir")"
    done

    if toolchain_works; then
        echo "✅ cached Rust toolchain restored: $("$BUILDROOT_DIR/output/host/bin/rustc" --version)"
        exit 0
    fi

    # A half-restored toolchain is worse than none: the stamps would tell
    # Buildroot to skip building a rustc that cannot run. Undo everything and
    # let it build from source. Globs, not $RUST_VERSION -- that variable is
    # empty precisely when `rustc --version` failed.
    echo "⚠️  cached toolchain is missing binaries or libraries -- rebuilding from source" >&2
    for pkg_dir in $(rust_pkg_dirs); do
        if [ -d "$pkg_dir" ]; then
            rm -f "$pkg_dir"/.stamp_*
            echo "  removed stamps from $(basename "$pkg_dir")"
        fi
    done
    rm -rf "$BUILDROOT_DIR/output/host/bin/rustc" \
           "$BUILDROOT_DIR/output/host/bin/cargo" \
           "$BUILDROOT_DIR/output/host/lib/rustlib" 2>/dev/null || true
    exit 0
    ;;

package)
    if ! toolchain_works; then
        echo "rust-toolchain-cache: no usable rustc in $BUILDROOT_DIR/output/host/bin -- nothing to cache"
        exit 0
    fi

    echo "📦 Packaging Rust toolchain for future builds..."
    "$BUILDROOT_DIR/output/host/bin/rustc" --version

    STAMP_FILES=""
    for d in $(rust_pkg_dirs); do
        if [ -d "$d" ]; then
            STAMP_FILES="$STAMP_FILES $(find "$d" -maxdepth 1 -name '.stamp_*' -type f)"
        fi
    done

    # Paths inside the tarball are relative to output/, matching where restore
    # untars it.
    cd "$BUILDROOT_DIR/output"
    FILE_LIST="$(mktemp)"
    {
        for f in host/bin/rustc host/bin/cargo host/bin/rustdoc host/bin/rust-gdb \
                 host/bin/rust-gdbgui host/bin/rust-lldb; do
            [ -e "$f" ] && echo "$f"
        done
        [ -d host/lib/rustlib ] && find host/lib/rustlib \( -type f -o -type l \)
        # rustc dynamically links these; without them the restored toolchain
        # runs on the cache-writing machine and nowhere else.
        find host/lib -maxdepth 1 \
            \( -name 'librustc_driver-*.so' -o -name 'libstd-*.so' \
               -o -name 'libtest-*.so' -o -name 'libLLVM-*.so' \) \
            \( -type f -o -type l \) 2>/dev/null || true
        # Stamp paths are absolute; make them relative to output/.
        for s in $STAMP_FILES; do
            case "$s" in
                "$BUILDROOT_DIR/output/"*) echo "${s#"$BUILDROOT_DIR/output/"}" ;;
            esac
        done
    } | sort -u > "$FILE_LIST"

    echo "  files to package: $(wc -l < "$FILE_LIST")"
    mkdir -p "$(dirname "$CACHE_TAR")"
    tar --zstd -cf "$CACHE_TAR" --files-from="$FILE_LIST"
    rm -f "$FILE_LIST"
    ls -lh "$CACHE_TAR"
    echo "✅ Rust toolchain cached at $CACHE_TAR"
    ;;

*)
    echo "rust-toolchain-cache: unknown mode '$MODE' (use restore|package)" >&2
    exit 1
    ;;
esac
