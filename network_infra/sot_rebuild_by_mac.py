#!/usr/bin/env python3
"""
sot_rebuild_by_mac.py
Rebâtit la "source de vérité" à partir d'un YAML lan_hosts.*.yml :
- meta en tête (règles + logique d'usage)
- déduplication par MAC (1 mac = 1 device)
- regroupement par zone et tri par hostname

Usage :
  ./sot_rebuild_by_mac.py \
      --input lan_hosts.v3.withmac_vendor.wifi.yml \
      --output lan_hosts.sot.yml
"""

from pathlib import Path
import argparse
import yaml
import copy

ZONES_ORDER = [
    "infra.home.arpa",
    "cams.home.arpa",
    "iot.home.arpa",
    "media.home.arpa",
    "guest.home.arpa",
    "unassigned",
]

def load_yaml(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f) or {}

def save_yaml(data, path: Path):
    # meta doit apparaître en premier => sort_keys=False et structure déjà ordonnée
    with open(path, "w", encoding="utf-8") as f:
        yaml.safe_dump(data, f, allow_unicode=True, sort_keys=False)

def norm_mac(mac):
    if not mac: return None
    m = mac.strip().upper()
    # tolérer formats avec "-" ou pas de séparateurs
    if ":" not in m and "-" in m:
        m = m.replace("-", ":")
    if ":" not in m and len(m) == 12:
        m = ":".join(m[i:i+2] for i in range(0,12,2))
    return m

def pick_best(primary, candidate):
    """
    Choisit l'entrée "best" à garder lors d'un merge par MAC.
    Règles :
      1) Préfère celle qui a ip_current
      2) Sinon celle avec confidence legacy la plus haute
      3) Sinon garde la première
    """
    def has_ip(h): return bool(h.get("ip_current"))
    def conf(h):
        lg = h.get("legacy") or {}
        try:
            return float(lg.get("confidence", 0.0))
        except Exception:
            return 0.0

    if has_ip(candidate) and not has_ip(primary):
        return candidate, primary
    if has_ip(primary) and not has_ip(candidate):
        return primary, candidate

    if conf(candidate) > conf(primary):
        return candidate, primary
    return primary, candidate

def merge_entries(base, other):
    """
    Merge non destructif :
      - On garde base comme référence.
      - On ne touche PAS au bloc legacy existant, sauf pour enregistrer l'historique.
      - On complète champs top-level si absents dans base (hostname, zone, fqdn, role, aliases, ip_target, manufacturer, location, vendor, notes).
      - Historique des merges : base.legacy._merged (liste des legacy de 'other' + name/fqdns/ip_current/ip_target d’origine)
    """
    # champs à compléter si absents
    for key in ["hostname","zone","fqdn","role","ip_current","ip_target","manufacturer","location","vendor","notes"]:
        if key not in base or base.get(key) in (None, "", []):
            if other.get(key) not in (None, "", []):
                base[key] = other.get(key)

    # union d'aliases
    a = set(base.get("aliases") or [])
    b = set(other.get("aliases") or [])
    base["aliases"] = sorted(a.union(b)) if a or b else []

    # historique merge
    base.setdefault("legacy", {})
    merged = base["legacy"].setdefault("_merged", [])
    o_leg = copy.deepcopy(other.get("legacy") or {})
    o_leg["_name"] = other.get("name")
    o_leg["_fqdn"] = other.get("fqdn")
    o_leg["_ip_current"] = other.get("ip_current")
    o_leg["_ip_target"] = other.get("ip_target")
    merged.append(o_leg)

    return base

def rebuild_by_mac(hosts):
    """
    Dédoublonne par MAC. Si MAC absent => bucket 'no_mac'.
    Retourne : dict mac->entry (fusionné) et liste de orphelins sans MAC.
    """
    mac_map = {}
    no_mac = []

    for h in hosts:
        # s'assurer que legacy est un dict
        if not isinstance(h.get("legacy"), dict):
            h["legacy"] = {}
        lg = h["legacy"]

        mac = norm_mac(lg.get("mac"))
        if mac:
            if mac not in mac_map:
                # première occurrence de ce device
                mac_map[mac] = h
            else:
                # merge avec la meilleure entrée
                best, other = pick_best(mac_map[mac], h)
                if best is not mac_map[mac]:
                    # on remplace la base par la meilleure, puis fusionne l'ancienne
                    old = mac_map[mac]
                    mac_map[mac] = best
                    merge_entries(mac_map[mac], old)
                    merge_entries(mac_map[mac], other)
                else:
                    merge_entries(mac_map[mac], other)
        else:
            no_mac.append(h)
    return mac_map, no_mac

def group_by_zone(mac_map, orphans):
    groups = {z: [] for z in ZONES_ORDER}
    # devices avec MAC
    for mac, h in mac_map.items():
        zone = h.get("zone") or "unassigned"
        if zone not in groups:
            groups[zone] = []
        h["legacy"]["mac"] = mac  # s'assurer que le mac normalisé reste
        groups[zone].append(h)
    # orphelins sans MAC
    for h in orphans:
        zone = h.get("zone") or "unassigned"
        if zone not in groups:
            groups[zone] = []
        groups[zone].append(h)

    # tri par hostname dans chaque zone
    for z in groups:
        groups[z].sort(key=lambda x: (x.get("hostname") or x.get("name") or ""))

    # ne garder que les zones non vides + ordre préféré
    ordered_groups = {z: groups[z] for z in ZONES_ORDER if groups.get(z)}
    # ajouter zones supplémentaires non prévues
    for z in sorted(set(groups.keys()) - set(ZONES_ORDER)):
        if groups[z]:
            ordered_groups[z] = groups[z]

    return ordered_groups

def build_meta(input_path, data_before):
    # Essaye de récupérer le plan d’adressage existant si présent
    addressing_plan = None
    if isinstance(data_before, dict) and "meta" in data_before:
        addressing_plan = data_before["meta"].get("addressing_plan")

    return {
        "meta": {
            "title": "LAN Source of Truth (SoT)",
            "version": 1,
            "inputs": {
                "file": str(input_path),
                "notes": "Construit à partir du YAML enrichi (Ethernet + Wi-Fi)."
            },
            "logic": {
                "goals": [
                    "Une entrée unique par device (clé = MAC).",
                    "Hébergement des infos d’origine dans `legacy` (snapshot + historique).",
                    "Référencement par FQDN stable (`hostname.zone`).",
                    "Plan d’adressage cible `ip_target` découplé du plan courant `ip_current`.",
                ],
                "invariants": [
                    "`legacy` n’est jamais écrasé (hors ajout de `mac` si manquant lors des scans).",
                    "Un MAC correspond à un et un seul device.",
                    "Les alias (`aliases`) ne doivent pas entrer en conflit avec d’autres labels.",
                ],
                "deduplication_rules": [
                    "Clé primaire = `legacy.mac` normalisé.",
                    "Choix de l’entrée principale : présence de `ip_current` prioritaire.",
                    "Sinon, plus forte `legacy.confidence`.",
                    "Les autres entrées sont conservées dans `legacy._merged` (audit).",
                ],
                "zoning": {
                    "order": ZONES_ORDER,
                    "notes": "Regroupement par `zone`; tri par `hostname`.",
                },
                "addressing": {
                    "plan": addressing_plan or {
                        "infra.home.arpa":  "192.168.10.0/24",
                        "cams.home.arpa":   "192.168.20.0/24",
                        "iot.home.arpa":    "192.168.30.0/24",
                        "media.home.arpa":  "192.168.40.0/24",
                        "guest.home.arpa":  "192.168.50.0/24",
                    },
                    "allocation_rule": "Conserver l’octet final de `ip_current` quand possible; sinon allouer à partir de .10 (réserver .0-.9 et .255)."
                },
                "workflow": [
                    "1) Scanner Ethernet (enrichir legacy.mac + manufacturer si possible).",
                    "2) Scanner Wi-Fi (incrémental) pour compléter ce que l’Ethernet n’a pas vu.",
                    "3) Rebuild SoT (ce script) : dédup par MAC, regrouper par zone, trier.",
                    "4) Générer exports (CoreDNS, /etc/hosts) depuis la SoT, pas depuis les scans bruts.",
                    "5) Commit Git + CI de déploiement (NAS/NUC).",
                ],
            },
        }
    }

def main():
    ap = argparse.ArgumentParser(description="Rebuild SoT by MAC and group by zone.")
    ap.add_argument("--input", "-i", type=Path, required=True, help="YAML enrichi (après scans).")
    ap.add_argument("--output", "-o", type=Path, default=Path("lan_hosts.sot.yml"), help="YAML SoT en sortie.")
    args = ap.parse_args()

    data_in = load_yaml(args.input)
    hosts = data_in.get("hosts", [])

    # Dédoublonnage par MAC
    mac_map, orphans = rebuild_by_mac(hosts)
    groups = group_by_zone(mac_map, orphans)

    # META au début + groups
    sot = build_meta(args.input, data_in)
    sot.update({"groups": groups})

    save_yaml(sot, args.output)
    print(f"[+] SoT rebuilt: {args.output}")
    print(f"    Devices with MAC : {len(mac_map)}")
    print(f"    Entries without MAC : {len(orphans)}")

if __name__ == "__main__":
    main()
