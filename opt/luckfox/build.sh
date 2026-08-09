#!/bin/bash
# SeedSigner Build Script - Self-Contained and Portable
# No home directory pollution, no docker-compose, just simple Docker

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="seedsigner-builder"
CONTAINER_NAME="seedsigner-build-$(date +%s)"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

print_header() { echo -e "${BLUE}=== $1 ===${NC}"; }
print_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
print_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
print_error() { echo -e "${RED}[ERROR] $1${NC}"; }

show_usage() {
    cat << 'USAGE'
SeedSigner Self-Contained Build System

Usage: ./build.sh [command] [options]

Commands:
  build       - Run full automated build (artifacts automatically available)
  interactive - Start container in interactive mode  
  shell       - Start container with direct shell access
  clean       - Clean build artifacts and containers
  status      - Show build system status

Options:
  --help, -h     - Show this help
  --force        - Force rebuild of Docker image
  --jobs, -j N   - Set number of parallel build jobs
  --output DIR   - Set output directory (default: ./build-output)
  --nand         - Build NAND-flashable system image artifacts
  --microsd      - Build MicroSD image artifacts
  --model TARGET - Target model: mini|max|pi|both (default: both)

Build-shaping options (mirror the GitHub Actions workflow inputs of the same
name, so a local build can reproduce what CI ships):
  --variant V           - non-dev (hardened) | dev (serial console + adb)
                          (default: non-dev)
  --readonly-rootfs V   - auto|on|off. Read-only squashfs root with tmpfs
                          overlays; auto = on for non-dev (default: auto)
  --usb-mode V          - auto|gadget|host|otg (default: auto)
  --debug-network V     - auto|on|off (default: auto)
  --seedsigner-ref R    - SeedSigner app branch, RELEASE TAG or commit
                          (default: dev). --seedsigner-branch is an alias.

Examples:
  ./build.sh build             # Standard build (artifacts in ./build-output)
  ./build.sh build --jobs 8    # Use 8 parallel jobs
  ./build.sh interactive       # Debug build issues
  ./build.sh status            # Check volume and image status

  # Reproduce the CI shipping image for the Pro Max on MicroSD:
  ./build.sh build --model max --microsd --variant non-dev --readonly-rootfs on

  # Build against a release tag:
  ./build.sh build --model max --microsd --seedsigner-ref SeSi-0.8.7+ShSi-B11

Build Output:
  - Build artifacts are automatically available in the output directory
  - Artifacts appear immediately after build completes
  - Perfect for GitHub Actions and CI/CD systems

Repository Persistence:
  - First build: Clones repos to Docker volume 'seedsigner-repos'
  - Subsequent builds: Reuses existing repos (much faster!)
  - Clean with volume removal: Forces complete re-clone

Performance:
  First build:  30-90 min (clones ~500MB+ of repos)
  Later builds: 15-45 min (reuses persistent repos)

Fast subsequent builds! ⚡
USAGE
}

check_docker() {
    print_header "Checking Docker"
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker not installed"
        exit 1
    fi
    
    if ! docker version &> /dev/null; then
        print_error "Docker not running"
        exit 1
    fi
    
    # Architecture check
    ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        print_error "ARM64 Macs not supported due to Docker emulation issues"
        echo "Use GitHub Actions or x86_64 machine for building"
        exit 1
    fi
    
    PLATFORM_ARGS=""
    print_success "Docker available"
}

build_docker_image() {
    local force_rebuild="$1"
    print_header "Building Docker Image"
    
    cd "$SCRIPT_DIR"
    
    local build_args="$PLATFORM_ARGS -t $IMAGE_NAME ."
    
    if [[ "$force_rebuild" == "true" ]]; then
        build_args="--no-cache $build_args"
        print_warning "Force rebuilding Docker image..."
    fi
    
    docker build $build_args
    print_success "Docker image built: $IMAGE_NAME"
}

run_build() {
    local mode="$1"
    local build_jobs="$2"
    local output_dir="${3:-./build-output}"
    local build_nand="${4:-false}"
    local build_microsd="${5:-false}"
    local build_model="${6:-both}"
    
    print_header "Running Build ($mode)"
    
    # Ensure output directory exists
    mkdir -p "$output_dir"
    local abs_output_dir=$(realpath "$output_dir")
    
    # Create or use existing Docker volume for repositories
    local volume_name="seedsigner-repos"
    if ! docker volume ls | grep -q "$volume_name"; then
        print_success "Creating Docker volume for persistent repositories: $volume_name"
        docker volume create "$volume_name"
    else
        print_success "Using existing repository volume: $volume_name"
    fi
    
    # Set up build environment variables
    local env_args="-e BUILD_MODEL=$build_model"
    if [[ -n "$build_jobs" ]]; then
        env_args="-e BUILD_JOBS=$build_jobs -e BUILD_MODEL=$build_model"
        print_success "Using $build_jobs parallel build jobs"
    fi

    # Forward the build-shaping variables into the container. Only BUILD_MODEL and
    # BUILD_JOBS used to cross the boundary, so a Docker build silently took
    # os-build.sh's defaults for the variant, USB role, network and rootfs mode no
    # matter what the caller asked for -- the local build could not reproduce a CI
    # image. `docker run -e VAR` with no value passes the host's value through and
    # omits the variable entirely when it is unset, so os-build.sh's own defaults
    # still apply when nothing is specified.
    local passthrough
    for passthrough in SEEDSIGNER_BUILD_VARIANT SEEDSIGNER_READONLY_ROOTFS \
                       SEEDSIGNER_USB_MODE SEEDSIGNER_DEBUG_NETWORK \
                       SEEDSIGNER_HARDEN_ADB SEEDSIGNER_REPO_URL \
                       SEEDSIGNER_REF SEEDSIGNER_BRANCH; do
        if [[ -n "${!passthrough:-}" ]]; then
            env_args="$env_args -e $passthrough=${!passthrough}"
            print_success "$passthrough=${!passthrough}"
        fi
    done
    
    # Mount this repo's converged SeedSigner Buildroot packages (a single
    # toolchain-aware set under opt/external-packages) so the container does not
    # need to clone seedsigner-os.
    local external_packages_dir
    external_packages_dir="$(cd "$SCRIPT_DIR/../external-packages" && pwd)"
    if [[ ! -d "$external_packages_dir" ]]; then
        print_error "external-packages not found at $external_packages_dir"
        print_error "Run build.sh from within a seedsigner-os checkout (opt/luckfox/)."
        exit 1
    fi

    # Mount the shared OS-release generator so os-build.sh can stamp provenance.
    local gen_os_release="$(cd "$SCRIPT_DIR/.." && pwd)/gen-os-release.sh"
    local gen_os_release_arg=""
    if [[ -f "$gen_os_release" ]]; then
        gen_os_release_arg="-v $gen_os_release:/build/gen-os-release.sh:ro"
    fi

    # Docker run arguments with persistent volume
    local docker_args="$PLATFORM_ARGS
                       --name $CONTAINER_NAME
                       --rm
                       -v $volume_name:/build/repos
                       -v $abs_output_dir:/build/output
                       -v $external_packages_dir:/build/external-packages:ro
                       $gen_os_release_arg
                       $env_args"
    
    case "$mode" in
        "build")
            print_success "Starting automated build..."
            if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
                print_warning "ARM64 build will take 60-120 minutes due to emulation"
            else
                print_warning "Build will take 30-90 minutes"
            fi
            print_success "Repository volume: $volume_name (persists between builds)"
            print_success "Output directory: $abs_output_dir (artifacts automatically available)"
            local container_mode=""
            if [[ "$build_nand" == "true" && "$build_microsd" == "true" ]]; then
                container_mode="auto-nand"
                print_success "NAND + MicroSD artifact generation enabled"
            elif [[ "$build_nand" == "true" ]]; then
                container_mode="auto-nand-only"
                print_success "NAND-only artifact generation enabled"
            elif [[ "$build_microsd" == "true" ]]; then
                container_mode="auto"
                print_success "MicroSD artifact generation enabled"
            else
                print_error "No artifact type selected. Use --microsd and/or --nand"
                exit 1
            fi
            docker run $docker_args "$IMAGE_NAME" "$container_mode"
            print_success "Build completed! Artifacts are available in: $abs_output_dir"
            ;;
        "interactive")
            print_success "Starting interactive mode..."
            print_success "Repository volume: $volume_name (persists between sessions)"
            docker run -it $docker_args "$IMAGE_NAME" interactive
            ;;
        "shell")
            print_success "Starting direct shell..."
            print_success "Repository volume: $volume_name (persists between sessions)"
            docker run -it $docker_args "$IMAGE_NAME" shell
            ;;
        *)
            print_error "Unknown mode: $mode"
            exit 1
            ;;
    esac
}

clean_environment() {
    print_header "Cleaning Environment"
    
    # Stop and remove any running containers
    if docker ps -a --format "{{.Names}}" | grep -q "seedsigner-build"; then
        print_warning "Stopping existing build containers..."
        docker ps -a --format "{{.Names}}" | grep "seedsigner-build" | xargs docker rm -f
    fi
    
    # Remove Docker volume if requested
    local volume_name="seedsigner-repos"
    if docker volume ls | grep -q "$volume_name"; then
        read -p "Remove persistent repository volume '$volume_name'? This will force re-cloning repos (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            docker volume rm "$volume_name" 2>/dev/null || print_warning "Volume cleanup failed"
            print_success "Repository volume removed - repos will be re-cloned on next build"
        else
            print_success "Repository volume preserved - faster subsequent builds"
        fi
    fi
    
    # Remove image if requested
    read -p "Remove Docker image '$IMAGE_NAME'? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker rmi "$IMAGE_NAME" 2>/dev/null || print_warning "Image not found"
        print_success "Docker image removed"
    fi
    
    # Clean build output
    read -p "Remove build-output directory? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf build-output
        print_success "Build output removed"
    fi
    
    print_success "Environment cleaned"
}

show_status() {
    print_header "Build System Status"
    
    echo "Script directory: $SCRIPT_DIR"
    echo "Architecture: $(uname -m)"
    echo "Platform args: ${PLATFORM_ARGS:-none}"
    
    # Check Docker image
    if docker images | grep -q "$IMAGE_NAME"; then
        print_success "Docker image '$IMAGE_NAME' exists"
        docker images | grep "$IMAGE_NAME"
    else
        print_warning "Docker image '$IMAGE_NAME' not built yet"
    fi
    
    # Check Docker volume for repositories
    local volume_name="seedsigner-repos"
    if docker volume ls | grep -q "$volume_name"; then
        print_success "Repository volume '$volume_name' exists (persistent repos)"
        # Try to get volume info
        local volume_info=$(docker volume inspect "$volume_name" 2>/dev/null | grep '"Mountpoint"' | cut -d'"' -f4)
        echo "  Volume path: ${volume_info:-unknown}"
    else
        print_warning "Repository volume '$volume_name' not created yet"
        echo "  First build will clone repos and create volume"
    fi
    
    # Check for running containers
    local running=$(docker ps --format "{{.Names}}" | grep "seedsigner-build" | head -1)
    if [[ -n "$running" ]]; then
        print_success "Build container running: $running"
    fi
    
    # Check for build output
    if [[ -d "build-output" ]] && [[ "$(ls -A build-output 2>/dev/null)" ]]; then
        print_success "Build output exists:"
        ls -la build-output/ | head -5
    else
        print_warning "No build output found"
    fi
}

# Main script logic
main() {
    local command="${1:-build}"
    local force_rebuild=false
    local build_jobs=""
    local output_dir=""
    local build_nand=false
    local build_microsd=false
    local build_model="both"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_usage
                exit 0
                ;;
            --force)
                force_rebuild=true
                shift
                ;;
            --jobs|-j)
                if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
                    build_jobs="$2"
                    shift 2
                else
                    print_error "Invalid or missing argument for --jobs"
                    exit 1
                fi
                ;;
            --output)
                if [[ -n "$2" ]]; then
                    output_dir="$2"
                    shift 2
                else
                    print_error "Missing argument for --output"
                    exit 1
                fi
                ;;
            --nand)
                build_nand=true
                shift
                ;;
            --microsd)
                build_microsd=true
                shift
                ;;
            --model)
                # os-build.sh has always understood BUILD_MODEL=pi; only this
                # wrapper rejected it, so the Pico Pi could be built in CI but not
                # locally.
                if [[ -n "$2" && "$2" =~ ^(mini|max|pi|both)$ ]]; then
                    build_model="$2"
                    shift 2
                else
                    print_error "Invalid or missing argument for --model (use: mini|max|pi|both)"
                    exit 1
                fi
                ;;
            # The build-shaping options below mirror the GitHub Actions inputs of
            # the same names. Without them a local build could not produce the
            # image CI produces -- it always got the defaults.
            --variant)
                if [[ -n "$2" && "$2" =~ ^(non-dev|dev)$ ]]; then
                    export SEEDSIGNER_BUILD_VARIANT="$2"; shift 2
                else
                    print_error "Invalid or missing argument for --variant (use: non-dev|dev)"; exit 1
                fi
                ;;
            --readonly-rootfs)
                if [[ -n "$2" && "$2" =~ ^(auto|on|off)$ ]]; then
                    export SEEDSIGNER_READONLY_ROOTFS="$2"; shift 2
                else
                    print_error "Invalid or missing argument for --readonly-rootfs (use: auto|on|off)"; exit 1
                fi
                ;;
            --usb-mode)
                if [[ -n "$2" && "$2" =~ ^(auto|gadget|host|otg)$ ]]; then
                    export SEEDSIGNER_USB_MODE="$2"; shift 2
                else
                    print_error "Invalid or missing argument for --usb-mode (use: auto|gadget|host|otg)"; exit 1
                fi
                ;;
            --debug-network)
                if [[ -n "$2" && "$2" =~ ^(auto|on|off)$ ]]; then
                    export SEEDSIGNER_DEBUG_NETWORK="$2"; shift 2
                else
                    print_error "Invalid or missing argument for --debug-network (use: auto|on|off)"; exit 1
                fi
                ;;
            # A ref is a branch, a release tag, or a commit -- `git clone -b`
            # accepts all three. --seedsigner-branch is kept as an alias because
            # it is what the CI input is still called.
            --seedsigner-ref|--seedsigner-branch)
                if [[ -n "$2" ]]; then
                    export SEEDSIGNER_REF="$2"; shift 2
                else
                    print_error "Missing argument for $1"; exit 1
                fi
                ;;
            *)
                if [[ -z "${command_set:-}" ]]; then
                    command="$1"
                    command_set=true
                fi
                shift
                ;;
        esac
    done
    
    # Set default output directory if not specified
    output_dir="${output_dir:-./build-output}"
    
    # Always check Docker for most commands
    if [[ "$command" != "status" ]]; then
        check_docker
    fi
    
    case "$command" in
        "status")
            show_status
            ;;
        "build")
            build_docker_image "$force_rebuild"
            run_build "build" "$build_jobs" "$output_dir" "$build_nand" "$build_microsd" "$build_model"
            ;;
        "interactive")
            build_docker_image "$force_rebuild"
            run_build "interactive" "$build_jobs" "$output_dir"
            ;;
        "shell")
            build_docker_image "$force_rebuild"
            run_build "shell" "$build_jobs" "$output_dir"
            ;;
        "clean")
            clean_environment
            ;;
        *)
            print_error "Unknown command: $command"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"
