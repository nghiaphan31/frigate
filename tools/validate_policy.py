#!/usr/bin/env python3
import sys, re, argparse, yaml, json
from pathlib import Path

def err(msg): print(f"[ERROR] {msg}", file=sys.stderr)
def warn(msg): print(f"[WARN]  {msg}", file=sys.stderr)
def info(msg): print(f"[OK]    {msg}")

def is_strlist(x): return isinstance(x, list) and all(isinstance(s, str) for s in x)

def load_policy(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        return data, None
    except Exception as e:
        return None, f"YAML parse error: {e}"

def collect_family_ids(section):
    ids = []
    for i, fam in enumerate(section or []):
        fid = fam.get("id")
        if not isinstance(fid, str) or not fid.strip():
            err(f"families entry #{i} missing valid 'id'")
        else:
            ids.append(fid)
    return ids

def compile_patterns(fam, bucket_name, errors, warnings):
    pats = fam.get("patterns")
    fid = fam.get("id", "?")
    if pats is None:
        warn(f"{bucket_name}:{fid} has no 'patterns' key")
        return 0
    if not is_strlist(pats):
        errors.append(f"{bucket_name}:{fid} 'patterns' must be a list of strings")
        return 0
    n = 0
    seen = set()
    for j, p in enumerate(pats):
        if p in seen:
            warnings.append(f"{bucket_name}:{fid} duplicate pattern[{j}]")
        else:
            seen.add(p)
        try:
            re.compile(p)
        except re.error as e:
            errors.append(f"{bucket_name}:{fid} pattern[{j}] regex error: {e} -> {p}")
            continue
        # helpful anchor hint for path regexes
        if "(^|/)" not in p or "(/|$)" not in p:
            warnings.append(f"{bucket_name}:{fid} pattern[{j}] not anchored with (^|/) … (/{'|$'}) -> {p}")
        n += 1
    return n

def main():
    ap = argparse.ArgumentParser(description="Validate policy.yaml consistency (structure, regex, refs).")
    ap.add_argument("--policy", required=True, help="path to policy.yaml")
    ap.add_argument("--json", action="store_true", help="emit a short JSON summary to stdout")
    args = ap.parse_args()

    policy, e = load_policy(args.policy)
    if e:
        err(e); sys.exit(2)

    errors, warnings = [], []

    # --- Top-level checks ---
    if not isinstance(policy, dict):
        err("Top-level YAML must be a mapping/object"); sys.exit(2)

    families = policy.get("families")
    passes   = policy.get("passes")

    if families is None or not isinstance(families, dict):
        errors.append("Missing 'families' (must be a mapping with 'exclude_soft' and/or 'keep')")
        families = {}

    excl = families.get("exclude_soft") or []
    keep = families.get("keep") or []

    if not isinstance(excl, list): errors.append("'families.exclude_soft' must be a list")
    if not isinstance(keep, list): errors.append("'families.keep' must be a list")

    # family id uniqueness
    excl_ids = collect_family_ids(excl)
    keep_ids = collect_family_ids(keep)
    if len(set(excl_ids)) != len(excl_ids):
        errors.append("Duplicate ids in families.exclude_soft")
    if len(set(keep_ids)) != len(keep_ids):
        errors.append("Duplicate ids in families.keep")

    # compile patterns & basic anchoring hints
    excl_pat_count = 0
    for fam in excl:
        excl_pat_count += compile_patterns(fam, "exclude_soft", errors, warnings)
    keep_pat_count = 0
    for fam in keep:
        keep_pat_count += compile_patterns(fam, "keep", errors, warnings)

    # passes
    if passes is None or not isinstance(passes, list) or not passes:
        warnings.append("No 'passes' declared (or not a list).")
        passes = []

    pass_ids = []
    for i, p in enumerate(passes):
        if not isinstance(p, dict):
            errors.append(f"passes[{i}] must be an object"); continue
        pid = p.get("id")
        if not isinstance(pid, str) or not pid.strip():
            errors.append(f"passes[{i}] missing valid 'id'")
        else:
            pass_ids.append(pid)

        # keep_families reference check
        kf = p.get("keep_families", [])
        if kf is not None:
            if not isinstance(kf, list) or not all(isinstance(x, str) for x in kf):
                errors.append(f"passes[{i}] keep_families must be a list of strings")
            else:
                for fam_id in kf:
                    if fam_id not in keep_ids:
                        errors.append(f"passes[{i}] keep_families references unknown keep id '{fam_id}'")

    summary = {
        "file": str(Path(args.policy).resolve()),
        "families": {
            "exclude_soft": {"count": len(excl_ids), "pattern_count": excl_pat_count},
            "keep":         {"count": len(keep_ids), "pattern_count": keep_pat_count},
        },
        "passes": {"count": len(pass_ids), "ids": pass_ids},
        "errors": len(errors),
        "warnings": len(warnings),
    }

    # print human summary
    info(f"Loaded: {summary['file']}")
    info(f"exclude_soft families: {summary['families']['exclude_soft']['count']} "
         f"(patterns: {summary['families']['exclude_soft']['pattern_count']})")
    info(f"keep families:         {summary['families']['keep']['count']} "
         f"(patterns: {summary['families']['keep']['pattern_count']})")
    info(f"passes:                {summary['passes']['count']} -> {', '.join(pass_ids) if pass_ids else '(none)'}")

    for w in warnings:
        warn(w)
    for x in errors:
        err(x)

    if args.json:
        print(json.dumps(summary, indent=2))

    sys.exit(1 if errors else 0)

if __name__ == "__main__":
    main()
