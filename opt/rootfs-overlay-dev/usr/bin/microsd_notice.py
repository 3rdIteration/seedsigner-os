#!/usr/bin/env python3
"""Display a short message indicating the app is running from the MicroSD card.

This script is executed before launching the main SeedSigner application when a
`seedsigner-dev` folder is detected on the inserted MicroSD card.  It uses the
device's ST7789 display driver to render a simple centered text message for five
seconds and then clears the screen.
"""

import time

try:
    from PIL import Image, ImageDraw, ImageFont
    from ST7789 import ST7789
except Exception:  # pragma: no cover - best effort in early boot
    # Fallback: print to console if any graphics dependency is missing
    print("Running from MicroSD card", flush=True)
    time.sleep(5)
else:
    try:
        display = ST7789()

        image = Image.new("RGB", (display.width, display.height))
        draw = ImageDraw.Draw(image)
        font = ImageFont.load_default()
        message = "Running from MicroSD"
        width, height = draw.textsize(message, font=font)
        x = (display.width - width) // 2
        y = (display.height - height) // 2
        draw.text((x, y), message, font=font, fill=(255, 255, 255))
        display.ShowImage(image, 0, 0)
        time.sleep(5)
        display.clear()
    except Exception:
        print("Running from MicroSD card", flush=True)
        time.sleep(5)
