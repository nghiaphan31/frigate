#!/usr/bin/env python3
import csv, argparse, re
from pathlib import Path

def norm_path(p: str) -> str:
    p = (p or "").strip()
    if p.startswith("./"): p = p[2:]
    p = re.sub(r"/+", "/", p)
    if not p.startswith("/"): p = "/" + p
    return p

def is_under(candidate: str, folder: str) -> bool:
    if candidate == folder: return True
    return candidate.startswith(folder + "/")

def split_homes(p: str):
    parts = [s for s in p.split("/") if s]
    if len(parts) >= 3 and parts[0] == "homes":
        after_user = "/" + "/".join(parts[2:]) if len(parts) > 2 else "/"
        return True, "/homes", after_user
    return False, "", ""

def load_excludes(mark_tsv: Path, anon_homes: bool):
    """
    Record X marks. If raw endswith('/'): is_dir=True.
    Otherwise is_dir=None (unknown) -> will match BOTH exact file and descendants.
    """
    excl = []
    with mark_tsv.open("r", encoding="utf-8", newline="") as f:
        r = csv.DictReader(f, delimiter="\t")
        for row in r:
            mark = (row.get("mark") or "").upper()
            if mark != "X": continue
            raw = row.get("path") or row.get("prefix") or ""
            if not raw: continue
            ends_slash = raw.endswith("/")
            p = norm_path(raw.rstrip("/"))
            is_dir = True if ends_slash else None  # None => treat as dir-or-file
            if anon_homes:
                is_h, _, rest = split_homes(p)
                excl.append(("homes_agnostic" if is_h else "exact", p, is_dir, rest))
            else:
                excl.append(("exact", p, is_dir, None))
    return excl

def matches(candidate: str, rules, anon_homes: bool) -> bool:
    c = norm_path(candidate.rstrip("/"))
    for kind, p, is_dir, rest in rules:
        if kind == "exact":
            if is_dir is True:
                if is_under(c, p): return True
            elif is_dir is None:
                # Unknown => treat as directory-or-file
                if c == p or is_under(c, p): return True
            else:  # is_dir is False (unused in this workflow)
                if c == p: return True
        else:  # homes_agnostic
            parts = [s for s in c.split("/") if s]
            if len(parts) >= 3 and parts[0] == "homes":
                cand_suffix = "/" + "/".join(parts[2:]) if len(parts) > 2 else "/"
                base_suffix = rest or "/"
                if is_dir is True:
                    if cand_suffix == base_suffix or cand_suffix.startswith(base_suffix.rstrip("/") + "/"):
                        return True
                elif is_dir is None:
                    if cand_suffix == base_suffix or cand_suffix.startswith(base_suffix.rstrip("/") + "/"):
                        return True
                else:
                    if cand_suffix == base_suffix:
                        return True
    return False

def main():
    ap = argparse.ArgumentParser(description="Prefilter candidates using X marks from tree.mark.tsv (path-based, no regex).")
    ap.add_argument("--marks", required=True, help="tree.mark.tsv")
    ap.add_argument("--input", required=True, help="raw candidates list (may contain ./prefix)")
    ap.add_argument("--output", required=True, help="filtered candidates list")
    ap.add_argument("--anon-homes", action="store_true", help="treat /homes/<user>/… marks as user-agnostic")
    ap.add_argument("--show", type=int, default=0, help="show first N dropped lines for debug")
    args = ap.parse_args()

    rules = load_excludes(Path(args.marks), args.anon_homes)

    kept = 0; dropped = 0; shown = 0
    with open(args.input, "r", encoding="utf-8") as fin, open(args.output, "w", encoding="utf-8") as fout:
        for line in fin:
            s = line.rstrip("\n")
            if not s: continue
            if matches(s, rules, args.anon_homes):
                dropped += 1
                if args.show and shown < args.show:
                    print(f"DROP: {s}")
                    shown += 1
            else:
                fout.write(s + "\n")
                kept += 1

    print(f"Kept {kept:,} lines; Dropped {dropped:,} lines using {len(rules)} X marks "
          f"({'anon-homes on' if args.anon_homes else 'anon-homes off'}).")

if __name__ == "__main__":
    main()
