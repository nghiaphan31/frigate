#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ingest_media.py — Ingestion de médias en CAS (BLAKE3) avec journalisation et métadonnées.
- Conserve chemin original, tailles, mtime, SHA256, BLAKE3.
- Écrit vers CAS: CAS_ROOT/<b3[:2]>/<b3[2:4]>/<b3>
- Idempotent: si l’objet CAS existe, on SKIP.
- Sorties dans --run-dir: manifest.jsonl, manifest.csv, counts.json (+ symlinks si --link-back)
"""

import argparse, os, sys, time, json, csv, hashlib, shutil
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import blake3
except Exception as e:
    print(f"[FATAL] blake3 non disponible: {e}", file=sys.stderr)
    sys.exit(2)

BUF = 1024 * 1024

def hash_file(path: Path):
    sha = hashlib.sha256()
    b3 = blake3.blake3()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(BUF)
            if not chunk: break
            sha.update(chunk)
            b3.update(chunk)
    return sha.hexdigest(), b3.hexdigest()

def safe_mkdirs(p: Path): p.mkdir(parents=True, exist_ok=True)

def cas_path(cas_root: Path, b3_hex: str) -> Path:
    return cas_root / b3_hex[:2] / b3_hex[2:4] / b3_hex

def hardlink_or_copy(src: Path, dst: Path):
    try:
        os.link(src, dst); return "hardlink"
    except OSError:
        shutil.copy2(src, dst); return "copy"

def sanitize_rel(line: str) -> str:
    line = line.strip()
    if not line: return ""
    if line.startswith("./"): line = line[2:]
    return line.lstrip("/")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--mount-root", default="/mnt/nas")
    ap.add_argument("--cas-root", required=True)
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--link-back", action="store_true")
    ap.add_argument("--git-rev", default="")
    args = ap.parse_args()

    mount_root = Path(args.mount_root)
    cas_root   = Path(args.cas_root)
    run_dir    = Path(args.run_dir)
    safe_mkdirs(run_dir)
    links_dir  = run_dir / "links"
    if args.link_back: safe_mkdirs(links_dir)

    list_path = Path(args.list)
    if not list_path.is_file():
        print(f"[FATAL] Liste introuvable: {list_path}", file=sys.stderr); sys.exit(2)
    cas_root.mkdir(parents=True, exist_ok=True)

    # Pré-comptage
    with list_path.open("r", encoding="utf-8", errors="replace") as f:
        total = sum(1 for _ in f)

    jpath = run_dir / "manifest.jsonl"
    cpath = run_dir / "manifest.csv"
    manifest_jsonl = jpath.open("a", encoding="utf-8", newline="")
    manifest_csv_f = cpath.open("a", encoding="utf-8", newline="")
    csvw = csv.writer(manifest_csv_f, delimiter=";")
    if manifest_csv_f.tell() == 0:
        csvw.writerow(["status","error","orig_rel","src_path","size","mtime","sha256","blake3","cas_path","link_action"])

    counts = {"total": total, "done": 0, "ok": 0, "skip": 0, "err": 0}
    counts_path = run_dir / "counts.json"

    def process_one(rel_line: str):
        rel = sanitize_rel(rel_line)
        if not rel: return {"status":"skip","error":"empty","orig_rel":rel}
        src = mount_root / rel
        if not src.exists() or not src.is_file():
            return {"status":"err","error":"missing_or_not_file","orig_rel":rel}
        try:
            st = src.stat(); size = st.st_size; mtime = int(st.st_mtime)
            sha, b3 = hash_file(src)
            dst = cas_path(cas_root, b3)
            safe_mkdirs(dst.parent)
            link_action = ""
            if dst.exists():
                status = "skip"
            else:
                link_action = hardlink_or_copy(src, dst)
                status = "ok"
            # link-back
            if args.link_back:
                lb = links_dir / rel
                safe_mkdirs(lb.parent)
                try:
                    if lb.exists() or lb.is_symlink(): lb.unlink()
                except Exception: pass
                try: lb.symlink_to(dst)
                except Exception: pass
            return {
                "status": status, "error": "",
                "orig_rel": rel, "src_path": str(src),
                "size": size, "mtime": mtime,
                "sha256": sha, "blake3": b3, "cas_path": str(dst),
                "link_action": link_action,
            }
        except Exception as e:
            return {"status":"err","error":str(e),"orig_rel":rel}

    futures = []
    with list_path.open("r", encoding="utf-8", errors="replace") as f, \
         ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
        for line in f: futures.append(ex.submit(process_one, line))
        last_print = time.time()
        for fut in as_completed(futures):
            rec = fut.result()
            counts["done"] += 1
            counts[rec["status"]] = counts.get(rec["status"], 0) + 1
            out = {
                "ts": int(time.time()),
                **{k: rec.get(k,"") for k in
                   ("status","error","orig_rel","src_path","size","mtime","sha256","blake3","cas_path","link_action")}
            }
            manifest_jsonl.write(json.dumps(out, ensure_ascii=False) + "\n"); manifest_jsonl.flush()
            csvw.writerow([out["status"], out["error"], out["orig_rel"], out["src_path"],
                           out["size"], out["mtime"], out["sha256"], out["blake3"],
                           out["cas_path"], out["link_action"]]); manifest_csv_f.flush()
            if counts["done"] % 50 == 0 or (time.time() - last_print) > 10:
                counts_path.write_text(json.dumps(counts, ensure_ascii=False, indent=2), encoding="utf-8")
                print(f"[PROGRESS] {counts['done']}/{counts['total']} ok={counts['ok']} skip={counts['skip']} err={counts['err']}", flush=True)
                last_print = time.time()

    counts_path.write_text(json.dumps(counts, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[DONE] {counts}", flush=True)

if __name__ == "__main__":
    main()
