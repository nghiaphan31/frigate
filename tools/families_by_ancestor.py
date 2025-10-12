#!/usr/bin/env python3
import argparse, pathlib, datetime, collections, os, sys, re

def split_parts(p: str):
    p = p.strip()
    if p.startswith('./'): p = p[2:]
    p = re.sub(r'/+', '/', p)
    p = p.strip('/')
    return [seg for seg in p.split('/') if seg]

def family_from_file_end(parts, levels):
    """N niveaux AU-DESSUS du fichier (depuis la fin).
       N=1 => dossier parent immédiat, N=2 => parent du parent, etc.
    """
    if not parts: return ''
    # si la ligne finit par /, on considère le dernier segment comme 'dossier' (pas fichier)
    # dans tous les cas, on retire 1 segment (le fichier/dossier final), puis (levels-1) de plus
    drop = min(levels, max(1, len(parts)) - 0)  # au moins 1 segment à retirer (le dernier)
    # En pratique, on veut retirer 1 (fichier) + (levels-1) parents = levels au total
    drop = min(levels, len(parts)-1) if len(parts) >= 2 else 1
    keep = parts[:max(0, len(parts) - drop)]
    return '/'.join(keep)

def family_from_root(parts, levels):
    """N premiers segments depuis la racine (ex: share/dir1/dir2)."""
    return '/'.join(parts[:levels])

def main():
    ap = argparse.ArgumentParser(description="Regroupe les chemins par 'familles' de N niveaux.")
    ap.add_argument('--list', required=True, help='Fichier liste de chemins (ex: candidates_01-media_YYYY-MM-DD.lst)')
    ap.add_argument('--levels', type=int, required=True, help='N niveaux (entier > 0)')
    ap.add_argument('--mode', choices=['file', 'root'], default='file',
                    help="file = N niveaux au-dessus du fichier ; root = N premiers segments depuis la racine")
    ap.add_argument('--outdir', default='/mnt/nas/run/nas-pipelines/checks', help='Répertoire de sortie')
    ap.add_argument('--samples', type=int, default=5, help="Nb d'exemples par famille")
    args = ap.parse_args()

    if args.levels <= 0:
        print("levels doit être > 0", file=sys.stderr); sys.exit(2)

    ts = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
    outdir = pathlib.Path(args.outdir) / f"{ts}_families_{args.mode}_L{args.levels}"
    outdir.mkdir(parents=True, exist_ok=True)

    counts = collections.Counter()
    samples = collections.defaultdict(list)

    total = 0
    with open(args.list, 'r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line: continue
            total += 1
            parts = split_parts(line)
            if not parts:
                fam = ''
            else:
                if args.mode == 'file':
                    fam = family_from_file_end(parts, args.levels)
                else:
                    fam = family_from_root(parts, args.levels)
            if fam == '': fam = '(root)'
            counts[fam] += 1
            if len(samples[fam]) < args.samples:
                samples[fam].append(line)

    # Fichiers de sortie
    top_txt = outdir / "families.txt"          # "count  family"
    top_tsv = outdir / "families.tsv"          # "family \t count"
    samp_md  = outdir / "samples.md"           # exemples par famille
    meta_txt = outdir / "meta.txt"

    with open(top_txt, 'w', encoding='utf-8') as T:
        for fam, n in counts.most_common():
            T.write(f"{n}\t{fam}\n")

    with open(top_tsv, 'w', encoding='utf-8') as T:
        T.write("family\tcount\n")
        for fam, n in counts.most_common():
            T.write(f"{fam}\t{n}\n")

    with open(samp_md, 'w', encoding='utf-8') as S:
        S.write(f"# Samples par famille — {ts}\n\n")
        S.write(f"- Liste: `{args.list}`\n- Total lignes: **{total}**\n")
        S.write(f"- Mode: **{args.mode}**, Levels: **{args.levels}**\n\n")
        for fam, _ in counts.most_common():
            S.write(f"## {fam}\n\n")
            for ex in samples[fam]:
                S.write(f"- {ex}\n")
            S.write("\n")

    with open(meta_txt, 'w', encoding='utf-8') as M:
        M.write(f"input={args.list}\nmode={args.mode}\nlevels={args.levels}\n"
                f"total_lines={total}\noutput_dir={outdir}\n")

    print(f"✅ Familles (triées): {top_txt}")
    print(f"✅ TSV:               {top_tsv}")
    print(f"✅ Exemples:          {samp_md}")
    print(f"ℹ️  Meta:             {meta_txt}")

if __name__ == '__main__':
    main()
