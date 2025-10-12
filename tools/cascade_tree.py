#!/usr/bin/env python3
import argparse, pathlib, datetime, collections, os, re

def split_parts(p: str):
    p = p.strip()
    if p.startswith('./'):
        p = p[2:]
    p = re.sub(r'/+', '/', p).strip('/')
    return [seg for seg in p.split('/') if seg]

def add_counts(prefix_counts, parts, max_depth):
    """Compter tous les ancêtres jusqu'au dossier parent (jamais le fichier).
       max_depth=0 => toute la profondeur jusqu'au parent ; sinon borne.
    """
    if not parts:
        return
    parent_depth = max(0, len(parts) - 1)  # exclude leaf (file)
    if parent_depth == 0:
        return
    depth_max = parent_depth if max_depth <= 0 else min(max_depth, parent_depth)
    for d in range(1, depth_max + 1):
        prefix = '/'.join(parts[:d])
        prefix_counts[(d, prefix)] += 1

def render_tree(prefix_counts):
    children = collections.defaultdict(list)
    for (d, p) in prefix_counts.keys():
        if d > 1:
            parent = (d - 1, '/'.join(p.split('/')[:-1]))
            children[parent].append((d, p))
        else:
            children[('ROOT', '')].append((d, p))
    for k in children:
        children[k].sort(key=lambda t: t[1])
    return children

def main():
    ap = argparse.ArgumentParser(description="Cascade des chemins en arbre par ancêtres (jusqu'au parent).")
    ap.add_argument('--list', required=True, help="Liste brute (ex: candidates_01-media_YYYY-MM-DD.lst)")
    ap.add_argument('--outdir', default='/mnt/nas/run/nas-pipelines/checks', help="Dossier de sortie")
    ap.add_argument('--max-depth', type=int, default=0, help="Profondeur max (0 = toute la profondeur jusqu'au parent)")
    ap.add_argument('--stat-size', action='store_true', help="Cumule les tailles (requiert --mount-root monté)")
    ap.add_argument('--mount-root', default='/mnt/nas', help="Racine de montage CIFS (ex: /mnt/nas)")
    args = ap.parse_args()

    ts = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
    outdir = pathlib.Path(args.outdir) / f"{ts}_tree_cascade"
    outdir.mkdir(parents=True, exist_ok=True)

    prefix_counts = collections.Counter()
    prefix_sizes  = collections.Counter()
    total = 0

    with open(args.list, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            total += 1
            parts = split_parts(line)
            if not parts:
                continue

            # 1) Compte des ancêtres (jamais le fichier)
            add_counts(prefix_counts, parts, args.max_depth)

            # 2) Optionnel: stat() du fichier puis remontée
            if args.stat_size:
                full = f"{args.mount_root.rstrip('/')}/" + '/'.join(parts)
                try:
                    st = os.stat(full)
                    prefix_sizes[(len(parts), '/'.join(parts))] += st.st_size
                except FileNotFoundError:
                    pass

    # Remontée des tailles aux ancêtres
    if args.stat_size and prefix_sizes:
        for (d, p), sz in sorted(prefix_sizes.items(), key=lambda x: -x[0][0]):
            if d > 1:
                parent = (d - 1, '/'.join(p.split('/')[:-1]))
                prefix_sizes[parent] += sz

    # Arbre (ancêtres uniquement)
    children = render_tree(prefix_counts)

    # 1) TSV annotable
    tsv = outdir / "tree.tsv"
    with open(tsv, 'w', encoding='utf-8') as T:
        T.write("mark\tdepth\tcount\tsize_bytes\tprefix\n")
        def walk(node):
            for d, p in children.get(node, []):
                count = prefix_counts[(d, p)]
                size  = prefix_sizes.get((d, p), 0)
                T.write(f"\t{d}\t{count}\t{size}\t{p}\n")
                walk((d, p))
        walk(('ROOT', ''))

    # 2) Vue Markdown
    md = outdir / "tree.md"
    with open(md, 'w', encoding='utf-8') as M:
        M.write(f"# Tree cascade — {ts}\n\n")
        M.write(f"- Input: `{args.list}`\n- Total lines: **{total}**\n")
        M.write(f"- Max depth: **{args.max_depth}** (0 = parent max)\n")
        M.write(f"- Sizes: {'ON' if args.stat_size else 'OFF'} (mount-root: {args.mount_root})\n\n")
        def walk_md(node, indent=0):
            for d, p in children.get(node, []):
                count = prefix_counts[(d, p)]
                size  = prefix_sizes.get((d, p), 0)
                human = f"{size/1024/1024:.1f} MB" if size else "-"
                M.write("  " * indent + f"- `{p}` — count: {count}, size: {human}\n")
                walk_md((d, p), indent + 1)
        walk_md(('ROOT', ''))

    # 3) Notice
    with open(outdir / "README.txt", 'w', encoding='utf-8') as R:
        R.write(
"ÉDITION:\n"
"- Ouvre tree.tsv et mets 'X' (exclude) ou 'K' (keep) dans la 1ère colonne.\n"
"- Inutile de marquer les descendants d’un préfixe déjà marqué 'X'.\n"
"CONVERSION:\n"
"- Utilise marks_to_policy.py pour générer le snippet YAML + dry-run.\n"
)

    print(f"✅ TSV annotable : {tsv}")
    print(f"✅ Vue Markdown  : {md}")
    print(f"ℹ️  Aide         : {outdir/'README.txt'}")

if __name__ == '__main__':
    main()
