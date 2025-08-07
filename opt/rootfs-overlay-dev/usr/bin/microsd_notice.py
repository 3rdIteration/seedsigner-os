#!/usr/bin/env python3
"""Display a short message indicating the app is running from the MicroSD card.

This script is executed before launching the main SeedSigner application when a
``seedsigner-dev`` folder is detected on the inserted MicroSD card.  It uses
SeedSigner's own display modules and configuration to render a simple centered
text message for five seconds and then clears the screen.
"""

import time

try:
    from PIL import ImageFont
    from seedsigner.gui.renderer import Renderer
except Exception:  # pragma: no cover - best effort in early boot
    # Fallback: print to console if any graphics dependency is missing
    print("Running from MicroSD card", flush=True)
    time.sleep(5)
else:
    try:
        Renderer.configure_instance()
        renderer = Renderer.get_instance()

        renderer.display_blank_screen()
        font = ImageFont.load_default()
        message = "Running from MicroSD"
        width, height = renderer.draw.textsize(message, font=font)
        x = (renderer.canvas_width - width) // 2
        y = (renderer.canvas_height - height) // 2
        renderer.draw.text((x, y), message, font=font, fill=(255, 255, 255))
        renderer.show_image()
        time.sleep(5)
        renderer.display_blank_screen()
    except Exception:
        print("Running from MicroSD card", flush=True)
        time.sleep(5)
