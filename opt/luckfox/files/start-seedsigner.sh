#!/bin/bash

# Configuration
MAX_RETRIES=5
RETRY_DELAY=10  # seconds
CAMERA_START_TIMEOUT=20  # max seconds to wait for app init signal
CAMERA_POLL_INTERVAL=1   # seconds
CAMERA_POST_SPI_DELAY=10  # seconds to wait after SPI init detection
BOOT_WATCHDOG_TIMEOUT=120  # seconds; fall into Loader mode if the app never signals ready
LOG_FILE="/tmp/startup.log"
APP_LOG="/tmp/seedsigner-app.log"   # the app's own stdout/stderr (Python tracebacks)
APP_TAIL_LINES=40                   # how much of it to copy into the logs on failure
READY_FILE="/tmp/seedsigner-ready"  # written by the app (MainMenuView) once it is up
APP_PID=""
CAMERA_HELPER_PID=""
BOOT_WATCHDOG_PID=""

# Persistent copy of the startup log. /tmp is a tmpfs, so on a non-dev image —
# no serial console, no adb, no network — a boot failure destroys the only
# record of why on the next reboot, leaving a device that looks bricked and
# says nothing. /userdata is a separate partition that survives both reboot and
# a firmware reflash, which is what it was restored for.
PERSIST_DIR="/userdata"
PERSIST_LOG="$PERSIST_DIR/seedsigner-boot.log"
PERSIST_LOG_PREV="$PERSIST_DIR/seedsigner-boot.log.prev"
PERSIST_LOG_MAX_BYTES=131072  # 128 KiB, rotated once => 256 KiB worst case on a 10M partition
PERSIST_OK=0

# Set up the persistent log. Entirely best-effort: /userdata may be absent (Mini
# and Pico Pi drop it), unmounted, full, or read-only once the rootfs hardening
# lands. Any failure just leaves PERSIST_OK=0 and logging continues to /tmp.
init_persistent_log() {
    [ -d "$PERSIST_DIR" ] || return 0
    # Rotate a previous boot's log aside so a crash loop cannot bury the first
    # failure, which is usually the informative one.
    if [ -f "$PERSIST_LOG" ]; then
        mv -f "$PERSIST_LOG" "$PERSIST_LOG_PREV" 2>/dev/null || true
    fi
    if : > "$PERSIST_LOG" 2>/dev/null; then
        PERSIST_OK=1
        printf '===== boot %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >> "$PERSIST_LOG" 2>/dev/null || PERSIST_OK=0
    fi
}

# Remove the persistent log. Called as soon as the boot is known to have
# succeeded: the log exists ONLY to explain a failure, and anything that
# outlives a good boot is a liability — an app traceback can quote paths,
# arguments or other material we would rather not leave sitting in flash.
clear_persistent_log() {
    rm -f "$PERSIST_LOG" "$PERSIST_LOG_PREV" 2>/dev/null || true
    PERSIST_OK=0
}

persist_line() {
    [ "$PERSIST_OK" = "1" ] || return 0
    # Stop persisting the moment the app reports ready. The boot succeeded, so
    # there is nothing left to diagnose and no reason to keep writing to flash.
    # Checked here (rather than via a variable) because the watchdog that
    # observes readiness runs in a subshell and cannot change our state.
    [ -f "$READY_FILE" ] && return 0
    printf '%s\n' "$1" >> "$PERSIST_LOG" 2>/dev/null || { PERSIST_OK=0; return 0; }
    # Cap the size so a fast crash loop cannot fill the partition.
    local size
    size=$(wc -c < "$PERSIST_LOG" 2>/dev/null || echo 0)
    if [ "${size:-0}" -gt "$PERSIST_LOG_MAX_BYTES" ]; then
        printf '%s\n' "--- log truncated at ${PERSIST_LOG_MAX_BYTES} bytes ---" >> "$PERSIST_LOG" 2>/dev/null || true
        PERSIST_OK=0
    fi
}

# Function to log messages
log_message() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$line" | tee -a "$LOG_FILE"
    persist_line "$line"
}

# Copy the tail of the app's own output into the startup log (and thus the
# persistent log). Without this the reason for a failed start is invisible on a
# non-dev image: no console, no adb, no network, and /tmp is gone after reboot.
log_app_output_tail() {
    [ -s "$APP_LOG" ] || { log_message "app produced no output"; return 0; }
    log_message "--- last ${APP_TAIL_LINES} lines of app output ---"
    # Read via a pipe so a huge file can't be slurped into memory.
    tail -n "$APP_TAIL_LINES" "$APP_LOG" 2>/dev/null | while IFS= read -r app_line; do
        log_message "  | $app_line"
    done
    log_message "--- end app output ---"
}

# Draw a static message on the panel via the app's display driver. Strictly
# best-effort and time-boxed: this is a diagnostic aid and must never delay the
# boot or the Loader failover. Backgrounding is not an option because it must
# release SPI before the app opens the panel, so it is bounded with `timeout`.
SCREEN_MSG="/usr/bin/show-screen-message.py"
SCREEN_MSG_TIMEOUT=20
show_screen_message() {
    [ -f "$SCREEN_MSG" ] || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout "$SCREEN_MSG_TIMEOUT" python "$SCREEN_MSG" "$@" 2>&1 | while IFS= read -r msg_line; do
            log_message "$msg_line"
        done
    else
        python "$SCREEN_MSG" "$@" 2>&1 | while IFS= read -r msg_line; do
            log_message "$msg_line"
        done
    fi
    return 0
}

# Sweep SPI bus configurations against the panel, in place of the boot splash.
#
# Diagnosing "the panel is black but every layer reports success" needs the panel
# driven several different ways in one boot, and the only instrument is the
# operator's eye. A hardened image has no shell to run the probe from, so it is
# triggered by dropping an empty file named `display-probe` on the microSD card
# or in /userdata.
#
# The marker is consumed on use. A probe that latched on would replace the splash
# on every subsequent boot and delay the app each time, turning a diagnostic into
# a permanent defect; deleting it first also means a probe that hangs and gets
# killed still cannot repeat. Removal is best-effort: on a read-only card the
# probe simply runs again, which is harmless.
DISPLAY_PROBE="/usr/bin/probe-display.py"
DISPLAY_PROBE_TIMEOUT=90
run_display_probe_if_requested() {
    [ -f "$DISPLAY_PROBE" ] || return 1
    marker=""
    for dir in /mnt/microsd /mnt/sdcard "$PERSIST_DIR"; do
        if [ -f "$dir/display-probe" ]; then
            marker="$dir/display-probe"
            break
        fi
    done
    [ -n "$marker" ] || return 1

    log_message "display probe requested via $marker"
    rm -f "$marker" 2>/dev/null || log_message "WARNING: could not remove $marker"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$DISPLAY_PROBE_TIMEOUT" python "$DISPLAY_PROBE" 2>&1 | while IFS= read -r probe_line; do
            log_message "$probe_line"
        done
    else
        python "$DISPLAY_PROBE" 2>&1 | while IFS= read -r probe_line; do
            log_message "$probe_line"
        done
    fi
    return 0
}

# Best-effort one-line summary of why the app died, for the on-screen message.
# Prefers the last Python exception line, which is the informative one.
app_failure_summary() {
    local line=""
    if [ -s "$APP_LOG" ]; then
        line=$(grep -aE '^[A-Za-z_.]+(Error|Exception|Warning):' "$APP_LOG" 2>/dev/null | tail -n 1)
        [ -n "$line" ] || line=$(grep -av '^[[:space:]]*$' "$APP_LOG" 2>/dev/null | tail -n 1)
    fi
    [ -n "$line" ] || line="app exited without output"
    # Keep it short enough to be readable on a 240x240 panel.
    printf '%.120s' "$line"
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

stop_rkipc() {
    # `killall rkipc` followed by a fixed sleep is NOT enough. When the encoder never
    # came up (as on the 64 MB Mini, where a 1 MB CMA cannot satisfy the vendor camera
    # app) rkipc sits in a tight retry loop emitting thousands of
    # "RK_MPI_VENC_GetStream timeout" per second, and either takes seconds to act on
    # SIGTERM or never acts on it at all. While it lives it holds DMA/CMA buffers and
    # fragments the little memory there is - which is what makes spidev_open()'s
    # contiguous allocation fail, so the display never opens even though the panel is
    # fine. Wait for it to actually exit, then escalate to SIGKILL.
    pidof rkipc >/dev/null 2>&1 || return 0

    killall rkipc 2>/dev/null || true
    i=0
    while [ "$i" -lt 5 ]; do
        pidof rkipc >/dev/null 2>&1 || { log_message "rkipc stopped"; return 0; }
        sleep 1
        i=$((i + 1))
    done

    log_message "WARNING: rkipc ignored SIGTERM after 5s; sending SIGKILL"
    killall -9 rkipc 2>/dev/null || true
    i=0
    while [ "$i" -lt 3 ]; do
        pidof rkipc >/dev/null 2>&1 || { log_message "rkipc killed"; return 0; }
        sleep 1
        i=$((i + 1))
    done

    log_message "ERROR: rkipc still running after SIGKILL — display open may fail (ENOMEM)"
    return 1
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
    stop_rkipc || true
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Start the persistent log before anything else can fail, so an early failure is
# still recorded somewhere that survives the reboot.
init_persistent_log

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

# Kill any existing rkipc processes (and wait for them to actually go away)
stop_rkipc || true
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

# Early splash. The panel is dark until the app finishes starting, so the device
# looks dead for ~20s. This also splits the two failure classes on a non-dev
# image at a glance: splash then nothing => display/SPI is fine and the app is
# at fault; screen never lights => suspect the display chain (no
# /dev/spidev0.0 from the configfs / device-tree overlay path).
# The probe drives the panel itself and takes the place of the splash when
# requested; running both would fight over the SPI bus for no benefit.
if ! run_display_probe_if_requested; then
    show_screen_message loading
fi

# Boot watchdog: recover a bad boot without the BOOT button. If the app never
# signals readiness (the app writes $READY_FILE from MainMenuView) within the
# window, reboot into rockusb Loader mode so the device stays re-flashable. This
# covers the app-hang case the retry loop cannot (a hung app never returns from
# `wait`). Cleared automatically once the app is up.
rm -f "$READY_FILE" 2>/dev/null || true
(
    waited=0
    while [ "$waited" -lt "$BOOT_WATCHDOG_TIMEOUT" ]; do
        if [ -f "$READY_FILE" ]; then
            # Boot succeeded: drop the persistent log rather than leave a
            # record of a healthy boot sitting in flash.
            clear_persistent_log
            exit 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    if [ ! -f "$READY_FILE" ]; then
        log_message "Boot watchdog: app not ready after ${BOOT_WATCHDOG_TIMEOUT}s — rebooting into Loader mode"
        # Deliberately no on-screen message here, unlike the retry-exhausted
        # path below: this fires while the app is still RUNNING (just not
        # ready), so it probably holds /dev/spidev0.0. A second process opening
        # the panel would contend for SPI and could itself wedge the boot. The
        # persistent log records the reason instead.
        rk-reboot loader
    fi
) &
BOOT_WATCHDOG_PID="$!"

# Retry loop
retry_count=0
while [ $retry_count -lt $MAX_RETRIES ]; do
    camera_post_spi_delay=$((CAMERA_POST_SPI_DELAY + retry_count))

    log_message "Starting SeedSigner (attempt $((retry_count + 1))/$MAX_RETRIES)"

    # Always clear camera-related processes before launching the app. This must WAIT for
    # rkipc to exit, not just signal it: the app opens /dev/spidev0.0 moments later and
    # that open needs a contiguous kernel allocation which fails while rkipc is thrashing.
    stop_rkipc || true
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
    #
    # Capture the app's own stdout/stderr to a file. Previously it inherited the
    # console, which non-dev images strip — so a Python traceback went nowhere
    # and a crash-looping app was completely silent. This is the only place the
    # actual reason for a failed start exists.
    #
    # Deliberately a plain redirect rather than `| tee`: piping would make $!
    # the tee PID, breaking `wait "$APP_PID"` and the camera helper that keys
    # off it. Live console output is traded for a durable record; on dev images
    # use `tail -f $APP_LOG`, and the tail is echoed on failure below.
    : > "$APP_LOG" 2>/dev/null || true
    python main.py >>"$APP_LOG" 2>&1 &
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
        # Clean exit is not a failure either — leave nothing behind.
        clear_persistent_log
        exit 0
    else
        retry_count=$((retry_count + 1))
        log_message "SeedSigner failed with exit code $exit_code"
        log_app_output_tail

        if [ $retry_count -lt $MAX_RETRIES ]; then
            log_message "Retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
        else
            log_message "Maximum retries reached. SeedSigner failed to start — rebooting into Loader mode."
            # Say why on the panel before the device disappears into Loader mode,
            # so a bricked-looking device is not also a silent one.
            show_screen_message failed "$(app_failure_summary)"
            rk-reboot loader
            exit 1
        fi
    fi
done
