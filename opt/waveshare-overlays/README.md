# Waveshare 2.8" DPI overlays

Place the following device tree overlays in this directory when building
smartcard-dev images so they are copied into the boot partition:

- `waveshare-28dpi-3b-4b.dtbo`
- `waveshare-28dpi-3b.dtbo`
- `waveshare-touch-28dpi.dtbo`

The SeedSigner smartcard-dev post-build step will copy these files into the
`/boot/overlays` directory if they are present. These overlays are typically
available on Raspberry Pi OS installations or from the Waveshare wiki.
