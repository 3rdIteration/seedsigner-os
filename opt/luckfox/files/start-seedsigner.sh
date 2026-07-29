#!/bin/bash

# Configuration
MAX_RETRIES=5
RETRY_DELAY=10  # seconds
CAMERA_START_TIMEOUT=20  # max seconds to wait for app init signal
CAMERA_POLL_INTERVAL=1   # seconds
CAMERA_POST_SPI_DELAY=10  # seconds to wait after SPI init detection
BOOT_WATCHDOG_TIMEOUT=120  # seconds; fall into Loader mode if the app never signals ready
LOG_FILE="/tmp/startup.log"
READY_FILE="/tmp/seedsigner-ready"  # written by the app (MainMenuView) once it is up
APP_PID=""
CAMERA_HELPER_PID=""
BOOT_WATCHDOG_PID=""

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Function to cleanup on exit
cleanup() {
    log_message "Stopping SeedSigner..."
    if [ -n "$BOOT_WATCHDOG_PID" ]; then
        kill "$BOOT_WATCHDOG_PID" 2>/dev/null || true
    fi
    if [ -n "$CAMERA_HELPER_PID" ]; then
        kill "$CAMERA_HELPER_PID" 2>/dev/null || true
    fi
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
    fi
    killall rkipc 2>/dev/null
    exit 0
}

start_camera_service() {
    local camera_service="/usr/bin/rkaiq-service"
    if [ ! -x "$camera_service" ]; then
        log_message "rkaiq service script not found at $camera_service; continuing"
        return 0
    fi

    log_message "Starting camera ISP service (rkaiq-service)..."
    "$camera_service" start >/dev/null 2>&1 || "$camera_service" restart >/dev/null 2>&1 || true
    sleep 2
}

stop_camera_service() {
    local camera_service="/usr/bin/rkaiq-service"
    if [ ! -x "$camera_service" ]; then
        log_message "rkaiq service script not found at $camera_service; continuing"
        return 0
    fi

    log_message "Stopping camera ISP service (rkaiq-service)..."
    "$camera_service" stop >/dev/null 2>&1 || true
    sleep 1
}

release_conflicting_gpio_lines() {
    # Release legacy sysfs-exported lines that conflict with libgpiod/periphery.
    # On Luckfox Pico Mini, KEY_RIGHT uses global line 4 (gpiochip0 line 4).
    for line in 4; do
        if [ -d "/sys/class/gpio/gpio${line}" ]; then
            echo "${line}" > /sys/class/gpio/unexport 2>/dev/null || true
            if [ -d "/sys/class/gpio/gpio${line}" ]; then
                log_message "GPIO line ${line} still exported via sysfs"
            else
                log_message "Unexported sysfs GPIO line ${line}"
            fi
        fi
    done
}

start_camera_service_later() {
    local target_pid="$1"
    local post_spi_delay="$2"
    (
        local waited=0
        while [ "$waited" -lt "$CAMERA_START_TIMEOUT" ]; do
            if ! kill -0 "$target_pid" 2>/dev/null; then
                return 0
            fi

            # Wait for SeedSigner to initialize the SPI display first.
            if ls -l "/proc/$target_pid/fd" 2>/dev/null | grep -q 'spidev'; then
                log_message "Detected SeedSigner SPI device init; waiting ${post_spi_delay}s before starting camera service"
                sleep "$post_spi_delay"
                if kill -0 "$target_pid" 2>/dev/null; then
                    start_camera_service
                fi
                return 0
            fi

            sleep "$CAMERA_POLL_INTERVAL"
            waited=$((waited + CAMERA_POLL_INTERVAL))
        done

        if kill -0 "$target_pid" 2>/dev/null; then
            log_message "SeedSigner init signal not detected after ${CAMERA_START_TIMEOUT}s; starting camera service anyway"
            start_camera_service
        fi
    ) &
    CAMERA_HELPER_PID="$!"
}

ensure_gpiochip_symlinks() {
    # On some LuckFox Pico variants the kernel omits one or more GPIO banks from
    # the device tree, shifting gpiochip numbers downward.  Any profile that
    # references /dev/gpiochip4 (e.g. FOX_PI KEY1, or future FOX_22 configs)
    # needs a symlink pointing at the real chip device.
    if [ -e /dev/gpiochip4 ]; then
        return 0
    fi

    local model=""
    if [ -f /proc/device-tree/model ]; then
        model=$(tr -d '\0' < /proc/device-tree/model | tr '[:upper:]' '[:lower:]')
    fi

    case "$model" in
        *"luckfox pico mini"*)
            # On Mini, GPIO2 bank is absent from the device tree so gpiochip
            # numbers shift by one: GPIO4 is always registered as gpiochip3.
            # Create the symlink directly — no sysfs scanning needed.
            if [ -c /dev/gpiochip3 ]; then
                log_message "Creating /dev/gpiochip4 -> /dev/gpiochip3 (Mini: GPIO4 bank shifted to chip3)"
                ln -sf /dev/gpiochip3 /dev/gpiochip4
                return 0
            fi
            log_message "WARNING: /dev/gpiochip3 not found on Mini; cannot create /dev/gpiochip4 symlink"
            return 0
            ;;
    esac

    # For other variants (e.g. Pi), find the GPIO4 bank dynamically via sysfs.
    local sysdir chip devname label

    # Primary: platform device path anchored to GPIO4's fixed hardware address
    # (0xff560000) — reliable regardless of chip numbering or driver label.
    for sysdir in /sys/devices/platform/ff560000.gpio/gpio/gpiochip*/; do
        [ -d "$sysdir" ] || continue
        chip=$(basename "$sysdir")
        devname="/dev/${chip}"
        if [ -c "$devname" ]; then
            log_message "Creating /dev/gpiochip4 -> $devname (GPIO4 bank via platform path)"
            ln -sf "$devname" /dev/gpiochip4
            return 0
        fi
    done

    # Fallback: scan /sys/class/gpio by label.  The Rockchip GPIO driver
    # labels each chip with its DT node name (e.g. "ff560000.gpio") or the
    # DT alias (e.g. "gpio4").
    for sysdir in /sys/class/gpio/gpiochip*/; do
        [ -d "$sysdir" ] || continue
        label=$(cat "$sysdir/label" 2>/dev/null || true)
        case "$label" in
            *ff560*|*gpio4*)
                chip=$(basename "$sysdir")
                devname="/dev/${chip}"
                if [ -c "$devname" ]; then
                    log_message "Creating /dev/gpiochip4 -> $devname (GPIO4 bank label='$label')"
                    ln -sf "$devname" /dev/gpiochip4
                    return 0
                fi
                ;;
        esac
    done

    log_message "WARNING: GPIO4 bank gpiochip not found; /dev/gpiochip4 unavailable — KEY1 may not work on Pi"
}

bootstrap_camera_graph() {
    # Some builds only create a usable ISP graph after rkipc performs early init.
    if ls /dev/v4l-subdev* >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v rkipc >/dev/null 2>&1; then
        log_message "rkipc not found; skipping camera graph bootstrap"
        return 0
    fi

    log_message "Bootstrapping camera graph via temporary rkipc start..."
    if [ -d "/oem/usr/share/iqfiles" ]; then
        rkipc -a /oem/usr/share/iqfiles >/tmp/rkipc-bootstrap.log 2>&1 &
    else
        rkipc >/tmp/rkipc-bootstrap.log 2>&1 &
    fi
    sleep 3
    killall rkipc 2>/dev/null || true
    sleep 1
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Ensure the kernel hostname matches what the SeedSigner app expects. This is a
# sethostname() call (no disk write) so it is safe even on a full rootfs, and it
# guarantees SeedSigner-OS platform detection regardless of whether the SDK init
# applied /etc/hostname.
hostname seedsigner-os 2>/dev/null || true

# Boot-failover (non-dev). U-Boot carries a memory-backed boot counter
# (CONFIG_SYS_BOOTCOUNT_ADDR = GRF OS_REG scratch register 0xFF020218, enabled in the
# U-Boot board header) that increments on every boot; once it exceeds bootlimit, U-Boot
# runs altbootcmd to enter rockusb Loader mode for re-flashing — no BOOT button, ADB, or
# working app needed. Reaching userspace here is the "healthy enough" signal, so clear the
# counter now; only boots that never get this far (kernel panic / rootfs-mount / init
# failure) accumulate toward the limit. The register survives a warm reset (a panic reboot
# loop) and clears on a cold power-cycle, so Loader is never a permanent dead-end.
# bootlimit=5 and altbootcmd are compiled into U-Boot's DEFAULT env (this U-Boot is
# built ENV_IS_NOWHERE and never reads the mtd0 env, so fw_setenv would be ignored —
# see build-luckfox.yml). Nothing to provision here; userspace only has to CLEAR the
# counter so a healthy boot never accumulates toward the limit.
if command -v devmem >/dev/null 2>&1; then
    if devmem 0xFF020218 32 0 2>/dev/null; then
        log_message "boot-failover: cleared U-Boot boot counter (GRF 0xFF020218)"
    fi
fi

# Kill any existing rkipc processes
killall rkipc 2>/dev/null
# Non-dev (production) images carry /etc/seedsigner-nondev (see optimize-nondev.sh):
# background the ~4s camera-graph bootstrap so the display/UI comes up first. Dev
# images have no marker and keep the SDK-default foreground ordering.
if [ -f /etc/seedsigner-nondev ]; then
    log_message "non-dev: backgrounding camera graph bootstrap (UI-first boot)"
    bootstrap_camera_graph &
else
    bootstrap_camera_graph
fi

# Ensure /dev/gpiochip4 exists — on some variants, GPIO4 bank is registered
# under a lower chip number due to absent GPIO banks in the device tree.
ensure_gpiochip_symlinks

# Change to SeedSigner directory (Raspberry Pi SeedSigner-OS layout: app at /opt/src)
cd /opt/src

# Boot watchdog: recover a bad boot without the BOOT button. If the app never
# signals readiness (the app writes $READY_FILE from MainMenuView) within the
# window, reboot into rockusb Loader mode so the device stays re-flashable. This
# covers the app-hang case the retry loop cannot (a hung app never returns from
# `wait`). Cleared automatically once the app is up.
rm -f "$READY_FILE" 2>/dev/null || true
(
    waited=0
    while [ "$waited" -lt "$BOOT_WATCHDOG_TIMEOUT" ]; do
        [ -f "$READY_FILE" ] && exit 0
        sleep 5
        waited=$((waited + 5))
    done
    if [ ! -f "$READY_FILE" ]; then
        log_message "Boot watchdog: app not ready after ${BOOT_WATCHDOG_TIMEOUT}s — rebooting into Loader mode"
        rk-reboot loader
    fi
) &
BOOT_WATCHDOG_PID="$!"

# Retry loop
retry_count=0
while [ $retry_count -lt $MAX_RETRIES ]; do
    camera_post_spi_delay=$((CAMERA_POST_SPI_DELAY + retry_count))

    log_message "Starting SeedSigner (attempt $((retry_count + 1))/$MAX_RETRIES)"

    # Always clear camera-related processes before launching the app.
    killall rkipc 2>/dev/null || true
    stop_camera_service
    release_conflicting_gpio_lines

    # Configure GPIO button pins (IOMUX, pull-up, input, IE) for detected variant
    if [ -x /usr/bin/configure-gpio.sh ]; then
        /usr/bin/configure-gpio.sh 2>&1 | tee -a "$LOG_FILE" || log_message "WARNING: GPIO configuration failed — buttons may not work correctly. Check $LOG_FILE for details."
    else
        log_message "WARNING: /usr/bin/configure-gpio.sh not found or not executable"
    fi

    # Ensure /dev/gpiochip4 symlink is present before launching the app.
    # This is a no-op if the symlink was already created at startup.
    ensure_gpiochip_symlinks

    # Start SeedSigner first. On Mini, camera ISP start before display init can
    # exhaust memory and cause SPI open failures.
    python main.py &
    APP_PID="$!"
    start_camera_service_later "$APP_PID" "$camera_post_spi_delay"

    wait "$APP_PID"
    exit_code=$?
    APP_PID=""
    if [ -n "$CAMERA_HELPER_PID" ]; then
        wait "$CAMERA_HELPER_PID" 2>/dev/null || true
        CAMERA_HELPER_PID=""
    fi

    if [ $exit_code -eq 0 ]; then
        log_message "SeedSigner exited successfully"
        exit 0
    else
        retry_count=$((retry_count + 1))
        log_message "SeedSigner failed with exit code $exit_code"
        
        if [ $retry_count -lt $MAX_RETRIES ]; then
            log_message "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        else
            log_message "Maximum retries reached. SeedSigner failed to start — rebooting into Loader mode."
            rk-reboot loader
            exit 1
        fi
    fi
done
