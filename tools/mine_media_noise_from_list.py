#!/usr/bin/env python3
import re, os, argparse, pathlib, datetime, collections, json

# --- Mots-clés "bruit" (regex, insensible à la casse) ---
KW = [
  r'android', r'\.android', r'\.eclipse', r'\.dia',
  r'\.thumb', r'thumbnail', r'thumbnails?',
  r'cache', r'caches', r'\btmp\b', r'\btemp\b',
  r'downloads?', r'instagram', r'facebook',
  r'gnuradio', r'gnuradio[-_ ]companion',
  r'export', r'exports', r'edited',
  r'preview', r'previews?',
  r'transcod(e|ed|ing)',
  r'whatsapp', r'telegram', r'snapchat',
  r'ffly4u', r'azureus', r'vuze', r'siemens'
]
KW_RE = re.compile('(?:' + '|'.join(KW) + ')', re.IGNORECASE)

MEDIA_EXT = set("""
jpg jpeg png gif webp heic heif tif tiff bmp psd ai svg
mp4 mov m4v mkv avi wmv webm mts m2ts ts mpg mpeg 3gp 3g2
dng cr2 nef arw rw2 orf raf srw pef ico
""".split())

def norm_line_to_share(line:str) -> str:
  p = line.strip()
  if p.startswith('./'): p = p[2:]
  p = re.sub(r'^/+', '', p)
  return p

def normalize_family(p:str) -> str:
  # lower + slashes
  p = p.lower()
  p = re.sub(r'/+','/', p)
  # homes/<user>/ → homes/[^/]+/
  p = re.sub(r'^homes/[^/]+/', 'homes/[^/]+/', p)
  # collapse ids/dates & noms IMG_1234
  p = re.sub(r'[0-9]{4,}', r'[0-9]+', p)
  p = re.sub(r'(img|vid|pano|mov|screenshot|screenrecord)[-_]?[0-9]+', r'\1_[0-9]+', p)
  # prendre une "famille" = 3 segments (share/dir1/dir2) quand possible
  segs = p.split('/')
  fam = '/'.join(segs[:3]) if len(segs) >= 3 else p
  return fam

def to_mount_path(share_path:str, mount_root:str) -> str:
  # share_path: 'photo/xyz/file.jpg'  →  '/mnt/nas/photo/xyz/file.jpg'
  return f"{mount_root.rstrip('/')}/{share_path}"

def ext_of(path:str) -> str:
  b = os.path.basename(path)
  if '.' not in b: return ''
  return b.rsplit('.',1)[1].lower()

def main():
  ap = argparse.ArgumentParser(description="Mine noisy media families from candidates list, score, and propose YAML snippet.")
  ap.add_argument('--list', required=True, help='candidates_01-media_YYYY-MM-DD.lst')
  ap.add_argument('--outdir', default='/mnt/nas/run/nas-pipelines/checks')
  ap.add_argument('--mount-root', default='/mnt/nas', help='If shares are mounted here, we will stat() sizes.')
  ap.add_argument('--topn', type=int, default=120)
  ap.add_argument('--tiny-kb', type=int, default=64, help='files <= this size (KB) count as tiny (thumbnails/previews).')
  args = ap.parse_args()

  ts = datetime.datetime.now().strftime('%Y-%m-%d_%H%M%S')
  outdir = pathlib.Path(args.outdir) / f"{ts}_mine-media-noise-adv"
  outdir.mkdir(parents=True, exist_ok=True)

  fam_counts = collections.Counter()
  fam_samples = collections.defaultdict(list)
  fam_tiny = collections.Counter()
  fam_total_sz = collections.Counter()
  fam_total_cnt = collections.Counter()
  kw_hits = collections.Counter()

  total = 0
  stat_enabled = os.path.isdir(args.mount_root)

  with open(args.list, 'r', encoding='utf-8', errors='ignore') as f:
    for line in f:
      line = line.strip()
      if not line: continue
      total += 1
      share_path = norm_line_to_share(line)     # 'photo/...' ou 'homes/...'
      # filtrer sur mots-clés bruit
      if not KW_RE.search(share_path):
        continue

      fam = normalize_family(share_path)
      fam_counts[fam] += 1
      if len(fam_samples[fam]) < 6:
        fam_samples[fam].append(line)

      # stats taille si monté et si média
      e = ext_of(share_path)
      fam_total_cnt[fam] += 1
      if stat_enabled and e in MEDIA_EXT:
        full = to_mount_path(share_path, args.mount_root)
        try:
          st = os.stat(full)
          fam_total_sz[fam] += st.st_size
          if st.st_size <= args.tiny_kb * 1024:
            fam_tiny[fam] += 1
        except FileNotFoundError:
          pass

      # kw hits (unicité par ligne)
      for m in set(m.group(0).lower() for m in KW_RE.finditer(share_path)):
        kw_hits[m] += 1

  # Scoring: base sur count + bonus si tiny_ratio élevé
  scored = []
  for fam, cnt in fam_counts.most_common():
    tiny = fam_tiny.get(fam, 0)
    tot = fam_total_cnt.get(fam, 0) or 1
    tiny_ratio = tiny / tot
    score = cnt * (1.0 + 0.5 * tiny_ratio)   # bonus max +50% si 100% tiny
    scored.append((score, fam, cnt, tiny, tot, fam_total_sz.get(fam,0)))

  scored.sort(reverse=True)

  # Rapport Markdown
  rep = outdir / "noise_report.md"
  with rep.open('w', encoding='utf-8') as R:
    R.write(f"# Media noise mining (advanced) — {ts}\n\n")
    R.write(f"- Input list: `{args.list}`\n")
    R.write(f"- Total lines scanned: **{total}**\n")
    R.write(f"- Families detected: **{len(fam_counts)}**\n")
    R.write(f"- Keywords: {', '.join(sorted(set(KW)))}\n")
    R.write(f"- Mount root: `{args.mount_root}` — stat sizes: {'ON' if stat_enabled else 'OFF'}\n")
    R.write(f"- tiny threshold: <= {args.tiny_kb} KB\n\n")
    R.write("## Top families (by score)\n\n")
    R.write("| family | count | tiny | tiny_ratio | total_size_mb |\n")
    R.write("|---|---:|---:|---:|---:|\n")
    for score,fam,cnt,tiny,tot,sz in scored[:args.topn]:
      tr = f"{(tiny/(tot or 1))*100:.1f}%"
      R.write(f"| `{fam}` | {cnt} | {tiny} | {tr} | {sz/1024/1024:.1f} |\n")
      for s in fam_samples[fam]:
        R.write(f"  - {s}\n")
      R.write("\n")

    R.write("## Keyword hits\n\n")
    for k, n in kw_hits.most_common():
      R.write(f"- {k}: {n}\n")

  # Génération de regex "famille"
  def fam_to_regex(fam:str) -> str:
    rx = re.escape(fam).replace('homes/\\[^/\\]\\+/', r'homes/[^/]+/')
    return f"(?i)(^|/){rx}(/|$)"

  # Suggestions YAML (families)
  yml = outdir / "exclude_media_noise_snippet.yaml"
  with yml.open('w', encoding='utf-8') as Y:
    Y.write("# Add under families.exclude_soft: MEDIA-NOISE.patterns\n")
    for _,fam,_,_,_,_ in scored[:args.topn]:
      Y.write(f"- '{fam_to_regex(fam)}'\n")

    # Règles ciblées supplémentaires (WhatsApp sent, Android caches)
    Y.write("# Handy targeted rules:\n")
    Y.write("- '(?i)(^|/)WhatsApp/Media/.*/Sent(/|$)'\n")
    Y.write("- '(?i)(^|/)Android/(data|media)/.*/(cache|caches|files/\\.thumbnails)(/|$)'\n")
    Y.write("- '(?i)(^|/)DCIM/\\.thumbnails(/|$)'\n")
    Y.write("- '(?i)(^|/)Pictures/\\.thumbnails(/|$)'\n")
    Y.write("- '(?i)(^|/)(Azureus|Vuze)(/|$)'\n")
    Y.write("- '(?i)(^|/)FFLY4U(/|$)'\n")
    Y.write("- '(?i)(^|/)Siemens/[^/]+/(Cache|Temp|Samples|Examples|Tutorials|Help)(/|$)'\n")
    Y.write("- '(?i)(^|/)[^/]*(thumb|thumbnail|preview|edited)[^/]*\\.(jpg|jpeg|png|gif|webp|heic|heif|tif|tiff|mp4|mov|m4v|mkv|avi|webm)$'\n")

  # Estimation "dry-run" (combien de lignes laissent tomber ces regex)
  import fnmatch
  sugg_patterns = []
  with yml.open('r', encoding='utf-8') as Y:
    for line in Y:
      line=line.strip()
      if not line.startswith("- '"): continue
      pat = line[3:].strip().strip("'").strip('"')
      try:
        sugg_patterns.append(re.compile(pat))
      except re.error:
        pass

  killed=0; total_lines=0
  with open(args.list,'r',encoding='utf-8',errors='ignore') as f:
    for raw in f:
      raw = raw.strip()
      if not raw: continue
      total_lines += 1
      sp = norm_line_to_share(raw).lower()
      if any(rx.search(sp) for rx in sugg_patterns):
        killed += 1
  with (outdir/"dry_run_summary.json").open('w', encoding='utf-8') as J:
    json.dump({"total": total_lines, "would_exclude": killed, "pct": round(100*killed/(total_lines or 1),2)}, J, indent=2)

  print(f"✅ Report: {rep}")
  print(f"✅ YAML snippet: {yml}")
  print(f"✅ Dry-run summary: {outdir/'dry_run_summary.json'}")

