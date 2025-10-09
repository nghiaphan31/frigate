#!/usr/bin/env python3
"""
export_synology.py
Generate Synology helper configs from the SoT.

Outputs:
  - out/synology/hosts.csv      → alias_human,fqdn,ip,mac,vendor
  - out/synology/backups.json   → restic/rsync job targets

Usage:
  python3 tools/export_synology.py sot/sot.yaml -o out/synology
"""
import argparse, csv, json, yaml
from pathlib import Path
from datetime import datetime, timezone

def load_sot(path: Path):
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("devices", [])
    return data

def first_ip(device: dict) -> str | None:
    # Prefer dns.ip_current; fallback to first interface IP
    dns = device.get("dns") or {}
    if dns.get("ip_current"):
        return dns["ip_current"]
    for iface in (device.get("interfaces") or []):
        ip = iface.get("ip")
        if ip:
            return ip
    return None

def first_mac(device: dict) -> str | None:
    for iface in (device.get("interfaces") or []):
        mac = iface.get("mac")
        if mac:
            return mac
    return None

def vendor_of(device: dict) -> str | None:
    return device.get("vendor") or device.get("manufacturer")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sot", help="path to SoT YAML")
    ap.add_argument("-o", "--out", required=True, help="output directory")
    args = ap.parse_args()

    sot = load_sot(Path(args.sot))
    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    # --- hosts.csv
    hosts_csv = outdir / "hosts.csv"
    with hosts_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["alias_human", "fqdn", "ip", "mac", "vendor"])
        for d in sot["devices"]:
            alias = d.get("alias_human", "")
            fqdn = d.get("fqdn", "")
            ip = first_ip(d) or ""
            mac = first_mac(d) or ""
            vendor = vendor_of(d) or ""
            writer.writerow([alias, fqdn, ip, mac, vendor])

    # --- backups.json (restic/rsync targets)
    jobs = []
    for d in sot["devices"]:
        backup = d.get("backup") or {}
        if not backup:
            continue
        job = {
            "alias": d.get("alias_human", ""),
            "fqdn": d.get("fqdn"),
            "ip": first_ip(d),
            "paths": backup.get("paths", []),
            "schedule": backup.get("schedule", "daily"),
            "method": backup.get("method", "rsync"),
        }
        jobs.append(job)

    backups_json = outdir / "backups.json"
    backups_json.write_text(
        json.dumps(
            {
                "_meta": {
                    "generated": datetime.now(timezone.utc).isoformat(),
                    "source": str(Path(args.sot).resolve()),
                },
                "jobs": jobs,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print(f"[OK] wrote {hosts_csv} and {backups_json}")

if __name__ == "__main__":
    main()
