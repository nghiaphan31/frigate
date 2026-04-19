#!/usr/bin/env python3
import subprocess
import yaml
import re
import sys
from pathlib import Path

# Fichiers E/S
INPUT = Path("lan_hosts.v3.yml")
OUTPUT = Path("lan_hosts.v3.withmac_vendor.yml")

# Interface fixée comme demandé
IFACE = "enx00e04c680141"

def run_arp_scan():
    """
    Lance arp-scan sur IFACE et renvoie deux index:
      - by_ip[ip] = {"mac": MAC, "manufacturer": Vendor}
      - by_mac[mac] = {"ip": IP, "manufacturer": Vendor}
    """
    try:
        out = subprocess.check_output(
            ["arp-scan", "--localnet", f"--interface={IFACE}"],
            stderr=subprocess.STDOUT,
            text=True
        )
    except subprocess.CalledProcessError as e:
        print(e.output)
        raise
    except Exception as e:
        raise RuntimeError(f"Failed to run arp-scan on {IFACE}: {e}")

    by_ip, by_mac = {}, {}
    # arp-scan sort typiquement: 192.168.50.112  00:11:22:33:44:55  Vendor Name, Inc
    line_re = re.compile(r"^(\d+\.\d+\.\d+\.\d+)\s+([0-9A-Fa-f:]{17})\s+(.+)$")
    for line in out.splitlines():
        m = line_re.match(line.strip())
        if not m:
            continue
        ip, mac, vendor = m.groups()
        mac = mac.upper()
        vendor = vendor.strip()
        by_ip[ip] = {"mac": mac, "manufacturer": vendor}
        by_mac[mac] = {"ip": ip, "manufacturer": vendor}
    return by_ip, by_mac

def main():
    # Entrée optionnelle via argument (sinon défaut)
    in_path = Path(sys.argv[1]) if len(sys.argv) >= 2 else INPUT
    out_path = Path(sys.argv[2]) if len(sys.argv) >= 3 else OUTPUT

    if not in_path.exists():
        print(f"[!] Input file not found: {in_path}")
        sys.exit(1)

    with open(in_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    hosts = data.get("hosts", [])

    print(f"[*] Scanning LAN on {IFACE} with arp-scan…")
    by_ip, by_mac = run_arp_scan()
    print(f"[+] arp-scan results: {len(by_ip)} hosts discovered on {IFACE}")

    updated_mac = 0
    set_manu = 0

    for h in hosts:
        # Assure que legacy est un dict
        legacy = h.setdefault("legacy", {}) if isinstance(h.get("legacy"), dict) else {}
        # IP de référence pour la découverte : ip_current sinon ip_target
        ip = h.get("ip_current") or h.get("ip_target")
        mac_in_legacy = legacy.get("mac")

        # 1) Compléter legacy.mac si manquant et dispo via IP
        if (not mac_in_legacy) and ip and ip in by_ip:
            legacy["mac"] = by_ip[ip]["mac"]
            mac_in_legacy = legacy["mac"]
            updated_mac += 1

        # 2) Déterminer manufacturer (priorité: par MAC si présent, sinon via IP)
        manufacturer = h.get("manufacturer")
        if mac_in_legacy and mac_in_legacy in by_mac:
            manu = by_mac[mac_in_legacy]["manufacturer"]
        elif ip and ip in by_ip:
            manu = by_ip[ip]["manufacturer"]
        else:
            manu = None

        if manu and manu != manufacturer:
            h["manufacturer"] = manu
            set_manu += 1
        elif "manufacturer" not in h:
            # Ajoute explicitement la clé, même si None (pour homogénéité du schéma)
            h["manufacturer"] = manu

    # Sauvegarde
    with open(out_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

    print(f"[+] Done.")
    print(f"    MACs added: {updated_mac}")
    print(f"    manufacturer set/updated: {set_manu}")
    print(f"    Output: {out_path}")

if __name__ == "__main__":
    main()
