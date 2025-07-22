#!/usr/bin/env python3
"""
mqtt logs -to be parsed by this script- are typically in /var/log/mqtt folder

mqtt_inventory_ring.py – Ring topic inventory ➜ clean YAML
========================================================

• **Starts with‑filter**: by default keeps topics that begin with
  ``ring/`` (case‑insensitive). Override with ``‑p REGEX``.
• **Optional attribute filter**: ``‑a lastDisarmedBy`` keeps only topics
  whose payload ever contained that attribute key.
• Counts messages (``count``) and per‑value frequencies.
• Writes *plain* YAML – no Python tags.

Usage examples
--------------
```bash
# 1. Default – topics starting with ring/
python3 mqtt_inventory_ring.py mqtt.log > ring.yaml

# 2. Topics starting with ring/ that also contain attribute lastDisarmedBy
python3 mqtt_inventory_ring.py mqtt.log \
        -a lastDisarmedBy               \
        > ring_lastdisarmed.yaml

# 3. Any topic that contains "alarm" anywhere
python3 mqtt_inventory_ring.py mqtt.log -p "ring/.*alarm" > ring_alarm.yaml
```
"""

import sys, re, json, gzip, pathlib, argparse, yaml
from typing import Dict, Any

# ── CLI ----------------------------------------------------------------------
cli = argparse.ArgumentParser(description="Summarise MQTT topics to YAML.")
cli.add_argument("logfile", help="mosquitto_sub log file (.log or .gz)")
cli.add_argument("-p", "--pattern", default="^ring/",
                metavar="REGEX",
                help="Regex applied from the *beginning* of each topic "
                     "(default: '^ring/', case‑insensitive)")
cli.add_argument("-a", "--attribute", default=None,
                help="Only include topics whose payload contains this "
                     "attribute key at least once")
args = cli.parse_args()

try:
    TOPIC_RE = re.compile(args.pattern, re.IGNORECASE)
except re.error as err:
    sys.exit(f"[ERROR] Invalid regex: {err}")

# ── inventory container ------------------------------------------------------
Inv: Dict[str, Dict[str, Any]] = {}

def bump(topic: str, key: str, val: str = "") -> None:
    """Increment counters inside *Inv* in‑place."""
    ent = Inv.setdefault(topic, {"count": 0, "attrs": {}})
    if key == "__count__":
        ent["count"] += 1
        return
    bucket = ent["attrs"].setdefault(key, {})
    bucket[val] = bucket.get(val, 0) + 1

# ── open log (handles .gz) ---------------------------------------------------
path = pathlib.Path(args.logfile)
open_fn = gzip.open if path.suffix == ".gz" else open

# ── parse log ----------------------------------------------------------------
with open_fn(path, "rt", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        if " : " not in raw:
            continue
        _, remaining = raw.rstrip("\n").split(" : ", 1)  # drop timestamp

        if " : " in remaining:
            topic, payload = remaining.split(" : ", 1)
        else:  # mosquitto_sub -v style
            parts = remaining.split(None, 1)
            if len(parts) != 2:
                continue
            topic, payload = parts

        if not TOPIC_RE.match(topic):
            continue  # topic doesn’t match regex

        bump(topic, "__count__")
        payload = payload.strip()

        # attempt JSON
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            bump(topic, "__payload", payload)
            continue

        if isinstance(data, dict):
            for k, v in data.items():
                bump(topic, k, json.dumps(v, ensure_ascii=False))
        else:  # non‑dict JSON
            bump(topic, "__payload", json.dumps(data, ensure_ascii=False))

# ── optional attribute post‑filter -------------------------------------------
if args.attribute:
    Inv = {t: info for t, info in Inv.items() if args.attribute in info["attrs"]}

# ── dump YAML ----------------------------------------------------------------
if not Inv:
    sys.stderr.write("[INFO] No topics matched – empty report.\n")
    sys.exit(0)

yaml.safe_dump(Inv, sys.stdout, allow_unicode=True, sort_keys=False)
