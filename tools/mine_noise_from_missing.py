#!/usr/bin/env python3
import re, sys, argparse, pathlib, datetime, collections, json

# Mots-clés initiaux (incluant ceux que tu as cités)
KW = [
  r'\.thumb', r'thumbnails?', r'\.thumbnails', r'cache', r'caches', r'\btmp\b', r'temp',
  r'android', r'dcim', r'screenshots?', r'screenrecorder', r'downloads?',
  r'whatsapp', r'telegram', r'instagram', r'facebook', r'tiktok', r'snapchat',
  r'lightroom', r'previews?', r'exports?', r'edited', r'transcod(e|ed|ing)?',
  r'\.eclipse', r'\.idea', r'\.vscode', r'__pycache__', r'\.gradle', r'\.m2',
  r'\.dia', r'gnuradio', r'gnuradio[-_ ]?companion', r'\.android',
]
kw_re = re.compile('|'.join(KW), re.I)

def strip_mount(p, mount_root):
  p = p.strip()
  if mount_root and p.startswith(mount_root.rstrip('/')+'/'):
    p = p[len(mount_root.rstrip('/'))+1:]
  if p.startswith('./'): p = p[2:]
  return p

def normalize_family(p):
  p = p.lower()
  p = re.sub(r'/+','/', p)
  # homes/<user>/ → homes/[^/]+/
  p = re.sub(r'^homes/[^/]+/', 'homes/[^/]+/', p)
  # collapse chiffres longs et séquences IMG_1234 etc.
  p = re.sub(r'[0-9]{4,}', r'[0-9]+', p)
  p = re.sub(r'(img|vid|pano|mov|screenshot|screenrecord)[-_]?[0-9]+', r'\1_[0-9]+', p)
  # on prend un préfixe familial: share/dir1/dir2 si possible
  parts = p.split('/')
  fam = '/'.join(parts[:3]) if len(parts)>=3 else p
  return fam

def main():
  ap = argparse.ArgumentParser()
  ap.add_argument('--input', required=True, help='.../candidates_missing.lst')
  ap.add_argument('--mount-root', default='/mnt/nas')
  ap.add_argument('--topn', type=int, default=80)
  args = ap.parse_args()

  ts = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
  outdir = pathlib.Path('/mnt/nas/run/nas-pipelines/checks') / f"{ts}_noise-from-missing-01-media"
  outdir.mkdir(parents=True, exist_ok=True)

  counts = collections.Counter()
  samples = collections.defaultdict(list)
  kw_hits = collections.Counter()

  total = 0
  with open(args.input,'r',encoding='utf-8',errors='ignore') as f:
    for line in f:
      total += 1
      raw = strip_mount(line.strip(), args.mount_root)
      low = raw.lower()
      if not kw_re.search(low): 
        continue
      fam = normalize_family(low)
      counts[fam] += 1
      if len(samples[fam]) < 6:
        samples[fam].append(raw)
      for m in kw_re.finditer(low):
        kw_hits[m.group(0).lower()] += 1

  # Rapport markdown
  rep = outdir / "noise_report.md"
  with rep.open('w', encoding='utf-8') as R:
    R.write(f"# Noise mining from candidates_missing — {ts}\n\n")
    R.write(f"- Input: `{args.input}`\n- Mount root stripped: `{args.mount_root}`\n")
    R.write(f"- Total lines scanned: **{total}**\n- Families detected: **{len(counts)}**\n\n")
    R.write("## Top families (by count)\n\n")
    for fam, n in counts.most_common(args.topn):
      R.write(f"### {fam} — {n}\n\n")
      for s in samples[fam]:
        R.write(f"- {s}\n")
      R.write("\n")
    R.write("## Keyword hits\n\n")
    for k, n in kw_hits.most_common():
      R.write(f"- {k}: {n}\n")

  # Suggestions regex (sans slash wrapper, prêtes pour YAML)
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

  # JSON brut si besoin
  (outdir / "counts.json").write_text(json.dumps(counts.most_common(args.topn), indent=2), encoding='utf-8')

  print(f"✅ Report: {rep}")
  print(f"✅ Suggestions (regex): {sug}")
  print(f"✅ YAML snippet: {yml}")
  print(f"🗂️ Outdir: {outdir}")

if __name__ == '__main__':
  main()
