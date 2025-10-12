#!/usr/bin/env python3
import sys, yaml

def fail(msg):
    print(f"[ERROR] {msg}", file=sys.stderr); sys.exit(1)

def main(path):
    try:
        data = yaml.safe_load(open(path, "r", encoding="utf-8"))
    except Exception as e:
        fail(f"YAML load failed: {e}")

    if not isinstance(data, dict):
        fail("Top-level must be a mapping")

    devices = data.get("devices", []) or []
    groups  = data.get("groups", [])  or []

    # Uniqueness: sot_id, hostname, fqdn
    seen_sot, seen_host, seen_fqdn = set(), set(), set()
    for d in devices:
        sid = d.get("sot_id")
        if sid:
            if sid in seen_sot: fail(f"Duplicate sot_id: {sid}")
            seen_sot.add(sid)
        hn = d.get("hostname")
        if hn:
            if hn in seen_host: fail(f"Duplicate hostname: {hn}")
            seen_host.add(hn)
        fq = d.get("fqdn")
        if fq:
            if fq in seen_fqdn: fail(f"Duplicate fqdn: {fq}")
            seen_fqdn.add(fq)

    # Uniqueness for groups: group_id, hostname, fqdn
    seen_gid, seen_gh, seen_gf = set(), set(), set()
    for g in groups:
        gid = g.get("group_id")
        if gid:
            if gid in seen_gid: fail(f"Duplicate group_id: {gid}")
            seen_gid.add(gid)
        hn = g.get("hostname")
        if hn:
            if hn in seen_gh: fail(f"Duplicate group hostname: {hn}")
            seen_gh.add(hn)
        fq = g.get("fqdn")
        if fq:
            if fq in seen_gf: fail(f"Duplicate group fqdn: {fq}")
            seen_gf.add(fq)

    print("[OK] SoT basic validation passed.")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: tools/validate.py sot/sot.yaml", file=sys.stderr); sys.exit(2)
    main(sys.argv[1])
