# Waveshare 2.8" DPI overlays

Place the following device tree overlays in this directory when building
smartcard-dev images so they are copied into the boot partition:

- `waveshare-28dpi-3b-4b.dtbo`
- `waveshare-28dpi-3b.dtbo`
- `waveshare-touch-28dpi.dtbo`

The SeedSigner smartcard-dev post-build step will copy these files into the
`/boot/overlays` directory if they are present. These overlays are typically
available on Raspberry Pi OS installations or from the Waveshare wiki.

If you want the build to download a zip automatically, set
`WAVESHARE_OVERLAYS_ZIP_URL` to a zip that contains these three `.dtbo` files
somewhere inside. The post-build step will extract and copy them into the boot
partition.

Alternate boot configs are written to the boot partition as:

- `config-dpi.txt` (DPI display enabled, UART smartcard pins unavailable)
- `config-uart.txt` (UART smartcard enabled, no DPI display)

To switch between them, rename the desired file to `config.txt` on the boot
partition.
