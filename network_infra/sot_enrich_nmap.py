#!/usr/bin/env python3
"""
sot_enrich_nmap.py

Nmap-only enrichment for LAN Source of Truth (SoT).

Usage:
  sudo ./sot_enrich_nmap.py --input lan_hosts.sot.enriched.yml --output lan_hosts.sot.nmap.yml
Options:
  --parallel N        Run up to N concurrent nmap processes (default: 6)
  --timeout-secs N    Per-host nmap timeout in seconds (default: 300)
  --ports "1-65535"   Port range to scan (default: "1-65535")
  --overwrite         Overwrite existing os/exposed_ports/service_role fields
Notes:
  - For best OS fingerprint and service/version detection run with sudo.
  - nmap (-O, -sV) can be intrusive; use with care.
"""

import argparse
import subprocess
import yaml
import xml.etree.ElementTree as ET
from pathlib import Path
from datetime import datetime
import concurrent.futures
import shlex

# Heuristique simple pour déduire service_role depuis ports/services
ROLE_FROM_PORT = {
    22: "ssh",
    80: "http",
    443: "https",
    8123: "homeassistant",
    5000: "synology-dsm",   # often synology DSM
    5001: "synology-dsm",
    445: "smb",
    139: "smb",
    3306: "mysql",
    5432: "postgres",
    5900: "vnc",
    1900: "upnp",
    1883: "mqtt",
    8883: "mqtts",
    554: "rtsp",
    8554: "rtsp",
}

def run_nmap(ip, ports, timeout_secs, extra_args=None):
    """
    Run nmap for a single IP and return parsed XML element root.
    Uses: -Pn (no ping), -sS -sV -O --version-all -p<ports> -oX -
    """
    args = [
        "nmap",
        "-Pn",
        "-sS",
        "-sV",
        "-O",
        "--version-all",
        "-p", ports,
        "--host-timeout", f"{timeout_secs}s",
        "-oX", "-"
    ]
    if extra_args:
        args += extra_args
    args.append(ip)
    try:
        proc = subprocess.run(args, capture_output=True, text=True, check=True)
        xml_out = proc.stdout
        root = ET.fromstring(xml_out)
        return root
    except subprocess.CalledProcessError as e:
        print(f"[!] nmap failed for {ip}: {e}; stdout/stderr trimmed")
        if e.stdout:
            print(e.stdout.splitlines()[:10])
        return None
    except Exception as e:
        print(f"[!] Exception running nmap on {ip}: {e}")
        return None

def parse_nmap_xml_root(root):
    """
    Given the <nmaprun> root for one-host output, extract:
      - os (string), os_accuracy (int if present)
      - ports: list of dicts {port,proto,state,service,product,version}
    """
    res = {"os": None, "os_accuracy": None, "ports": []}
    host = root.find("host")
    if host is None:
        return res

    # OS
    osnode = host.find("os")
    if osnode is not None:
        osmatch = osnode.find("osmatch")
        if osmatch is not None:
            res["os"] = osmatch.attrib.get("name")
            acc = osmatch.attrib.get("accuracy")
            try:
                res["os_accuracy"] = int(acc) if acc is not None else None
            except Exception:
                res["os_accuracy"] = None

    # Ports
    ports_node = host.find("ports")
    if ports_node is not None:
        for p in ports_node.findall("port"):
            portid = int(p.attrib.get("portid", "0"))
            proto = p.attrib.get("protocol")
            state = p.find("state").attrib.get("state") if p.find("state") is not None else None
            service_node = p.find("service")
            service = None
            product = None
            version = None
            if service_node is not None:
                service = service_node.attrib.get("name")
                product = service_node.attrib.get("product")
                version = service_node.attrib.get("version")
            res["ports"].append({
                "port": portid,
                "proto": proto,
                "state": state,
                "service": service,
                "product": product,
                "version": version
            })
    return res

def merge_scan_into_host(host, scan_data, timestamp, overwrite=False):
    """
    Update host dict in-place using scan_data. Non-destructive unless overwrite=True.
    - set os if absent or overwrite
    - append/merge exposed_ports (replace if overwrite, otherwise union unique by port/proto)
    - set service_role heuristically if absent or overwrite
    - update last_seen and legacy._scan_history
    """
    if scan_data is None:
        return host

    # OS
    os_name = scan_data.get("os")
    os_acc = scan_data.get("os_accuracy")
    if os_name and (overwrite or not host.get("os")):
        # store as "OS (accuracy%)" and also in os_confidence
        host["os"] = os_name
        if os_acc is not None:
            host.setdefault("os_confidence", None)
            host["os_confidence"] = os_acc

    # Exposed ports
    existing_ports = host.get("exposed_ports") or []
    if overwrite:
        host["exposed_ports"] = scan_data.get("ports", [])
    else:
        # merge: keep unique (port,proto)
        seen = {(p.get("port"), p.get("proto")) for p in existing_ports}
        for p in scan_data.get("ports", []):
            key = (p.get("port"), p.get("proto"))
            if key not in seen:
                existing_ports.append(p)
                seen.add(key)
        host["exposed_ports"] = existing_ports

    # service_role heuristic (prefer highest-priority detected)
    if scan_data.get("ports"):
        # choose role by port mapping; prefer lowest-numbered matching port
        found_roles = []
        for p in sorted(scan_data["ports"], key=lambda x: x["port"]):
            role = ROLE_FROM_PORT.get(p["port"])
            if role:
                found_roles.append(role)
        if found_roles:
            candidate_role = found_roles[0]
            if overwrite or not host.get("service_role"):
                host["service_role"] = candidate_role

    # set last_seen
    host["last_seen"] = timestamp
    # provenance nmap in scan_history
    host.setdefault("legacy", {})
    scan_history = host["legacy"].setdefault("_scan_history", [])
    entry = {
        "date": timestamp,
        "source": "nmap",
        "os": scan_data.get("os"),
        "os_accuracy": scan_data.get("os_accuracy"),
        "ports": scan_data.get("ports", [])
    }
    scan_history.append(entry)

    # status online if any open ports
    ports = scan_data.get("ports", [])
    any_open = any(p.get("state") == "open" for p in ports)
    host["status"] = "online" if any_open else host.get("status", "unknown")

    return host

def process_host_item(item, ports, timeout_secs, overwrite):
    """
    Given a host dict (must have ip_current), run nmap and merge results.
    Return updated host dict.
    """
    ip = item.get("ip_current")
    name = item.get("hostname") or item.get("name") or ip
    if not ip:
        print(f"[-] Skipping {name}: no ip_current")
        return item

    print(f"[*] Scanning {name} ({ip}) ...")
    root = run_nmap(ip, ports, timeout_secs)
    if root is None:
        print(f"[!] No nmap xml for {ip}")
        return item
    scan_data = parse_nmap_xml_root(root)
    ts = datetime.utcnow().isoformat()
    updated = merge_scan_into_host(item, scan_data, ts, overwrite=overwrite)
    print(f"[+] Done {name} ({ip}): found {len(scan_data.get('ports', []))} ports, os={scan_data.get('os')}")
    return updated

def main():
    ap = argparse.ArgumentParser(description="Enrich SoT using Nmap scans")
    ap.add_argument("--input", "-i", type=Path, required=True, help="Input SoT YAML (lan_hosts.sot.enriched.yml)")
    ap.add_argument("--output", "-o", type=Path, default=Path("lan_hosts.sot.nmap.yml"), help="Output YAML path")
    ap.add_argument("--ports", "-p", default="1-65535", help="Port range for nmap (default 1-65535)")
    ap.add_argument("--timeout-secs", type=int, default=300, help="Per-host nmap timeout in seconds")
    ap.add_argument("--parallel", type=int, default=6, help="Concurrent nmap scans")
    ap.add_argument("--overwrite", action="store_true", help="Overwrite existing fields (os,exposed_ports,service_role)")
    args = ap.parse_args()

    data = yaml.safe_load(args.input.read_text()) or {}
    groups = data.get("groups", {})
    # flatten hosts into list of tuples (zone, host)
    host_entries = []
    for zone, hosts in groups.items():
        for h in hosts:
            # ensure ip_current is string if present
            if h.get("ip_current"):
                host_entries.append((zone, h))
            else:
                print(f"[-] Skipping {h.get('hostname') or h.get('name') or 'unknown'}: no ip_current")

    # run scans in parallel
    updated = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as ex:
        futures = []
        for zone, h in host_entries:
            futures.append(ex.submit(process_host_item, h, args.ports, args.timeout_secs, args.overwrite))
        for f in concurrent.futures.as_completed(futures):
            try:
                out = f.result()
                updated.append(out)
            except Exception as e:
                print(f"[!] scan thread exception: {e}")

    # reassemble groups: replace hosts in groups with updated ones (matching by hostname or ip_current)
    updated_map = {}
    for h in updated:
        key = (h.get("hostname"), h.get("ip_current"))
        updated_map[key] = h

    new_groups = {}
    for zone, hosts in groups.items():
        new_hosts = []
        for h in hosts:
            key = (h.get("hostname"), h.get("ip_current"))
            if key in updated_map:
                new_hosts.append(updated_map[key])
            else:
                new_hosts.append(h)
        new_groups[zone] = new_hosts

    # update meta last_scan time
    meta = data.get("meta", {})
    meta.setdefault("last_nmap_scan", datetime.utcnow().isoformat())
    data["meta"] = meta
    data["groups"] = new_groups

    args.output.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
    print(f"[+] Wrote enriched YAML to {args.output}")

if __name__ == "__main__":
    main()
