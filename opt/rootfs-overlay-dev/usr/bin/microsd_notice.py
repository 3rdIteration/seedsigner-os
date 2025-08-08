#!/usr/bin/env python3
"""Display a short message indicating the dev build is loading from MicroSD.

This script is executed before launching the main SeedSigner application when a
``seedsigner-dev`` folder is detected on the inserted MicroSD card.  It uses
SeedSigner's own display modules and configuration to render a simple centered
text message for five seconds and then clears the screen.
"""

import os
import sys
import time

# SeedSigner isn't installed as a system module, so search common source paths
# to pull in its display stack
for path in ("/mnt/microsd/seedsigner-dev/", "/opt/src/"):
    if os.path.isdir(path) and path not in sys.path:
        sys.path.insert(0, path)

try:
    from PIL import ImageFont
    from seedsigner.gui.renderer import Renderer
except Exception:  # pragma: no cover - best effort in early boot
    # Fallback: print to console if any graphics dependency is missing
    print("Loading SeedSigner-Dev from MicroSD", flush=True)
    time.sleep(5)
else:
    try:
        Renderer.configure_instance()
        renderer = Renderer.get_instance()

        renderer.display_blank_screen()
        try:
            font = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 32
            )
        except Exception:  # pragma: no cover - font not found
            font = ImageFont.load_default()
        message = "Loading SeedSigner-Dev from MicroSD"
        width, height = renderer.draw.textsize(message, font=font)
        x = (renderer.canvas_width - width) // 2
        y = (renderer.canvas_height - height) // 2
        renderer.draw.text((x, y), message, font=font, fill=(255, 255, 255))
        renderer.show_image()
        time.sleep(5)
        renderer.display_blank_screen()
    except Exception:
        print("Loading SeedSigner-Dev from MicroSD", flush=True)
        time.sleep(5)
