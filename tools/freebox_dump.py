#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Export des appareils Freebox (hostname, MAC, IP, interface, actif) en CSV.
# 1) python3 freebox_dump.py register
#    -> Valider sur l'écran Freebox (autorisation)
# 2) python3 freebox_dump.py dump
#    -> Génère devices.csv dans le dossier courant

import hashlib, hmac, json, os, sys, time
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

BOX_URL = "http://mafreebox.freebox.fr"
APP_ID = "com.example.inventory"
APP_NAME = "LAN Inventory"
APP_VERSION = "1.0"
DEVICE_NAME = "script"

STORE = os.path.expanduser("~/.freebox_app.json")

def http(method, path, headers=None, data=None):
    """
    Appel HTTP simple. `path` commence par '/' (ex: '/api/v15/login/...').
    """
    import json as _json
    from urllib.request import Request, urlopen
    url = BOX_URL + (path if path.startswith("/") else "/" + path)
    req = Request(url, data=(_json.dumps(data).encode() if isinstance(data, dict) else data), method=method)
    if headers:
        for k, v in headers.items():
            req.add_header(k, v)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "freebox-dump/1.0")
    with urlopen(req, timeout=8) as r:
        txt = r.read().decode()
        try:
            return _json.loads(txt)
        except Exception:
            raise SystemExit(f"Réponse non-JSON depuis {url}: {txt[:200]}")

def get_api_base():
    """
    Détermine l'URL de base exacte (ex: '/api/v15') à partir de /api_version.
    """
    info = http("GET", "/api_version")
    ver = info.get("api_version", "15.0")
    major = str(ver).split(".")[0]
    return f"/api/v{major}"

def open_session(app_id, app_token):
    """
    Ouvre une session (X-Fbx-App-Auth) en vXX correcte.
    """
    import hashlib, hmac
    api = get_api_base()
    chal = http("GET", f"{api}/login/")["result"]["challenge"]
    pwd = hmac.new(app_token.encode(), chal.encode(), hashlib.sha1).hexdigest()
    sess = http("POST", f"{api}/login/session/", data={"app_id": app_id, "password": pwd})
    return api, sess["result"]["session_token"]


def register():
    api = get_api_base()
    payload = {
        "app_id": APP_ID,
        "app_name": APP_NAME,
        "app_version": APP_VERSION,
        "device_name": DEVICE_NAME
    }
    resp = http("POST", f"{api}/login/authorize/", data=payload)
    track_id = resp["result"]["track_id"]
    app_token = resp["result"]["app_token"]
    print("👉 Autorise la demande sur l'écran de la Freebox… (tu as ~1 minute)")
    # On poll jusqu'à acceptation
    for _ in range(30):
        st = http("GET", f"{api}/login/authorize/{track_id}")
        status = st["result"]["status"]
        if status == "granted":
            with open(STORE, "w") as f:
                json.dump({"app_id": APP_ID, "app_token": app_token}, f)
            print("✅ Autorisé. Jeton enregistré dans", STORE)
            return
        elif status in ("denied", "timeout"):
            raise SystemExit(f"❌ Autorisation {status}")
        time.sleep(2)
    raise SystemExit("❌ Temps dépassé")


def dump_devices():
    if not os.path.exists(STORE):
        raise SystemExit("Pas d’autorisation trouvée. Lance d’abord: python3 freebox_dump.py register")
    creds = json.load(open(STORE))
    api, token = open_session(creds["app_id"], creds["app_token"])
    headers = {"X-Fbx-App-Auth": token}

    # Liste publique LAN
    data = http("GET", f"{api}/lan/browser/pub/", headers=headers)
    items = data["result"]

    # Aplatissement en lignes
    rows = []
    def add_row(hostname, mac, ip, iface, active):
        rows.append((hostname or "", mac or "", ip or "", iface or "", "yes" if active else "no"))

    for it in items:
        # Chaque entrée peut avoir plusieurs "l3connectivities" (plusieurs IP)
        hostname = it.get("primary_name") or it.get("l2ident", {}).get("name") or it.get("hostname")
        mac = (it.get("l2ident") or {}).get("id")
        active = it.get("active", False)
        iface = it.get("iface", "")
        l3 = it.get("l3connectivities") or []
        if not l3:
            add_row(hostname, mac, "", iface, active)
        else:
            for c in l3:
                add_row(hostname, mac, c.get("addr"), iface, active)

    # Écrit CSV
    out = "devices.csv"
    with open(out, "w", encoding="utf-8") as f:
        f.write("hostname,mac,ip,iface,active\n")
        for r in rows:
            f.write(",".join(x.replace(",", "_") for x in r) + "\n")
    print(f"✅ Exporté: {out} ({len(rows)} lignes)")

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("register", "dump"):
        print("Usage: python3 freebox_dump.py register|dump")
        sys.exit(1)
    if sys.argv[1] == "register":
        register()
    else:
        dump_devices()
