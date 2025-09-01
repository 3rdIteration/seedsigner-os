#!/usr/bin/env python3
"""Display a short message on the SeedSigner screen."""

import argparse
import os
import sys
import time


def main() -> None:
    """Render a message to both the console and SeedSigner display."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--message",
        default="Loading SeedSigner-Dev from MicroSD",
        help="Text to display",
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=5,
        help="Seconds to show the message",
    )
    args = parser.parse_args()

    # Always echo the message to the console for debugging visibility
    print(args.message, flush=True)

    # SeedSigner isn't installed as a system module, so search common source paths
    # to pull in its display stack
    for path in ("/mnt/microsd/seedsigner-dev/", "/opt/src/"):
        if os.path.isdir(path) and path not in sys.path:
            sys.path.insert(0, path)

    try:
        from PIL import ImageFont
        from seedsigner.gui.renderer import Renderer
    except Exception:  # pragma: no cover - best effort in early boot
        time.sleep(args.duration)
        return

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
        width, height = renderer.draw.textsize(args.message, font=font)
        x = (renderer.canvas_width - width) // 2
        y = (renderer.canvas_height - height) // 2
        renderer.draw.text((x, y), args.message, font=font, fill=(255, 255, 255))
        renderer.show_image()
        time.sleep(args.duration)
        renderer.display_blank_screen()
    except Exception:  # pragma: no cover - display failure
        time.sleep(args.duration)


if __name__ == "__main__":
    main()
