#!/usr/bin/env python3
"""
export_synology.py
Generate Synology helper configs from the SoT.

Outputs:
  - out/synology/hosts.csv      → FQDN,IP,MAC,vendor
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
            fqdn = d.get("fqdn", "")
            alias = d.get("alias_human", "")
            dns = d.get("dns") or {}
            ip = dns.get("ip_current") or ""
            vendor = d.get("vendor", "")
            macs = [i.get("mac") for i in (d.get("interfaces") or []) if i.get("mac")]
            mac = macs[0] if macs else ""
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
            "ip": d.get("dns", {}).get("ip_current"),
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
