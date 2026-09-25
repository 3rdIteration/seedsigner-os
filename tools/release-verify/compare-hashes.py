#!/usr/bin/env python3
"""Compare locally built SeedSigner OS images against CI reference hashes.

Two modes:

1. Image mode (Pi/Lafrite, Luckfox SD):
   compare-hashes.py <local-dir> --expect expect.txt
   expect.txt is sha256sum-format ("<sha256>  <name>", basenames), e.g. written
   from the release asset digests:
     gh api "repos/<owner>/<repo>/releases/tags/<tag>" \
       | jq -r '.assets[] | select(.name | endswith(".img")) | .digest + "  " + .name'

2. Manifest mode (Luckfox bundles): CI publishes a merged per-combination
   manifest artifact (seedsigner_luckfox_images_sha256); the local build writes
   its own sha256sums.txt in the output dir. Diff them:
   compare-hashes.py --manifest-ci ci.sha256 --manifest-local <out>/sha256sums.txt

Exit code 0 = everything matches, 1 = mismatch/missing, 2 = usage error.
"""
import argparse
import hashlib
import os
import sys


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_manifest(text):
    entries = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            print(f"warning: skipping malformed manifest line: {line!r}", file=sys.stderr)
            continue
        digest, name = parts
        entries[os.path.basename(name).strip("*").lstrip("./")] = digest.lower()
    return entries


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("local_dir", nargs="?", help="directory containing local build outputs")
    ap.add_argument("--expect", help="sha256sum-format file of expected hashes (image mode)")
    ap.add_argument("--manifest-ci", help="CI merged manifest (Luckfox manifest mode)")
    ap.add_argument("--manifest-local", help="local sha256sums.txt (Luckfox manifest mode)")
    args = ap.parse_args()

    if bool(args.manifest_ci) != bool(args.manifest_local):
        ap.error("use both --manifest-ci and --manifest-local, or neither")

    ok = True

    if args.manifest_ci:
        with open(args.manifest_ci) as f:
            ci = parse_manifest(f.read())
        with open(args.manifest_local) as f:
            local = parse_manifest(f.read())
        for name in sorted(set(ci) | set(local)):
            c, l = ci.get(name), local.get(name)
            if c is None:
                print(f"MISSING-IN-CI   {name}  (local only: {l})")
                ok = False
            elif l is None:
                print(f"MISSING-LOCAL   {name}  (ci: {c})")
                ok = False
            elif c == l:
                print(f"MATCH           {name}")
            else:
                print(f"MISMATCH        {name}\n  ci:    {c}\n  local: {l}")
                ok = False

    if args.local_dir and args.expect:
        with open(args.expect) as f:
            expected = parse_manifest(f.read())
        for name, want in sorted(expected.items()):
            path = os.path.join(args.local_dir, name)
            if not os.path.isfile(path):
                print(f"MISSING-LOCAL   {name}")
                ok = False
                continue
            got = sha256_file(path)
            if got == want:
                print(f"MATCH           {name}")
            else:
                print(f"MISMATCH        {name}\n  ci:    {want}\n  local: {got}")
                ok = False

    if not (args.manifest_ci or args.local_dir):
        ap.error("nothing to do: give <local-dir> --expect, or the two manifests")

    print()
    print("ALL HASHES MATCH" if ok else "HASH VERIFICATION FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
