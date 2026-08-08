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

import os
import sys

DEFAULT_WIDTH = 240
DEFAULT_HEIGHT = 240
LINE_HEIGHT = 11
MARGIN = 6
# Default PIL bitmap font is ~6px wide per char.
CHAR_WIDTH = 6

# The splash is read across a desk on a 240x240 panel, so it uses the app's own
# TrueType face at roughly 3x the PIL bitmap default (~11px). The failure screen
# deliberately does NOT scale its body text: its job is to carry a reason string
# (often a Python exception), and tripling that would truncate the one piece of
# information the screen exists to deliver. Only its heading is enlarged.
LOADING_TITLE_SIZE = 34
LOADING_BODY_SIZE = 26
FAILED_HEADING_SIZE = 20

# Shipped with the app; survives the non-dev prune (only translations are cut).
FONT_DIRS = (
    "/opt/src/seedsigner/resources/fonts",
    os.path.join(os.path.dirname(__file__), "seedsigner", "resources", "fonts"),
)
FONT_TITLE = "OpenSans-SemiBold.ttf"
FONT_BODY = "OpenSans-Regular.ttf"


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


def _font(name: str, size: int):
    """A TrueType face at `size`, or PIL's bitmap default. Never raises.

    Falling back rather than failing matters here: a missing font must degrade
    the splash to small text, never turn the diagnostic aid into the thing that
    stops the boot.
    """
    from PIL import ImageFont

    for directory in FONT_DIRS:
        path = os.path.join(directory, name)
        try:
            if os.path.isfile(path):
                return ImageFont.truetype(path, size)
        except Exception:
            continue
    _log(f"{name} unavailable - falling back to the default bitmap font")
    try:
        return ImageFont.load_default()
    except Exception:
        return None


def _draw_centered(draw, text: str, y: int, font, fill: str, width: int) -> int:
    """Draw `text` horizontally centred at `y`; return the y below it."""
    try:
        left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
        text_width = right - left
        height = bottom - top
        # textbbox includes the font's internal top bearing, so subtract it to
        # place the glyphs where the caller asked rather than a few px lower.
        draw.text(((width - text_width) // 2 - left, y - top), text, font=font, fill=fill)
        return y + height
    except Exception:
        # Any measurement failure still gets text on screen, just left-aligned.
        draw.text((MARGIN, y), text, font=font, fill=fill)
        return y + LINE_HEIGHT


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
            # Heading enlarged; body left at the bitmap font on purpose so the
            # reason string still fits (see the note by FAILED_HEADING_SIZE).
            heading_font = _font(FONT_TITLE, FAILED_HEADING_SIZE)
            y = _draw_centered(draw, "STARTUP FAILED", y, heading_font, "red", width)
            y += LINE_HEIGHT * 2
            for line in _wrap(reason, max_chars):
                if y > height - LINE_HEIGHT * 3:
                    break
                draw.text((MARGIN, y), line, fill="white")
                y += LINE_HEIGHT
            y += LINE_HEIGHT
            draw.text((MARGIN, y), "Rebooting to flash mode", fill="yellow")
        else:
            title_font = _font(FONT_TITLE, LOADING_TITLE_SIZE)
            body_font = _font(FONT_BODY, LOADING_BODY_SIZE)
            # Centred as a block rather than pinned to the top margin: at this
            # size three left-aligned lines look like a truncated error, which
            # is the opposite of what a "things are fine, please wait" screen
            # should convey.
            y = (height // 2) - LOADING_TITLE_SIZE - LOADING_BODY_SIZE
            y = _draw_centered(draw, "SeedSigner", y, title_font, "orange", width)
            y += LOADING_BODY_SIZE
            y = _draw_centered(draw, "Loading...", y, body_font, "white", width)
            y += LOADING_BODY_SIZE // 2
            _draw_centered(draw, "Please wait", y, body_font, "grey", width)

        # ST7735/ST7789 declare show_image(Image, Xstart, Ystart) with no
        # defaults (the other drivers default both to 0), so the origin must be
        # passed explicitly or the call raises TypeError and the splash never
        # draws — which is exactly how this probe silently failed before.
        driver.show_image(image, 0, 0)
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
