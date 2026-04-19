#!/usr/bin/env python3
"""
apply_schema_build_sot.py

- Lit un inventaire YAML (ex: lan_hosts.v3.withmac_vendor.wifi.yml)
- Applique le schéma enrichi (tous les champs standard ajoutés)
- Place meta en tête (goals/invariants/workflow/adressing)
- Regroupe les hôtes par zone, triés par hostname
- Ajoute un tableau `todo` listant les champs à remplir manuellement
- Écrit lan_hosts.sot.enriched.yml

Usage:
  ./apply_schema_build_sot.py --input lan_hosts.v3.withmac_vendor.wifi.yml \
                              --output lan_hosts.sot.enriched.yml
"""

import argparse
import yaml
from pathlib import Path
from collections import defaultdict

ZONES_ORDER = [
    "infra.home.arpa",
    "cams.home.arpa",
    "iot.home.arpa",
    "media.home.arpa",
    "guest.home.arpa",
    "unassigned",
]

NETWORK_FIELDS = ["ip_current", "ip_target", "interface_type", "multi_interface", "vlan_logique", "dhcp_reservation"]
TECH_FIELDS    = ["os", "hw_model", "serial", "firmware", "capabilities"]
BIZ_FIELDS     = ["location", "owner", "critical", "service_role", "backup_policy"]
SEC_FIELDS     = ["ssh_fingerprint", "cert_expiry", "exposed_ports", "threat_level"]
AUDIT_FIELDS   = ["manufacturer", "first_seen", "last_seen", "status", "provenance", "_scan_history", "notes"]

RECOMMENDED_FOR_TODO = (
    NETWORK_FIELDS +
    TECH_FIELDS +
    BIZ_FIELDS +
    SEC_FIELDS +
    AUDIT_FIELDS
)

def load_yaml(p: Path):
    with open(p, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}

def save_yaml(data, p: Path):
    with open(p, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

def enrich_host(h: dict) -> dict:
    # Copie superficielle
    h = dict(h)

    # Champs de base
    h.setdefault("hostname", None)
    h.setdefault("fqdn", None)
    h.setdefault("zone", None)
    h.setdefault("role", None)
    h.setdefault("aliases", [])

    # Catégories
    for k in NETWORK_FIELDS + TECH_FIELDS + BIZ_FIELDS + SEC_FIELDS + AUDIT_FIELDS:
        if k in ["exposed_ports", "capabilities", "_scan_history", "aliases"]:
            h.setdefault(k, [])
        else:
            h.setdefault(k, None)

    # legacy doit exister
    if not isinstance(h.get("legacy"), dict):
        h["legacy"] = {}

    # TODO list (champs vides recommandés)
    todo = []
    for k in RECOMMENDED_FOR_TODO:
        v = h.get(k, None)
        if v in (None, "", []):
            todo.append(k)
    if todo:
        h["todo"] = sorted(todo)
    else:
        h.pop("todo", None)

    return h

def main():
    ap = argparse.ArgumentParser(description="Apply enriched schema and build SoT grouped by zone.")
    ap.add_argument("--input", "-i", type=Path, required=True, help="Input inventory YAML (e.g., lan_hosts.v3.withmac_vendor.wifi.yml).")
    ap.add_argument("--output", "-o", type=Path, default=Path("lan_hosts.sot.enriched.yml"), help="Output SoT YAML path.")
    args = ap.parse_args()

    data_in = load_yaml(args.input)
    hosts = data_in.get("hosts", [])

    # Enrichir chaque host avec tous les champs du schéma + todo
    groups = defaultdict(list)
    for h in hosts:
        z = h.get("zone") or "unassigned"
        groups[z].append(enrich_host(h))

    # Ordonner les groupes et trier par hostname
    ordered_groups = {}
    for z in ZONES_ORDER:
        if z in groups and groups[z]:
            ordered_groups[z] = sorted(groups[z], key=lambda x: (x.get("hostname") or x.get("name") or ""))

    # Ajouter zones supplémentaires si présentes
    for z in sorted(set(groups.keys()) - set(ZONES_ORDER)):
        ordered_groups[z] = sorted(groups[z], key=lambda x: (x.get("hostname") or x.get("name") or ""))

    # Bloc meta en tête
    addressing_plan = None
    if isinstance(data_in.get("meta"), dict):
        addressing_plan = data_in["meta"].get("addressing_plan")

    meta = {
        "meta": {
            "title": "LAN Source of Truth (SoT)",
            "version": 1,
            "inputs": {
                "file": str(args.input),
                "notes": "Schema-enriched from previous inventory; fields listed in 'todo' must be filled manually."
            },
            "logic": {
                "goals": [
                    "Un seul enregistrement par device (clé = MAC normalisé).",
                    "Séparation claire : legacy (snapshot brut) vs SoT enrichi.",
                    "Plan d’adressage stable, ip_current vs ip_target."
                ],
                "invariants": [
                    "Un MAC = un device unique.",
                    "`legacy` n’est pas modifié (sauf ajout de champs bruts lors des scans).",
                    "Les alias ne doivent pas entrer en conflit entre eux."
                ],
                "zoning": {
                    "order": ZONES_ORDER,
                    "notes": "Regroupement par zone; tri par hostname."
                },
                "addressing": {
                    "plan": addressing_plan or {
                        "infra.home.arpa":  "192.168.10.0/24",
                        "cams.home.arpa":   "192.168.20.0/24",
                        "iot.home.arpa":    "192.168.30.0/24",
                        "media.home.arpa":  "192.168.40.0/24",
                        "guest.home.arpa":  "192.168.50.0/24",
                    },
                    "allocation_rule": "Conserver l’octet final de ip_current quand possible; sinon allouer dès .10 (réserver .0-.9 et .255)."
                },
                "workflow": [
                    "1) Scan Ethernet (MAC/manufacturer).",
                    "2) Scan Wi-Fi (incrémental).",
                    "3) Rebuild SoT (dédup par MAC, regroupement par zone).",
                    "4) Exports CoreDNS/DHCP/hosts depuis la SoT.",
                    "5) CI/CD : validation schema + déploiement NAS/NUC."
                ]
            }
        }
    }

    sot = {**meta, "groups": ordered_groups}
    save_yaml(sot, args.output)
    print(f"[+] SoT generated: {args.output}")

if __name__ == "__main__":
    main()
