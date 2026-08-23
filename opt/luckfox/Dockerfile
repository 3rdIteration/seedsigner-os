# SeedSigner Self-Contained Build - No Home Directory Pollution!
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive

# Install all required packages including ca-certificates for git cloning
RUN apt-get update && \
    apt-get install -y \
        build-essential \
        curl \
        git \
        python3 \
        python3-pip \
        # compile-translations.sh builds a venv to run the app's compile_catalog.
        # Without python3-venv it degrades to "English-only" and says so in one
        # line that scrolls past -- a Docker build silently shipped an image with
        # no translations while CI shipped one with all of them.
        python3-venv \
        ssh \
        make gcc \
        gcc-multilib g++-multilib \
        module-assistant expect g++ gawk \
        texinfo libssl-dev bison flex \
        fakeroot cmake unzip gperf autoconf \
        device-tree-compiler libncurses5-dev \
        pkg-config bc python-is-python3 passwd openssl \
        openssh-server openssh-client vim file cpio rsync \
        # rust-toolchain-cache.sh packs the host Rust toolchain with
        # `tar --zstd`, which shells out to the zstd binary. The CI runner
        # image happens to ship it; this base image does not, so without it
        # the cache silently fails to write and every build recompiles LLVM.
        zstd \
        ca-certificates \
        && \
    rm -rf /var/lib/apt/lists/*

# Set working directory for self-contained builds
WORKDIR /build

# Create directories for all components
RUN mkdir -p /build/repos /build/output

# Copy build scripts and configuration files
COPY configs/ /build/configs/
COPY files/ /build/files/
COPY scripts/ /build/scripts/
COPY blkenvflash /build/
# The SDK revision pin, read by prepare-sdk-checkout.sh from its own directory.
# NOT covered by the `COPY *.sh` below -- it is data, not a script -- so it needs
# its own line. Leaving it out makes every build fail at the clone step with
# "no SDK revision pinned"; assert_shared_build_files() in os-build.sh now
# catches it up front instead.
COPY SDK_COMMIT /build/


# Make scripts executable
RUN chmod +x /build/*.sh /build/blkenvflash 2>/dev/null || true

# Set up git configuration (required for cloning repositories inside container)
RUN git config --global user.email "build@seedsigner.luckfox" && \
    git config --global user.name "SeedSigner Build"

# Create required files for SDK toolchain
RUN touch /root/.bash_profile

SHELL ["/bin/bash", "-c"]

# Copy build automation script AND every shared *.sh alongside it.
#
# Only os-build.sh used to be copied, so none of the scripts it calls
# (apply-partition-layout.sh, strip-kernel-network.sh, readonly-rootfs.sh,
# harden-nondev.sh, optimize-nondev.sh, ...) existed inside the container. The
# call sites wrapped in `[[ -f ... ]]` therefore SILENTLY SKIPPED — a Docker
# build produced an image with the hardening simply absent and said nothing.
# The unguarded ones failed outright, which is how this was finally noticed.
#
# A glob, not a list, so adding a shared script cannot silently fail to reach
# the container. Copied last to keep the expensive apt layers cached.
COPY *.sh /build/
RUN chmod +x /build/*.sh

# Set the entrypoint
ENTRYPOINT ["/build/os-build.sh"]
CMD ["auto"]
