#!/usr/bin/env python3
"""
export_homeassistant.py
Generate Home Assistant packages from the Source of Truth (SoT).

Creates YAML fragments under out/homeassistant/packages/:
  - device_<hostname>.yaml → defines friendly_name + area
  - group_<zone>.yaml      → defines light groups, etc.

Usage:
  python3 tools/export_homeassistant.py sot/sot.yaml -o out/homeassistant
"""
import argparse, yaml
from pathlib import Path
from datetime import datetime, timezone

def load_sot(path: Path):
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    data.setdefault("devices", [])
    data.setdefault("groups", [])
    return data

def write_yaml(obj, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        yaml.dump(obj, f, sort_keys=False, allow_unicode=True)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sot", help="path to SoT YAML")
    ap.add_argument("-o", "--out", required=True, help="output dir (e.g. out/homeassistant)")
    args = ap.parse_args()

    sot = load_sot(Path(args.sot))
    out = Path(args.out)
    pkg_dir = out / "packages"
    pkg_dir.mkdir(parents=True, exist_ok=True)

    meta = {
        "generated": datetime.now(timezone.utc).isoformat(),
        "source": str(Path(args.sot).resolve())
    }

    # --- Individual devices
    for d in sot["devices"]:
        hn = d.get("hostname")
        alias = d.get("alias_human", hn)
        if not hn:
            continue
        area = d.get("location", {}).get("zone") or "unspecified"
        pkg = {
            "homeassistant": {
                "customize": {
                    f"device.{hn}": {
                        "friendly_name": alias,
                        "area": area,
                    }
                }
            },
            "_meta": meta
        }
        write_yaml(pkg, pkg_dir / f"device_{hn}.yaml")

    # --- Groups (lights, motion, etc.)
    for g in sot.get("groups", []):
        cat = g.get("category") or "group"
        hn = g.get("hostname") or g.get("alias_human")
        if not hn:
            continue
        members = g.get("members") or []
        entities = [f"light.{m}" for m in members] if cat == "light" else members
        group_pkg = {
            "group": {
                hn: {
                    "name": g.get("alias_human", hn),
                    "entities": entities
                }
            },
            "_meta": meta
        }
        write_yaml(group_pkg, pkg_dir / f"group_{hn}.yaml")

    print(f"[OK] Wrote Home Assistant packages under {pkg_dir}")

if __name__ == "__main__":
    main()
