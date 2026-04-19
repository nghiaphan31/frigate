#!/usr/bin/env python3
import subprocess
import yaml
import re
import sys
from pathlib import Path

INPUT = Path("lan_hosts.v3.yml")
OUTPUT = Path("lan_hosts.v3.withmac.yml")

# Run arp-scan once to collect MACs
def get_mac_table():
    try:
        out = subprocess.check_output(
            ["arp-scan", "--localnet", "--interface=eth0"], 
            stderr=subprocess.DEVNULL, text=True
        )
    except Exception as e:
        print(f"[!] Failed to run arp-scan: {e}")
        return {}

    macs = {}
    for line in out.splitlines():
        m = re.match(r"(\d+\.\d+\.\d+\.\d+)\s+([0-9A-Fa-f:]{17})", line)
        if m:
            ip, mac = m.groups()
            macs[ip.strip()] = mac.upper()
    return macs

def main():
    if not INPUT.exists():
        print(f"Input file {INPUT} not found")
        sys.exit(1)

    with open(INPUT, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    macs = get_mac_table()

    updated = 0
    for h in data.get("hosts", []):
        ip = h.get("ip_current") or h.get("ip_target")
        if not ip:
            continue
        legacy = h.setdefault("legacy", {})
        if "mac" in legacy and legacy["mac"]:
            continue  # already present
        mac = macs.get(ip)
        if mac:
            legacy["mac"] = mac
            updated += 1

    with open(OUTPUT, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

    print(f"[+] Done. {updated} MAC addresses added.")
    print(f"    New file: {OUTPUT}")

if __name__ == "__main__":
    main()
