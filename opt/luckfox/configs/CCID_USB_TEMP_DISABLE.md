# Temporary USB CCID Disable Workaround

## Status

Temporary mitigation is enabled in all three build paths:

- `buildroot/os-build.sh`
- `buildroot/build-local.sh`
- `.github/workflows/build.yml`

During rootfs staging, the build removes:

`/usr/lib/pcsc/drivers/ifd-ccid.bundle`

This keeps serial SEC1210 support (`libccidtwin.so`) while disabling USB CCID driver loading.

## Why this is needed

On Luckfox Pico images, `pcscd` starts correctly, initializes the SEC1210 serial reader, then exits after receiving `SIGTERM` in scenarios where USB CCID components are present. A practical on-device workaround was:

`rm -rf /usr/lib/pcsc/drivers/ifd-ccid.bundle`

This behavior was reproduced on built images and validated as restoring stable serial smartcard operation for SEC1210.

## What the failure looks like

Typical `pcscd` debug sequence:

1. Reader config parsed from `/etc/reader.conf.d/sec1210`
2. Driver loaded from `/usr/lib/pcsc/drivers/serial/libccidtwin.so`
3. Reader opens `/dev/ttyS2:SEC1210URT`
4. `pcscd` reports ready
5. Shortly after, process exits due to `Received signal: 15`

While this occurs:

- `python-pyscard` calls fail with `EstablishContextException: Service not available (0x8010001D)`

## Scope and tradeoff

- Keeps serial smartcard support working for SEC1210.
- Disables USB CCID reader support until root cause is fixed.

## Removal criteria

Remove this workaround when:

1. `pcscd` remains stable with USB CCID bundle installed.
2. Serial SEC1210 still works with `/dev/ttyS2`.
3. USB CCID readers are validated on target devices.
