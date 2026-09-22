# Driving SocToolkit's `upgrade_tool` directly

SocToolkit is a GUI wrapper. Every button press runs Rockchip's `upgrade_tool`,
which you can call yourself. Calling it directly gives an agent (or a human) a
scriptable way to flash, read back and diagnose a Luckfox board, and prints
errors that the GUI hides. This is also the fastest way to find out what
SocToolkit actually sent to the board: it logs every command.

Everything below was run against a Luckfox Pico Mini (RV1103, SPI NAND) with
SocToolkit V2.2 on Windows, including on a board whose secure-boot fuse is
burned. Commands not marked as verified come from the tool's own help text.

## Where things are

`<SocToolKit>` means wherever SocToolkit is unpacked: the folder that contains
`SocToolKit.exe`.

| What | Path |
|---|---|
| The CLI | `<SocToolKit>\bin\windows\upgrade_tool.exe` |
| SocToolkit's own log | `<SocToolKit>\Log\log_<date>.txt` |
| Also bundled | `afptool.exe`, `rkImageMaker.exe`, `programmer_image_tool.exe` (same folder) |
| Linux equivalents | `rkbin/tools/upgrade_tool`, `rkbin/tools/rkdeveloptool` |

Call it from **PowerShell** on Windows. Git Bash's path conversion mangles
arguments, and a USB stick mounted as a drive letter is not visible from WSL.

```powershell
$t = "<SocToolKit>\bin\windows\upgrade_tool.exe"
& $t ld
```

## SocToolkit's log is the ground truth

The log names every `upgrade_tool` command SocToolkit ran, with its full file
paths, and every failure. Read it before trusting anyone's account of what was
flashed:

```bash
grep -a -n 'upgrade_tool.exe\|Error' log_<date>.txt | grep -a -v ' ld$\| sld$'
```

- A log file is named for the day the SocToolkit session **started**. A session
  left open overnight keeps writing to the previous day's file.
- `Error:action=ActionType.ACTION_DOWNLOAD,ret=-2` means Download Boot (`db`)
  failed: the board did not accept the loader.
- SocToolkit's Download mode is: `db <folder>\download.bin`, then one `wl` per
  partition, then `rd`. It keeps the last folder you chose. On 2026-09-21 a
  run of "failed" retries was actually re-sending the same stale folder; the
  new files never reached the board. The log made that obvious.

## Board modes

`ld` lists devices:

```
DevNo=1  Vid=0x2207,Pid=0x110c,LocationID=<id>  Mode=Maskrom  SerialNo=
```

- **Bare maskrom**: `Mode=Maskrom`, empty `SerialNo`. Only BootROM is
  running. Enter it by holding BOOT while plugging in USB, or it happens by
  itself when BootROM rejects the NAND idblock. The only useful command here
  is `db`.
- **Loader running** (after a successful `db`): still reported as
  `Mode=Maskrom`, but `SerialNo=rockchip`. The usbplug is now in RAM and
  answers `rfi`, `rci`, `rl`, `wl`, `el`, `pl`, `rd`.
- **No device**: the board is booting from NAND (or is not connected).

Pass `-s <LocationID>` to address a specific board, as SocToolkit does. The ID
belongs to the USB port, so it changes if the board is moved to another port.

## Verified commands

| Command | What it does | Needs a loader? |
|---|---|---|
| `ld` | list devices and their mode | no |
| `db <download.bin>` | load the loader's DDR init + usbplug into RAM. **Writes nothing to flash** | no (this is how you get one) |
| `rfi` | flash info (NAND: `Flash Size: 127MB`, 2 KB pages, 128 KB blocks) | yes |
| `rci` | chip info (`36 30 31 31` = "6011", the RV1106 family tag) | yes |
| `wl <sector> <count> <file>` | write a file at a 512-byte LBA | yes |
| `rl <sector> <count> <file>` | read LBAs back to a file | yes |
| `rd` | reset the board. With no USB device afterwards, it booted from NAND | yes |

In the help text but not yet exercised here: `rsm` (ReadSecureMode, which would
be the direct way to tell a fused board from an unfused one), `ul`
(UpgradeLoader), `uf` (UpgradeFirmware, i.e. `update.img`), `ef`/`el`
(erase), `pl` (partition list; it failed without a loader), `exf` (extract a
firmware or loader), `sfi`.

- `ul` writes the loader's own embedded idblock (the RC4 "flashhead" inside
  `download.bin`), not `idblock.img`. On a re-keyed release, that flashhead
  must be re-keyed too (`rkloader.set_pubkey` does this since the 2026-09-21
  fix).
- `uf` flashes `update.img`, which embeds its own copy of every image. A
  re-signed release's `update.img` still carries the old chain unless it was
  rebuilt; the re-sign tools delete it for that reason.

## Boards that boot from MicroSD

Everything here writes the **NAND** of a NAND board. A board that boots from a
MicroSD card keeps its whole boot chain on the card, and `db` only ever loads a
loader into RAM — so a re-signed `download.bin` sent over USB changes nothing on
the card. Write the card in a reader instead (whole image, or just the changed
partitions): see
[secure-boot.md §2.5](secure-boot.md#flashing-a-board-that-boots-from-microsd).
Whether the usbplug can be switched to the card (`ssd`, SwitchStorage) is
untested here.

## NAND layout (Pico Mini, SPI NAND bundle)

These are the LBAs (512-byte sectors) SocToolkit uses, taken from its log for
a Mini NAND bundle. Other profiles differ, so take them from that bundle's own
SocToolkit log or its partition table rather than reusing these.

| Image | Start sector | Sectors |
|---|---|---|
| `env.img` | 0 | 512 |
| `idblock.img` | 512 | 512 |
| `uboot.img` | 1024 | 1024 |
| `boot.img` | 2048 | 8192 |
| `oem.img` | 10240 | 40960 |
| `userdata.img` | 51200 | 12288 |
| `rootfs.img` | 63488 | 190464 |

## Recipe: flash a bundle by hand

This is exactly what SocToolkit's Download mode does, with read-back added.

```powershell
$t  = "<SocToolKit>\bin\windows\upgrade_tool.exe"
$b  = "<bundle folder>"
$id = "<LocationID from ld>"
& $t ld                                   # expect Mode=Maskrom, empty SerialNo
& $t -s $id db "$b\download.bin"          # expect "Download boot ok."
$plan = @(@(0,512,"env.img"), @(512,512,"idblock.img"), @(1024,1024,"uboot.img"),
          @(2048,8192,"boot.img"), @(10240,40960,"oem.img"),
          @(51200,12288,"userdata.img"), @(63488,190464,"rootfs.img"))
foreach ($p in $plan) { & $t -s $id wl $p[0] $p[1] "$b\$($p[2])" }
& $t -s $id rl 512 512 "$env:TEMP\idblock-readback.img"   # compare the first len(idblock.img) bytes
& $t -s $id rd
```

`rl` returns the whole sector range, so compare only the first file-length
bytes of what it returns with the file you wrote. The rest is padding.

## Troubleshooting

### "Download boot failed!  Note: please check ddr, please reset device and retry"

This message is generic. It does not mean the DDR is faulty. It means BootROM
refused the loader, or the loader never came up. Work through these in order:

1. **Power-cycle before every retry.** After a failed `db`, a good loader can
   fail as well: a known-good loader failed straight after a rejected one, then
   passed from a clean power cycle. Unplug the board, hold BOOT, plug it back
   in, and send one loader per power cycle, or a bad result tells you nothing.
2. **Check what was actually sent**, in SocToolkit's log (above).
3. **On a fused board**, the loader must match the OTP key hash. Ask Rockchip's
   tool which hash it needs, and compare with what was burned:

   ```bash
   # from an rkbin clone (setting.ini and boot_merger must sit next to rk_sign_tool)
   ./rk_sign_tool cc --chip 1106
   ./rk_sign_tool lk --key <any.pem> --pubkey <any.pub>   # always done first here; unconfirmed whether otp needs it
   ./rk_sign_tool otp --loader download.bin --hash otp.bin && xxd -p otp.bin
   python3 opt/luckfox/secure-boot/rkloader.py inspect download.bin   # "OTP key hash" + any "!! FUSED BOARD" lines
   ```

   The burned value is the armed idblock's SPL `hash@np`, the same value
   `rkloader.py inspect idblock.img` prints as "SPL burns". The SPL refuses to
   burn unless that matches the key it holds, and reads the OTP back
   afterwards, so a board whose log printed "RSA: Write RSA key hash
   successfully" holds exactly that value.
4. **A 1970 `releaseTime`.** A fused board refuses a `download.bin` dated
   1970-01-01 even when it is correctly signed. `rkloader.py inspect` prints
   the date. Builds and re-signs now floor it at 2025-01-01.
5. **Prove the board itself is fine** with a loader nothing of ours has
   touched: build one from rkbin and have the vendor tool sign it with the
   fused key.

   ```bash
   cd rkbin && ./tools/boot_merger RKBOOT/RV1106MINIALL.ini    # -> rv1106_download_v*.bin
   ./tools/rk_sign_tool sl --loader rv1106_download_v*.bin     # after cc/lk with the fused key
   ```

   If this passes `db` and ours does not, the difference is in our loader, not
   the board. It uses the stock rkbin DDR/usbplug blobs, which is fine for
   `db` and for writing NAND.

### The board only prints `RKUART` on UART

That is BootROM. It prints nothing when it rejects the NAND idblock. On a fused
board this almost always means the idblock's header key block does not hash to
the OTP value (see [airgapped-signing.md](airgapped-signing.md#the-header-key-block-what-the-bootrom-checks)).
Recover over USB as above with a loader that does match, then write a
corrected `idblock.img` at sector 512.

## Rules for agents

- `db` is RAM-only and safe to retry (after a power cycle). `wl`, `el`, `ef`,
  `ul` and `uf` change flash, so confirm with the user before running them.
- A fused board is not bricked just because it sits in maskrom. Recovery only
  needs a loader whose header hashes to the burned OTP value, which means the
  fused key's private half. Never guess at signing keys, and keep key material
  out of the repo.
- Read SocToolkit's log instead of inferring what happened from the user's
  description.

## See also

- [secure-boot.md](secure-boot.md) — the hub: background, signing a release (all four methods),
  burning the fuse and recovery, future work, findings. Its
  [§8 Links and resources](secure-boot.md#8-links-and-resources) lists every related document,
  tool and external reference.
- [`rockchip-linux/rkbin`](https://github.com/rockchip-linux/rkbin) — `upgrade_tool`,
  `rkdeveloptool`, `boot_merger`, `rk_sign_tool` for Linux.
- [Rockusb (maskrom) — Rockchip open source wiki](https://opensource.rock-chips.com/wiki_Rockusb).
- [Luckfox wiki](https://wiki.luckfox.com/) — SocToolkit downloads and board flashing guides.
