#!/usr/bin/env python3
"""
Incremental enrichment of lan_hosts YAML with MAC and manufacturer info from Wi-Fi scan.
"""

from pathlib import Path
import subprocess
import yaml
import re
import sys
import argparse
import shutil

DEFAULT_IN = Path("lan_hosts.v3.withmac_vendor.yml")
DEFAULT_OUT = Path("lan_hosts.v3.withmac_vendor.wifi.yml")
DEFAULT_IFACE = "wlp101s0f0"

def run_arp_scan(iface):
    cmd = ["arp-scan", "--localnet", f"--interface={iface}"]
    out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
    by_ip, by_mac = {}, {}
    pattern = re.compile(r"^(\d+\.\d+\.\d+\.\d+)\s+([0-9A-Fa-f:]{17})\s+(.+)$")
    for line in out.splitlines():
        m = pattern.match(line.strip())
        if not m:
            continue
        ip, mac, vendor = m.groups()
        mac = mac.upper()
        vendor = vendor.strip()
        by_ip[ip] = {"mac": mac, "manufacturer": vendor}
        by_mac[mac] = {"ip": ip, "manufacturer": vendor}
    return by_ip, by_mac

def run_ip_neigh():
    out = subprocess.check_output(["ip", "neigh"], text=True)
    by_ip, by_mac = {}, {}
    pattern = re.compile(r"^(\d+\.\d+\.\d+\.\d+)\s+.*lladdr\s+([0-9A-Fa-f:]{17})")
    for line in out.splitlines():
        m = pattern.match(line.strip())
        if not m:
            continue
        ip, mac = m.groups()
        mac = mac.upper()
        by_ip[ip] = {"mac": mac}
        by_mac[mac] = {"ip": ip}
    return by_ip, by_mac

def load_yaml(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}

def save_yaml(data, path: Path):
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

def backup_file(path: Path):
    bak = path.with_suffix(path.suffix + ".bak")
    shutil.copy2(path, bak)
    return bak

def main():
    p = argparse.ArgumentParser(description="Incremental Wi-Fi enrichment of lan_hosts YAML (MAC + manufacturer).")
    p.add_argument("--input", "-i", type=Path, default=DEFAULT_IN, help="Input YAML (output of ethernet scan).")
    p.add_argument("--output", "-o", type=Path, default=DEFAULT_OUT, help="Output YAML path.")
    p.add_argument("--iface", "-f", default=DEFAULT_IFACE, help="Wi-Fi interface to scan (default: wlp101s0f0).")
    p.add_argument("--force-mac", action="store_true", help="Overwrite existing legacy.mac if present.")
    p.add_argument("--overwrite-manufacturer", action="store_true", help="Overwrite manufacturer even if present.")
    args = p.parse_args()

    if not args.input.exists():
        print(f"[!] Input file not found: {args.input}")
        sys.exit(1)

    # Load input and backup
    data = load_yaml(args.input)
    hosts = data.get("hosts", [])
    bak = backup_file(args.input)
    print(f"[*] Backup created: {bak}")

    # Try arp-scan -> else ip neigh
    by_ip, by_mac = {}, {}
    used_arp_scan = False
    try:
        print(f"[*] Running arp-scan on iface {args.iface} (requires sudo/root)...")
        by_ip, by_mac = run_arp_scan(args.iface)
        used_arp_scan = True
        print(f"[+] arp-scan discovered {len(by_ip)} hosts.")
    except FileNotFoundError:
        print("[!] arp-scan not installed; falling back to `ip neigh` (no manufacturer info).")
        by_ip, by_mac = run_ip_neigh()
    except subprocess.CalledProcessError as e:
        print("[!] arp-scan returned non-zero; falling back to `ip neigh`.")
        if getattr(e, "output", None):
            print("\n".join(e.output.splitlines()[:10]))
        by_ip, by_mac = run_ip_neigh()
    except Exception as e:
        print(f"[!] Unexpected error running arp-scan: {e}")
        print("[!] Falling back to `ip neigh` (no manufacturer info).")
        by_ip, by_mac = run_ip_neigh()

    updated_mac = 0
    updated_manufacturer = 0

    for h in hosts:
        # ensure legacy dict
        if not isinstance(h.get("legacy"), dict):
            h["legacy"] = {}
        legacy = h["legacy"]

        ip_ref = h.get("ip_current") or h.get("ip_target")
        mac_existing = legacy.get("mac")

        # 1) Fill legacy.mac if missing (or forced)
        mac_from_scan = by_ip.get(ip_ref, {}).get("mac") if ip_ref else None
        if mac_from_scan:
            if not mac_existing or args.force_mac:
                legacy["mac"] = mac_from_scan
                updated_mac += 1

        # 2) Set manufacturer
        manu_existing = h.get("manufacturer") if "manufacturer" in h else None
        manu_from_scan = None
        mac_to_check = legacy.get("mac")
        if mac_to_check and mac_to_check in by_mac:
            manu_from_scan = by_mac[mac_to_check].get("manufacturer")
        elif ip_ref and ip_ref in by_ip:
            manu_from_scan = by_ip[ip_ref].get("manufacturer")

        if manu_from_scan:
            if not manu_existing or args.overwrite_manufacturer:
                h["manufacturer"] = manu_from_scan
                updated_manufacturer += 1
        else:
            if "manufacturer" not in h:
                h["manufacturer"] = None

    # Save output
    save_yaml(data, args.output)
    print(f"[+] Done. Output: {args.output}")
    print(f"    MACs added/overwritten: {updated_mac}")
    print(f"    manufacturer set/overwritten: {updated_manufacturer}")
    if not used_arp_scan:
        print("    Note: arp-scan was not used; manufacturer information may be missing.")

if __name__ == "__main__":
    main()
