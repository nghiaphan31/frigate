#!/usr/bin/env python3
import argparse, csv, re, sys, yaml, datetime
from pathlib import Path

def norm_path(p:str)->str:
    p=p.strip()
    if not p: return ""
    if p.startswith("./"): p=p[2:]
    p=re.sub(r"/+","/",p)
    if not p.startswith("/"): p="/"+p
    # on s'arrête au parent (pas de slash final superflu)
    if p.endswith("/") and p!="/": p=p[:-1]
    return p

def anonymize_homes_literal_to_regex(p:str)->str:
    # remplace /homes/<user> par /homes/[^/]+ (au niveau REGEX, pas littéral)
    return re.sub(r"^/homes/[^/]+", "/homes/[^/]+", p)

def escape_path_for_regex(literal:str)->str:
    # On échappe chaque segment sauf le séparateur /
    segs = literal.strip("/").split("/")
    esc = [re.escape(s) for s in segs if s]
    core = "/".join(esc)
    return core

def to_segment_regex(literal_path:str, anon_homes:bool)->str:
    # literal -> (?i)(^|/)...(/|$) avec anonymisation éventuelle
    lit = norm_path(literal_path)
    if not lit: return None
    if anon_homes:
        lit = anonymize_homes_literal_to_regex(lit)  # introduit du regex
        # si on a mis [^/]+ on ne doit pas l'échapper entièrement; on échappe segment par segment
        parts = []
        for part in lit.strip("/").split("/"):
            if part == "[^/]+":
                parts.append(part)
            else:
                parts.append(re.escape(part))
        core = "/".join(parts)
    else:
        core = escape_path_for_regex(lit)
    return rf"(?i)(^|/){core}(/|$)"

def load_marks(tsv_path:Path):
    rows=[]
    with tsv_path.open("r", encoding="utf-8", newline="") as f:
        hdr = f.readline()
        # détecte séparateur (tab ou csv)
        dialect = csv.Sniffer().sniff(hdr + f.read(2048), delimiters="\t,;")
        f.seek(0)
        r = csv.DictReader(f, dialect=dialect)
        for row in r:
            rows.append(row)
    return rows

def unique(seq):
    out=[]; seen=set()
    for x in seq:
        if x and x not in seen:
            seen.add(x); out.append(x)
    return out

def append_to_family(doc, bucket:str, family_id:str, patterns):
    fams = (doc.get("families",{}) or {}).get(bucket) or []
    target = None
    for fam in fams:
        if fam.get("id")==family_id:
            target=fam; break
    if not target:
        # crée la famille si absente
        target={"id":family_id, "patterns":[]}
        fams.append(target)
        doc["families"].setdefault(bucket, fams)
    pats = target.setdefault("patterns", [])
    before=len(pats)
    # dédoublonne
    existing=set(pats)
    for p in patterns:
        if p not in existing:
            pats.append(p); existing.add(p)
    return before, len(pats)

def main():
    ap = argparse.ArgumentParser(description="Convert annotated tree marks to policy snippets, optionally patch policy.yaml")
    ap.add_argument("--marks", required=True, help="path to tree.mark.tsv or .csv")
    ap.add_argument("--outdir", required=False, help="where to write snippets (default: same dir as marks)")
    ap.add_argument("--anon-homes", action="store_true", help="generalize /homes/<user>/ to /homes/[^/]+/")
    ap.add_argument("--policy", help="policy.yaml to patch")
    ap.add_argument("--soft-id", default="MEDIA-NOISE", help="exclude_soft family id to receive X rules")
    ap.add_argument("--keep-id", default="KEEP-01", help="keep family id to receive K rules")
    ap.add_argument("--patch", action="store_true", help="append generated rules into policy.yaml")
    args = ap.parse_args()

    marks_path = Path(args.marks)
    outdir = Path(args.outdir) if args.outdir else marks_path.parent
    outdir.mkdir(parents=True, exist_ok=True)

    rows = load_marks(marks_path)
    excl, keep = [], []
    for row in rows:
        mark = (row.get("mark","") or row.get("MARK","")).strip().upper()
        path = row.get("path") or row.get("PATH") or ""
        if not path: continue
        if mark not in ("X","K"):  # ignore vide/none
            continue
        rx = to_segment_regex(path, anon_homes=args.anon_homes)
        if not rx: continue
        (excl if mark=="X" else keep).append(rx)

    excl = unique(excl); keep = unique(keep)

    ts = datetime.datetime.now().strftime("%Y-%m-%d_%H%M%S")
    excl_snip = outdir/f"exclude_snippet_{ts}.yaml"
    keep_snip = outdir/f"keep_snippet_{ts}.yaml"
    excl_snip.write_text("# Generated from tree marks (X)\npatterns:\n" + "".join([f"- '{p}'\n" for p in excl]), encoding="utf-8")
    keep_snip.write_text("# Generated from tree marks (K)\npatterns:\n" + "".join([f"- '{p}'\n" for p in keep]), encoding="utf-8")

    print(f"✅ Wrote {excl_snip}")
    print(f"✅ Wrote {keep_snip}")
    print(f"   X patterns: {len(excl)} | K patterns: {len(keep)}")

    if args.patch:
        if not args.policy:
            print("[WARN] --patch requires --policy", file=sys.stderr)
            sys.exit(2)
        pol_path = Path(args.policy)
        doc = yaml.safe_load(pol_path.read_text(encoding="utf-8"))
        if "families" not in doc: doc["families"]={}
        # append to MEDIA-NOISE (exclude_soft) and KEEP-01 (keep)
        b1,a1 = append_to_family(doc, "exclude_soft", args.soft_id, excl)
        b2,a2 = append_to_family(doc, "keep", args.keep_id, keep)
        pol_path.write_text(yaml.safe_dump(doc, sort_keys=False, allow_unicode=True), encoding="utf-8")
        print(f"🩹 Patched {pol_path}")
        print(f"   {args.soft_id}: {b1} → {a1} patterns")
        print(f"   {args.keep_id}: {b2} → {a2} patterns")

if __name__=="__main__":
    main()
