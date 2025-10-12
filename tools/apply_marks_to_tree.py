#!/usr/bin/env python3
import csv, argparse, re
from pathlib import Path
from datetime import datetime

def norm(p: str) -> str:
    p = (p or "").strip()
    if p.startswith("./"): p = p[2:]
    p = re.sub(r"/+", "/", p)
    if not p.startswith("/"): p = "/" + p
    return p.rstrip("/")

def split_homes(p: str):
    parts = [s for s in p.split("/") if s]
    if len(parts) >= 3 and parts[0] == "homes":
        return True, parts[1], "/" + "/".join(parts[2:])
    return False, "", ""

def load_marks(mark_tsv: Path, anon_homes: bool):
    """Return two dicts:
       X_rules and K_rules: path -> {'is_dir_or_file': True, 'is_dir_only': True}
       When user didn’t add trailing '/', we treat as dir-or-file (i.e. match node and descendants).
       If anon_homes is True, store a normalized suffix for /homes/<user>/… matches."""
    X = {}
    K = {}
    with mark_tsv.open("r", encoding="utf-8", newline="") as f:
        r = csv.DictReader(f, delimiter="\t")
        for row in r:
            raw = (row.get("path") or row.get("prefix") or "").strip()
            if not raw: continue
            m = (row.get("mark") or "").upper()
            is_dir_only = raw.endswith("/")
            p = norm(raw)  # store w/o trailing '/'
            rule = {"p": p, "is_dir_only": bool(is_dir_only),
                    "is_dir_or_file": not is_dir_only}
            if anon_homes:
                is_h, user, suf = split_homes(p)
                rule["is_homes"] = is_h
                rule["suffix"] = suf if is_h else None
            else:
                rule["is_homes"] = False
                rule["suffix"] = None
            if m == "X":
                X[p] = rule
            elif m == "K":
                K[p] = rule
    return X, K

def match_rule(cand: str, rule: dict) -> bool:
    """cand is normalized w/o trailing slash"""
    if not rule.get("is_homes"):
        if rule["is_dir_only"]:
            return cand == rule["p"] or cand.startswith(rule["p"] + "/")
        else:  # dir-or-file
            return cand == rule["p"] or cand.startswith(rule["p"] + "/")
    # homes-agnostic: compare suffix after /homes/<user>
    is_h, user, suffix = split_homes(cand)
    if not is_h: return False
    suf = rule.get("suffix") or "/"
    if rule["is_dir_only"]:
        return suffix == suf or suffix.startswith(suf.rstrip("/") + "/")
    else:
        return suffix == suf or suffix.startswith(suf.rstrip("/") + "/")

def inherited_exclude(cand: str, X_rules: dict):
    """Return (True, ancestor_path) if excluded by any X rule (explicit or ancestor). Prefer the longest match."""
    cand = norm(cand)
    best = None
    for p, ru in X_rules.items():
        if match_rule(cand, ru):
            if best is None or len(p) > len(best):
                best = p
    return (best is not None), best

def load_tree(tree_tsv: Path):
    with tree_tsv.open("r", encoding="utf-8", newline="") as f:
        r = csv.DictReader(f, delimiter="\t")
        rows = list(r)
        hdr  = r.fieldnames or []
    return hdr, rows

def write_tsv(path: Path, rows, cols):
    with path.open("w", encoding="utf-8", newline="") as w:
        wr = csv.DictWriter(w, fieldnames=cols, delimiter="\t")
        wr.writeheader()
        for row in rows:
            wr.writerow({c: row.get(c, "") for c in cols})

def main():
    ap = argparse.ArgumentParser(description="Build post-annotation tree TSV (flags + pruned view for next iteration).")
    ap.add_argument("--tree", required=True, help="tree.fixed.tsv (with at least a 'path' column)")
    ap.add_argument("--marks", required=True, help="tree.mark.tsv (path, mark)")
    ap.add_argument("--outdir", required=True, help="output directory")
    ap.add_argument("--anon-homes", action="store_true", help="make /homes marks user-agnostic")
    ap.add_argument("--prune-kept", action="store_true", help="also prune K (default: keep K visible)")
    args = ap.parse_args()

    outdir = Path(args.outdir); outdir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d_%H%M%S")

    hdr, tree_rows = load_tree(Path(args.tree))
    if not tree_rows or ("path" not in (hdr or [])):
        print("❌ Invalid tree TSV (no rows or no 'path' column)."); return

    X_rules, K_rules = load_marks(Path(args.marks), args.anon_homes)

    # Prepare output rows with flags
    add_cols = ["mark_explicit", "mark_effective", "inherit_from"]
    cols = add_cols + [c for c in hdr if c not in add_cols]

    post_rows = []
    kept_rows = []
    n_x_eff = n_k_eff = 0

    # Build quick lookup for explicit marks
    explicit = {}
    for p, ru in X_rules.items(): explicit[norm(p)] = "X"
    for p, ru in K_rules.items(): explicit[norm(p)] = "K"

    for row in tree_rows:
        p_raw = row.get("path","").strip()
        if not p_raw: continue
        p = norm(p_raw)

        exp = explicit.get(p, "")
        is_x, ancestor = inherited_exclude(p, X_rules)

        eff = "X" if is_x else ("K" if exp=="K" else "")
        if eff == "X": n_x_eff += 1
        if eff == "K": n_k_eff += 1

        row2 = dict(row)
        row2["mark_explicit"] = exp
        row2["mark_effective"] = eff
        row2["inherit_from"] = ancestor or ""
        post_rows.append(row2)

        if eff == "X" or (args.prune_kept and eff == "K"):
            # pruned out
            pass
        else:
            kept_rows.append(row2)

    post = outdir / f"tree.fixed.post_{ts}.tsv"
    nxt  = outdir / f"tree.fixed.to_annotate_{ts}.tsv"
    write_tsv(post, post_rows, cols)
    write_tsv(nxt,  kept_rows, cols)

    print(f"✅ post: {post}  rows={len(post_rows)}   (X_effective={n_x_eff}, K_effective={n_k_eff})")
    print(f"✅ next: {nxt}   rows={len(kept_rows)}   (pruned X{' + K' if args.prune_kept else ''})")

if __name__ == "__main__":
    main()
