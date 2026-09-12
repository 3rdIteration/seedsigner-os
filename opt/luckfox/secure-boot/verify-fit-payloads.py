#!/usr/bin/env python3
"""verify-fit-payloads.py — reproducibility helper for Rockchip FIT images.

A signed uboot.img / boot.img is a small flattened-device-tree (FDT) header —
metadata + per-image sha256 hashes + a structurally-detached RSA-PSS signature
at /configurations/conf/signature/value (256 bytes for rsa2048) — followed by
the actual image DATA stored *externally* (each /images/<x> carries data-position
+ data-size pointing into the file, from `mkimage -E`).

Key fact for reproducible signed releases: the DATA payloads and all metadata are
KEY-INDEPENDENT. Signing only ADDS the 256-byte signature/value; the pubkey is
not even in these FITs (it lives in the loader's SPL DTB). So anyone can rebuild
with the same build config (SEEDSIGNER_FIT_SIGNATURE=1, same key or a throwaway
one) and confirm the released image wraps byte-identical payloads — the signature
is the only thing a rebuild can't, and shouldn't, match.

Note: compare against a rebuild made with the SAME signing config, not an
unsigned build. On signed NAND the kernel DTB (`fdt`) carries baked bootargs
(root=ubi0…, see apply_signed_nand_bootargs), so its payload legitimately differs
from an unsigned build's. The key used does NOT affect any payload here.

Not covered: the loader (download.bin / idblock.img). Its SPL DTB embeds the
pubkey + burn-key-hash + an rk_sign_tool signature as binary inside a boot_merger
blob (pubkey modulus little-endian near 0x3bc; see secure-boot.md §10 Q16), so it
is not a plain FIT and needs separate handling.

Pure stdlib — no dtc, no external deps.

  payloads <img>            list each /images/<x>: type, size, stored vs RECOMPUTED sha256
  sig <img>                 print the signature node (algo/padding/key-name-hint + value hex)
  compare <img-a> <img-b>   PASS iff both images carry byte-identical payloads
                            (use as: compare <signed-release> <reproducible rebuild>)

Exit codes: 0 ok, 2 payload/hash mismatch, 1 usage, 3 parse error.
"""
import sys, struct, hashlib

FDT_BEGIN_NODE=1; FDT_END_NODE=2; FDT_PROP=3; FDT_NOP=4; FDT_END=9

def parse_fdt(buf, base=0):
    (magic,) = struct.unpack_from(">I", buf, base)
    if magic != 0xd00dfeed:
        raise ValueError("no FDT magic at offset %d" % base)
    (_, totalsize, off_struct, off_strings, _, _, _, _, size_strings, size_struct) = \
        struct.unpack_from(">IIIIIIIIII", buf, base)
    strings = buf[base+off_strings: base+off_strings+size_strings]
    def sname(o):
        e = strings.find(b"\x00", o); return strings[o:e].decode("latin1")
    p = base+off_struct; path=[]; props={}
    while True:
        (tok,) = struct.unpack_from(">I", buf, p); p+=4
        if tok==FDT_BEGIN_NODE:
            e=buf.find(b"\x00",p); path.append(buf[p:e].decode("latin1")); p=(e+4)&~3
        elif tok==FDT_END_NODE:
            path.pop()
        elif tok==FDT_PROP:
            (ln,noff)=struct.unpack_from(">II",buf,p); p+=8
            val=buf[p:p+ln]; p=(p+ln+3)&~3
            node="/"+"/".join(x for x in path if x)
            props.setdefault(node,{})[sname(noff)]=val
        elif tok==FDT_NOP:
            continue
        elif tok==FDT_END:
            break
    return totalsize, props

def _u32(b): return struct.unpack(">I", b)[0]

def _image_nodes(props):
    out={}
    for node,pr in props.items():
        if node.startswith("/images/") and node.count("/")==2:
            if "data-size" in pr and "data-position" in pr:
                name=node.split("/")[-1]
                h = props.get(node+"/hash",{}).get("value") or props.get(node+"/digest",{}).get("value")
                out[name]={"size":_u32(pr["data-size"]),"position":_u32(pr["data-position"]),
                           "type":pr.get("type",b"").rstrip(b"\x00").decode("latin1"),"stored_hash":h}
    return out

def payload_hashes(path):
    buf=open(path,"rb").read()
    _,props=parse_fdt(buf,0)
    res={}
    for name,info in _image_nodes(props).items():
        data=buf[info["position"]:info["position"]+info["size"]]
        actual=hashlib.sha256(data).hexdigest()
        res[name]={**info,"actual_hash":actual,
                   "hash_ok":(info["stored_hash"] is None or info["stored_hash"].hex()==actual)}
    return res

def cmd_payloads(path):
    res=payload_hashes(path)
    print("== %s: %d payload(s) ==" % (path,len(res)))
    ok=True
    for name,i in res.items():
        stored = i["stored_hash"].hex()[:16] if i["stored_hash"] else "(none)"
        flag = "OK" if i["hash_ok"] else "!! STORED-HASH MISMATCH"
        ok &= i["hash_ok"]
        print("  %-10s type=%-12s size=%8d pos=0x%x sha256=%s… stored=%s [%s]" %
              (name,i["type"],i["size"],i["position"],i["actual_hash"][:16],stored,flag))
    return 0 if ok else 2

def cmd_sig(path):
    buf=open(path,"rb").read(); _,props=parse_fdt(buf,0)
    sig=props.get("/configurations/conf/signature")
    if not sig:
        print("== %s: NO signature node (unsigned) ==" % path); return 0
    print("== %s: signature node ==" % path)
    for k in ("algo","padding","key-name-hint","signer-name","signer-version","sign-images"):
        if k in sig: print("  %s = %s" % (k, sig[k].rstrip(b"\x00").decode("latin1")))
    v=sig.get("value",b"")
    print("  value = %d bytes (RSA signature): %s…" % (len(v), v[:16].hex()))
    print("  ^ the ONLY key-dependent blob; payloads are reproducible without the key.")
    return 0

def cmd_compare(a,b):
    ra,rb=payload_hashes(a),payload_hashes(b)
    print("== compare payloads ==\n  A=%s\n  B=%s" % (a,b))
    ok=True
    for n in sorted(set(ra)|set(rb)):
        ha=ra.get(n,{}).get("actual_hash"); hb=rb.get(n,{}).get("actual_hash")
        match = ha==hb and ha is not None
        ok &= match
        print("  %-10s A=%-16s B=%-16s %s" % (n,str(ha)[:16],str(hb)[:16],"MATCH" if match else "!! DIFFER"))
    print("RESULT:", "PASS — payloads identical (release wraps the reproducible build)" if ok
          else "FAIL — payloads differ")
    return 0 if ok else 2

def main():
    try:
        c=sys.argv[1]
        if c=="payloads": return cmd_payloads(sys.argv[2])
        if c=="sig":      return cmd_sig(sys.argv[2])
        if c=="compare":  return cmd_compare(sys.argv[2],sys.argv[3])
    except IndexError:
        print(__doc__); return 1
    except ValueError as e:
        print("parse error:", e); return 3
    print(__doc__); return 1

if __name__=="__main__":
    sys.exit(main())
