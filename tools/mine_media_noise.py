#!/usr/bin/env python3
import re, sys, argparse, pathlib, datetime, collections, json

# Mots-clés "bruit" (regex, insensible à la casse)
KW = [
  r'android', r'\.android', r'\.eclipse', r'\.dia',
  r'\.thumb', r'thumbnail', r'thumbnails?',
  r'cache', r'caches', r'\btmp\b', r'\btemp\b',
  r'downloads?', r'instagram', r'facebook',
  r'gnuradio', r'gnuradio[-_ ]companion',
  r'export', r'exports', r'edited',
  r'preview', r'previews?',
  r'transcod(e|ed|ing)'
]
KW_RE = re.compile('(?:' + '|'.join(KW) + ')', re.IGNORECASE)

def normalize_prefix(p: str) -> str:
  p = p.strip()
  if p.startswith('./'): p = p[2:]
  p = p.lower()
  p = re.sub(r'/+','/', p)
  # généraliser homes/<user>/ → homes/[^/]+/
  p = re.sub(r'^homes/[^/]+/', 'homes/[^/]+/', p)
  # regrouper dates/ids longs et noms type IMG_1234
  p = re.sub(r'[0-9]{4,}', r'[0-9]+', p)
  p = re.sub(r'(img|vid|pano|mov|screenshot|screenrecord)[-_]?[0-9]+', r'\1_[0-9]+', p)
  # on retient un préfixe familial: share/dir1/dir2 si possible
  parts = p.split('/')
  fam = '/'.join(parts[:3]) if len(parts)>=3 else p
  return fam

def main():
  ap = argparse.ArgumentParser(description="Mine media-noise families from a candidates list (paths only).")
  ap.add_argument('--list', required=True, help='candidates_01-media_YYYY-MM-DD.lst')
  ap.add_argument('--outdir', default='/mnt/nas/run/nas-pipelines/checks')
  ap.add_argument('--topn', type=int, default=100)
  args = ap.parse_args()

  ts = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
  outdir = pathlib.Path(args.outdir) / f"{ts}_mine-media-noise"
  outdir.mkdir(parents=True, exist_ok=True)

  counts = collections.Counter()
  samples = collections.defaultdict(list)
  kw_hits = collections.Counter()
  total = 0

  with open(args.list,'r',encoding='utf-8',errors='ignore') as f:
    for line in f:
      line = line.strip()
      if not line: continue
      total += 1
      p = line[2:] if line.startswith('./') else line
      if not KW_RE.search(p):
        continue
      fam = normalize_prefix(p)
      counts[fam] += 1
      if len(samples[fam]) < 6:
        samples[fam].append(line)  # garde la ligne d'origine (./...)
      for m in KW_RE.finditer(p):
        kw_hits[m.group(0).lower()] += 1

  # Rapport Markdown
  rep = outdir / "noise_families_report.md"
  with rep.open('w', encoding='utf-8') as R:
    R.write(f"# Media noise mining — {ts}\n\n")
    R.write(f"- Input list: `{args.list}`\n")
    R.write(f"- Total lines scanned: **{total}**\n")
    R.write(f"- Families detected: **{len(counts)}**\n")
    R.write(f"- Keywords scanned: {', '.join(sorted(set(KW)))}\n\n")
    R.write("## Top families (by count)\n\n")
    for fam, n in counts.most_common(args.topn):
      R.write(f"### {fam} — {n}\n\n")
      for s in samples[fam]:
        R.write(f"- {s}\n")
      R.write("\n")
    R.write("## Keyword hits\n\n")
    for k, n in kw_hits.most_common():
      R.write(f"- {k}: {n}\n")

  # Suggestions regex (une par ligne)
  sug = outdir / "exclude_media_noise_suggested.txt"
  with sug.open('w', encoding='utf-8') as S:
    for fam,_ in counts.most_common(args.topn):
      rx = r'(^|/)' + re.escape(fam).replace('homes/\\[^/\\]\\+/', r'homes/[^/]+/') + r'(/|$)'
      S.write(rx + "\n")

  # Snippet YAML prêt à coller sous families.exclude_soft.MEDIA-NOISE.patterns
  yml = outdir / "exclude_media_noise_snippet.yaml"
  with yml.open('w', encoding='utf-8') as Y:
    Y.write("# Add under families.exclude_soft: MEDIA-NOISE.patterns\n")
    for fam,_ in counts.most_common(args.topn):
      rx = r'(^|/)' + re.escape(fam).replace('homes/\\[^/\\]\\+/', r'homes/[^/]+/') + r'(/|$)'
      Y.write(f"- '{rx}'\n")

  # JSON si besoin
  (outdir / "counts.json").write_text(json.dumps(counts.most_common(args.topn), indent=2), encoding='utf-8')

  print(f"✅ Report → {rep}")
  print(f"✅ Suggestions (regex) → {sug}")
  print(f"✅ YAML snippet → {yml}")
  print(f"🗂️ Outdir → {outdir}")

if __name__ == '__main__':
  main()
