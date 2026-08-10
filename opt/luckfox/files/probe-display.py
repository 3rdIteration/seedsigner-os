#!/usr/bin/env python3
"""Sweep SPI chip-select/mode/clock combinations against the panel.

Why this exists
---------------
The Luckfox Pico Mini reaches a state where every layer *reports* success --
``/dev/spidev0.0`` opens, the driver initialises, ``show_image()`` returns without
raising -- and the panel stays black. SPI is write-only here (MISO is disabled so
the pin can serve as RST), so there is no way to ask the panel whether it heard
anything. Software cannot distinguish "the panel got the pixels" from "the bytes
went into a wire the panel is not listening to".

The eye is the only available instrument. This probe walks the small set of
plausible bus configurations, painting a different solid colour for each and
logging which one it is about to paint. Whichever colour appears on the panel
names the configuration that works; if none appear, the fault is not chip-select,
SPI mode, or clock rate, and the search moves to wiring or the panel itself.

The axes swept are exactly the ones the adapter's jumpers select between:

  * chip-select -- kernel-managed CE0 (SPI mode 0) versus SPI_NO_CS with the
    LCD's CS strapped low (SPI mode 3). See ``ST7789.__post_init__``: mode 3 is
    required when CS is permanently asserted, because in mode 0 the panel latches
    boot-time noise on SCK and the command stream is misaligned from then on.
  * clock rate -- 40 MHz is the default; a marginal adapter or long jumper leads
    can corrupt the command stream at that rate while working at 10 MHz.

Running it
----------
No shell is needed on a hardened image: drop an empty file named ``display-probe``
on the microSD card (or in /userdata) and reboot. ``start-seedsigner.sh`` runs the
probe in place of the boot splash, then deletes the marker so the next boot is
normal. It can also be run directly on a dev build::

    python /usr/bin/probe-display.py

STRICTLY BEST-EFFORT, like show-screen-message.py: every failure path is silent,
the exit status is always 0, and SPI/GPIO are released after each attempt so a
failed probe cannot stop the app from opening the panel afterwards.
"""

import sys
import time

DEFAULT_WIDTH = 240
DEFAULT_HEIGHT = 240
MARGIN = 6
LINE_HEIGHT = 11

# Seconds to hold each configuration on screen. Long enough to notice and name
# the colour, short enough that the whole sweep is well under a minute.
HOLD_SECONDS = 6

# (label, colour, cs mode, spi_hz). The colour is the entire message: it has to
# be identifiable from across a desk, so these are maximally distinct hues and
# the text is a secondary confirmation only.
#
# Order matters. The current default configuration is first, so that a sweep
# which lights up on the very first step means the panel was working all along
# and the fault is in the app rather than the bus.
SWEEP = (
    ("1 RED    mode0 CE0  40MHz", (255, 0, 0), None, 40_000_000),
    ("2 GREEN  mode3 NOCS 40MHz", (0, 255, 0), "disabled", 40_000_000),
    ("3 BLUE   mode0 CE0  10MHz", (0, 0, 255), None, 10_000_000),
    ("4 YELLOW mode3 NOCS 10MHz", (255, 255, 0), "disabled", 10_000_000),
)


def _log(message: str) -> None:
    try:
        print(f"probe-display: {message}", flush=True)
    except Exception:
        pass


def _panel_geometry():
    """(display_type, width, height), falling back to the common 240x240."""
    try:
        from seedsigner.models.settings import Settings, SettingsConstants

        display_config = Settings.get_instance().get_value(
            SettingsConstants.SETTING__DISPLAY_CONFIGURATION, default_if_none=True
        )
        width, height = (int(v) for v in display_config.split("_")[1].split("x"))
        return display_config.split("_")[0], width, height
    except Exception:
        return "st7789", DEFAULT_WIDTH, DEFAULT_HEIGHT


def _attempt(label, colour, cs, spi_hz, display_type, width, height) -> None:
    """Paint one configuration. Never raises."""
    from PIL import Image, ImageDraw

    from seedsigner.hardware.displays.display_driver import DisplayDriverFactory
    from seedsigner.hardware.io_config import get_hardware_pin_mapping

    # The drivers read their pin mapping from io_config directly rather than
    # taking it as an argument, so the only way to vary the bus configuration is
    # to intercept that lookup. Each driver module imported the function by name,
    # so the module-level binding is what has to be replaced -- and in every
    # module, since which driver the factory picks depends on the panel type.
    modules = []
    for name in ("ST7789", "ST7735"):
        try:
            module = __import__(
                f"seedsigner.hardware.displays.{name}", fromlist=[name]
            )
        except Exception:
            continue
        if hasattr(module, "get_hardware_pin_mapping"):
            modules.append(module)

    original = get_hardware_pin_mapping

    def patched(hardware_config):
        mapping = original(hardware_config)
        display = dict(mapping["display"])
        if cs is None:
            display.pop("cs", None)
        else:
            display["cs"] = cs
        display["spi_hz"] = spi_hz
        patched_mapping = dict(mapping)
        patched_mapping["display"] = display
        return patched_mapping

    driver = None
    for module in modules:
        module.get_hardware_pin_mapping = patched
    try:
        driver = DisplayDriverFactory.instantiate_display_driver(
            display_type, width=width, height=height
        )
        image = Image.new("RGB", (width, height), colour)
        draw = ImageDraw.Draw(image)
        # Black text on the bright fills, white on blue, so the label stays
        # legible whichever colour is showing.
        text_fill = "white" if colour == (0, 0, 255) else "black"
        draw.text((MARGIN, MARGIN), label, fill=text_fill)
        draw.text((MARGIN, MARGIN + LINE_HEIGHT * 2), "report this colour", fill=text_fill)
        driver.show_image(image, 0, 0)
        _log(f"painted [{label}] - look at the panel now")
        time.sleep(HOLD_SECONDS)
    except Exception as exc:
        _log(f"[{label}] failed: {exc}")
    finally:
        # Always restore: a leaked patch would silently change the app's own
        # display configuration for the rest of the boot.
        for module in modules:
            module.get_hardware_pin_mapping = original
        # Release the bus between attempts: the next attempt reopens spidev with
        # different flags, which the kernel will refuse while it is still held.
        try:
            if driver is not None and hasattr(driver, "cleanup"):
                driver.cleanup()
        except Exception:
            pass


def main(argv: list[str]) -> int:
    sys.path.insert(0, "/opt/src")
    display_type, width, height = _panel_geometry()
    _log(f"sweeping {len(SWEEP)} configs on {display_type} {width}x{height}")
    _log("watch the panel; each config holds for %d seconds" % HOLD_SECONDS)
    for label, colour, cs, spi_hz in SWEEP:
        _attempt(label, colour, cs, spi_hz, display_type, width, height)
    _log("sweep complete - report which colour(s), if any, appeared")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:
        # Never propagate: the caller is on its way to starting the app.
        sys.exit(0)
