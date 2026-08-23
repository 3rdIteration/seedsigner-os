# tools

Developer utilities that are not part of the build itself.

| Tool | Purpose |
| ---- | ------- |
| [`imgdiff.py`](imgdiff.py) | Explain why two SeedSigner OS `.img` files are not byte-identical. |

## imgdiff.py

```bash
python3 tools/imgdiff.py local.img ci.img
```

Reproducible-build triage. Narrows a mismatch from "the SHA-256 doesn't match" down to the individual
file inside the image, and for ELF binaries down to the individual embedded string that differs.
Exits `0` if the images are byte-identical, `1` if they differ.

Python 3 standard library only — no mtools, binwalk or loopback mount, and it runs on Windows.

What it walks:

1. MBR, disk-id and partition table
2. The pre-partition region (on lafrite, the pinned Amlogic bootloader blob at sector 1)
3. FAT geometry, volume serial and label
4. Every file on the FAT boot partition — metadata and SHA-256
5. For `Image`: the gzipped initramfs linked into the arm64 kernel, then every rootfs entry in the
   cpio (mode, uid/gid, mtime, size, sha256, archive order)
6. For any differing ELF: a diff of the multiset of embedded printable strings
7. For any differing squashfs: the `mkfs_time` header field

Step 5 works because the lafrite profile sets `BR2_TARGET_ROOTFS_INITRAMFS=y` with
`BR2_TARGET_ROOTFS_CPIO_GZIP=y` — there is no separate rootfs filesystem, so the whole userland is
reachable from the `.img` with no rebuild and no `--debug-rootfs` tarball. The other stages are generic
and still report usefully on Pi images, which do not carry their rootfs inside the kernel.

See [docs/agents.md](../docs/agents.md#verifying-reproducibility) for how to read the output — especially
the part about differences cascading, where the innermost file whose *content* changed is the root cause
and everything after it is just shifted offsets.
