#!/usr/bin/env python3
"""Draw a static message on the SPI display, outside the SeedSigner app.

Two uses, both from start-seedsigner.sh:

  show-screen-message.py loading
      Early boot splash. The screen is otherwise dark until the app finishes
      starting, so the device looks dead for ~20s. It also doubles as the single
      most useful diagnostic on a non-dev image: if this appears and the app
      never follows, the display/SPI chain is fine and the app is at fault; if
      the screen stays dark, suspect the display chain (missing /dev/spidev0.0
      from the configfs / device-tree overlay path) first.

  show-screen-message.py failed "<reason>"
      The app failed to launch repeatedly and the device is about to reboot into
      Loader mode. Without this a non-dev image is mute about why: no console,
      no adb, no network, dark screen.

STRICTLY BEST-EFFORT. Every failure path here is silent and returns 0. A
diagnostic aid must never become a second failure mode, and must never delay
the Loader failover.

It also must not keep the display: SPI/GPIO are released before exit so the app
can open the panel afterwards.
"""

import sys

DEFAULT_WIDTH = 240
DEFAULT_HEIGHT = 240
LINE_HEIGHT = 11
MARGIN = 6
# Default PIL bitmap font is ~6px wide per char.
CHAR_WIDTH = 6


def _log(message: str) -> None:
    try:
        print(f"show-screen-message: {message}", flush=True)
    except Exception:
        pass


def _wrap(text: str, max_chars: int) -> list[str]:
    max_chars = max(8, max_chars)
    lines: list[str] = []
    current = ""
    for word in str(text).split():
        candidate = f"{current} {word}".strip()
        if len(candidate) <= max_chars:
            current = candidate
            continue
        if current:
            lines.append(current)
        # Hard-split a single over-long token (a path or traceback fragment)
        # rather than let it overflow the panel.
        while len(word) > max_chars:
            lines.append(word[:max_chars])
            word = word[max_chars:]
        current = word
    if current:
        lines.append(current)
    return lines


def _resolve_display():
    """(driver, width, height) or (None, 0, 0). Never raises."""
    try:
        from seedsigner.hardware.displays.display_driver import DisplayDriverFactory
    except Exception as exc:
        _log(f"display driver unavailable ({exc})")
        return None, 0, 0

    display_type, width, height = "st7789", DEFAULT_WIDTH, DEFAULT_HEIGHT
    try:
        # Match the app's panel selection where possible so this works across
        # the ST7789 variants instead of assuming one board's geometry. Falls
        # back to the common 240x240 if settings can't be read.
        from seedsigner.models.settings import Settings, SettingsConstants

        display_config = Settings.get_instance().get_value(
            SettingsConstants.SETTING__DISPLAY_CONFIGURATION, default_if_none=True
        )
        display_type = display_config.split("_")[0]
        width, height = (int(v) for v in display_config.split("_")[1].split("x"))
    except Exception:
        pass

    try:
        driver = DisplayDriverFactory.instantiate_display_driver(
            display_type, width=width, height=height
        )
    except Exception as exc:
        _log(f"could not open display ({exc}) - display may itself be the fault")
        return None, 0, 0

    return driver, getattr(driver, "width", width), getattr(driver, "height", height)


def _draw(mode: str, reason: str) -> None:
    try:
        from PIL import Image, ImageDraw
    except Exception as exc:
        _log(f"PIL unavailable ({exc})")
        return

    driver, width, height = _resolve_display()
    if driver is None:
        return

    try:
        image = Image.new("RGB", (width, height), "black")
        draw = ImageDraw.Draw(image)
        max_chars = width // CHAR_WIDTH
        y = MARGIN

        if mode == "failed":
            draw.text((MARGIN, y), "STARTUP FAILED", fill="red")
            y += LINE_HEIGHT * 2
            for line in _wrap(reason, max_chars):
                if y > height - LINE_HEIGHT * 3:
                    break
                draw.text((MARGIN, y), line, fill="white")
                y += LINE_HEIGHT
            y += LINE_HEIGHT
            draw.text((MARGIN, y), "Rebooting to flash mode", fill="yellow")
        else:
            draw.text((MARGIN, y), "SeedSigner", fill="orange")
            y += LINE_HEIGHT * 2
            draw.text((MARGIN, y), "Loading...", fill="white")
            y += LINE_HEIGHT * 2
            draw.text((MARGIN, y), "Please wait", fill="grey")

        driver.show_image(image)
        _log(f"drew '{mode}' message")
    except Exception as exc:
        _log(f"draw failed ({exc})")
    finally:
        # Release SPI/GPIO so the app can open the panel afterwards. Holding it
        # here would turn a splash screen into the cause of a boot failure.
        try:
            if hasattr(driver, "cleanup"):
                driver.cleanup()
        except Exception:
            pass


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else "loading"
    reason = argv[2] if len(argv) > 2 else "Unknown error"
    sys.path.insert(0, "/opt/src")
    _draw(mode, reason)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:
        # Never propagate: the caller may be on its way to a Loader reboot.
        sys.exit(0)
