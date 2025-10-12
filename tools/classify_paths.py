#!/usr/bin/env python3
import sys, re, argparse, pathlib, datetime, json, hashlib
import yaml

def load_yaml(p): return yaml.safe_load(open(p,'r',encoding='utf-8'))

def norm_path(s: str) -> str:
    s = s.rstrip('\n')
    if s.startswith('./'): s = s[1:]
    if not s.startswith('/'): s = '/' + s
    return re.sub(r'/+','/', s)

def ext_of(fname: str) -> str:
    b = fname.rsplit('/',1)[-1]
    if b.startswith('.') and b.count('.')==1: return ''
    parts = b.split('.')
    if len(parts) < 2: return ''
    e = parts[-1].lower(); p = (parts[-2].lower() if len(parts)>=2 else '')
    if e == 'tgz':  return 'tar.gz'
    if e == 'tbz2': return 'tar.bz2'
    if e == 'txz':  return 'tar.xz'
    if e in ('gz','bz2','xz','zst','lz','lzma') and p=='tar': return f'tar.{e}'
    return e

def compile_family(patterns): return [re.compile(p) for p in patterns]
def path_matches_any(path, regex_list): return any(r.search(path) for r in regex_list)

def load_keep_prefixes(cfg_dir: pathlib.Path):
    f = cfg_dir / "include_keep.txt"
    if f.exists():
        return [norm_path(x.strip().rstrip('/') + '/') for x in f.read_text(encoding='utf-8').splitlines()
                if x.strip() and not x.strip().startswith('#')]
    return []

def starts_with_any(path, prefixes): return any(path.startswith(pr) for pr in prefixes)

def pick_repo_roots(cfg_dir: pathlib.Path, explicit: str):
    if explicit:
        f = pathlib.Path(explicit)
        return f if f.exists() else None
    cands = sorted(cfg_dir.glob('git_repo_roots_*.txt'))
    return cands[-1] if cands else None

def load_repo_roots(repo_roots_file: pathlib.Path):
    if repo_roots_file and repo_roots_file.exists():
        return [norm_path(l.strip().rstrip('/') + '/') for l in repo_roots_file.read_text(encoding='utf-8').splitlines() if l.strip()]
    return []

def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode('utf-8')).hexdigest()

def main():
    ap = argparse.ArgumentParser(description="Policy-based path classifier (dry-list only).")
    ap.add_argument('--raw', required=True, help='RAW candidates_*.lst')
    ap.add_argument('--policy', required=True, help='policy.yaml')
    ap.add_argument('--pass-id', required=True, help='pass id from policy.passes (e.g., 02-docs)')
    ap.add_argument('--cfg-dir', default='/mnt/nas/run/nas-pipelines/config', help='dir with include_keep.txt and repo roots')
    ap.add_argument('--repo-roots', default='', help='optional git_repo_roots_*.txt (else latest in cfg-dir)')
    ap.add_argument('--runs-root', default='/mnt/nas/run/nas-pipelines/runs', help='root for run artifacts')
    ap.add_argument('--final-out-dir', default='/mnt/nas/run/nas-pipelines/config', help='where to write candidates_PASS_DATE.lst')
    args = ap.parse_args()

    cfg_dir = pathlib.Path(args.cfg_dir)
    runs_root = pathlib.Path(args.runs_root); runs_root.mkdir(parents=True, exist_ok=True)

    policy_path = pathlib.Path(args.policy)
    policy = load_yaml(policy_path)
    policy_text = policy_path.read_text(encoding='utf-8')
    policy_sha = sha256_text(policy_text)

    # categories → extensions
    cat_exts = {c: set([e.lower() for e in spec.get('exts',[])])
                for c, spec in policy.get('categories',{}).items()}

    # pick pass
    sel = next((p for p in policy.get('passes',[]) if p.get('id')==args.pass_id), None)
    if not sel:
        sys.exit(f"pass-id {args.pass_id} not found in policy")

    include_cats = set(sel.get('include_categories', []))
    include_families_scope = set(sel.get('include_families_scope', []))  # NEW: scope by families

    # families
    fam_hard = {f['id']: compile_family(f.get('patterns',[]))
                for f in policy['families'].get('exclude_hard', [])}
    fam_soft = {f['id']: compile_family(f.get('patterns',[]))
                for f in policy['families'].get('exclude_soft', [])}
    fam_keep = {f['id']: compile_family(f.get('patterns',[]))
                for f in policy['families'].get('keep', [])}

    # keep prefixes
    keep_prefixes = load_keep_prefixes(cfg_dir)

    # git repo roots (soft-exclude by prefix)
    repo_roots_file = pick_repo_roots(cfg_dir, args.repo_roots)
    repo_roots = load_repo_roots(repo_roots_file)

    # run folder (timestamp to the second)
    ts = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
    run_dir = runs_root / f"{ts}_pass-{args.pass_id}"
    run_dir.mkdir(parents=True, exist_ok=True)

    # persist inputs for audit
    (run_dir / "policy_used.yaml").write_text(policy_text, encoding='utf-8')
    (run_dir / "policy_used.sha256").write_text(policy_sha + "\n", encoding='utf-8')
    (run_dir / "include_keep_used.txt").write_text('\n'.join(keep_prefixes), encoding='utf-8')
    if repo_roots_file:
        (run_dir / "git_repo_roots_used.txt").write_text(repo_roots_file.read_text(encoding='utf-8'), encoding='utf-8')

    # outputs
    expl = (run_dir / f"explanations_{args.pass_id}.tsv").open('w', encoding='utf-8')
    out_tmp = (run_dir / "final_candidates.tmp").open('w', encoding='utf-8')

    # counters
    counts = {
        'total_lines': 0,
        'total_in': 0,
        'total_out_of_scope': 0,
        'total_drop_hard': 0,
        'total_drop_soft': 0,
        'in_scope_before_filters': 0
    }
    per_cat = {}
    per_ext = {}
    drop_families = {}  # id -> count

    # Helpers to check family membership
    def fam_hits(path, fam_map):
        return [fid for fid, regs in fam_map.items() if path_matches_any(path, regs)]

    # streaming classification
    raw_path = pathlib.Path(args.raw)
    with raw_path.open('r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line: continue
            counts['total_lines'] += 1

            p = norm_path(line)
            e = ext_of(p)
            # category detection
            cat = next((c for c, exts in cat_exts.items() if e in exts), None)

            # check scope-by-family first (if configured)
            scope_ok = True
            if include_families_scope:
                # at least one of the scope families must match
                scope_hits = set()
                for fam_id in include_families_scope:
                    regs = fam_hard.get(fam_id) or fam_soft.get(fam_id) or fam_keep.get(fam_id) or []
                    if path_matches_any(p, regs):
                        scope_hits.add(fam_id)
                scope_ok = len(scope_hits) > 0

            in_scope = scope_ok and (cat in include_cats)
            if in_scope:
                counts['in_scope_before_filters'] += 1
                per_cat[cat] = per_cat.get(cat, 0) + 1
                if e: per_ext[e] = per_ext.get(e, 0) + 1

            # families hits
            keep_hit = any(path_matches_any(p, regs) for regs in fam_keep.values()) or starts_with_any(p, keep_prefixes)
            hard_ids = fam_hits(p, fam_hard)
            soft_ids = fam_hits(p, fam_soft)
            if repo_roots and any(p.startswith(r) for r in repo_roots):
                soft_ids.append('GIT-ROOTS')

            # decision
            decision, reason = 'OUT_OF_SCOPE', '-'
            if in_scope:
                if hard_ids and not keep_hit:
                    decision = 'DROP_HARD'; reason = ','.join(hard_ids)
                    counts['total_drop_hard'] += 1
                    for fid in hard_ids: drop_families[fid] = drop_families.get(fid, 0) + 1
                elif soft_ids and not keep_hit:
                    decision = 'DROP_SOFT'; reason = ','.join(soft_ids)
                    counts['total_drop_soft'] += 1
                    for fid in soft_ids: drop_families[fid] = drop_families.get(fid, 0) + 1
                else:
                    decision = 'IN'
                    out_tmp.write(p.replace('/', './', 1) + '\n')
                    counts['total_in'] += 1
            else:
                counts['total_out_of_scope'] += 1

            # explanations row
            expl.write('\t'.join([
                p,                      # normalized path
                e or '-',               # extension
                cat or '-',             # detected category
                '1' if in_scope else '0',
                '1' if keep_hit else '0',
                ','.join(hard_ids) if hard_ids else '-',
                ','.join(soft_ids) if soft_ids else '-',
                decision,
                reason
            ]) + '\n')

    expl.close(); out_tmp.close()

    # finalize candidate list (dated by DAY, human-friendly)
    final_list = pathlib.Path(args.final_out_dir) / f"candidates_{args.pass_id}_{datetime.date.today().isoformat()}.lst"
    final_list.write_text(pathlib.Path(out_tmp.name).read_text(encoding='utf-8'), encoding='utf-8')

    # stats.json
    stats = {
        'timestamp': ts,
        'pass_id': args.pass_id,
        'raw_input': str(raw_path),
        'policy_file': str(policy_path),
        'policy_sha256': policy_sha,
        'repo_roots_file': str(repo_roots_file) if repo_roots_file else '',
        'include_keep_prefixes_count': len(keep_prefixes),
        'include_families_scope': list(include_families_scope),
        'counts': counts,
        'per_category_in_scope': dict(sorted(per_cat.items(), key=lambda x: x[0])),
        'per_extension_in_scope': dict(sorted(per_ext.items(), key=lambda x: (-x[1], x[0]))),
        'drop_families': dict(sorted(drop_families.items(), key=lambda x: -x[1])),
        'final_candidates_file': str(final_list)
    }
    (run_dir / "stats.json").write_text(json.dumps(stats, indent=2), encoding='utf-8')

    # report.md (human)
    rep = (run_dir / "report.md").open('w', encoding='utf-8')
    rep.write(f"# Pass report — {args.pass_id}\n\n")
    rep.write(f"- Timestamp: **{ts}**\n")
    rep.write(f"- RAW input: `{raw_path}`\n")
    rep.write(f"- Policy: `{policy_path}` (sha256: `{policy_sha}`)\n")
    if repo_roots_file:
        rep.write(f"- Git repo roots: `{repo_roots_file}`\n")
    rep.write(f"- Keep prefixes: {len(keep_prefixes)}\n")
    if include_families_scope:
        rep.write(f"- Scope limité aux familles: {', '.join(include_families_scope)}\n")
    rep.write("\n## Totaux\n")
    rep.write(f"- Total lignes RAW: **{counts['total_lines']}**\n")
    rep.write(f"- In-scope avant filtres: **{counts['in_scope_before_filters']}**\n")
    rep.write(f"- IN (candidats): **{counts['total_in']}**\n")
    rep.write(f"- DROP_SOFT: **{counts['total_drop_soft']}**\n")
    rep.write(f"- DROP_HARD: **{counts['total_drop_hard']}**\n")
    rep.write(f"- OUT_OF_SCOPE: **{counts['total_out_of_scope']}**\n\n")
    if per_cat:
        rep.write("## Répartition par catégorie (in-scope)\n")
        for c, n in sorted(per_cat.items(), key=lambda x: -x[1]):
            rep.write(f"- {c}: {n}\n")
        rep.write("\n")
    if per_ext:
        rep.write("## Top extensions (in-scope)\n")
        for e, n in list(sorted(per_ext.items(), key=lambda x: -x[1]))[:25]:
            rep.write(f"- {e}: {n}\n")
        rep.write("\n")
    if drop_families:
        rep.write("## Familles responsables des exclusions\n")
        for fid, n in sorted(drop_families.items(), key=lambda x: -x[1]):
            rep.write(f"- {fid}: {n}\n")
        rep.write("\n")
    rep.write(f"## Fichiers générés\n")
    rep.write(f"- Candidates: `{final_list}`\n")
    rep.write(f"- Explanations: `{expl.name}`\n")
    rep.write(f"- Stats (JSON): `{(run_dir / 'stats.json')}`\n")
    rep.write("\n")
    rep.close()

    print(f"✅ Candidates → {final_list}")
    print(f"📄 Explanations → {expl.name}")
    print(f"📊 Stats JSON → {(run_dir / 'stats.json')}")
    print(f"📝 Report → {(run_dir / 'report.md')}")
    print(f"🗂️ Run dir → {run_dir}")

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
