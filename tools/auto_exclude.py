#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto_exclude.py — Suggest exclusion regexes from a giant candidates list.

USAGE (on your NUC):
  python3 ~/git/nuc-docker-stack/tools/auto_exclude.py \
    --input /mnt/nas/run/nas-pipelines/config/candidates_2025-10-10.lst \
    --outdir /mnt/nas/run/nas-pipelines/config \
    --topk 80 --sample-limit 3000000

Outputs in --outdir:
  - exclude_suggested_YYYY-MM-DD.txt   (regexes for grep -Evf)
  - exclude_report_YYYY-MM-DD.md       (human report: counts + samples)

Notes:
  * This script NEVER excludes “Photos” families by default.
  * A keep-list file (include_keep.txt) can be placed in --outdir; one path per line.
    Any suggestion colliding with a keep path is dropped.
  * The output file contains a curated base block + discovered families.
"""

from __future__ import annotations
import argparse
import collections
import datetime
import gzip
import io
import os
import pathlib
import re
import sys
from typing import Iterable, List, Tuple, Dict

# ------------------------
# Curated base patterns
# ------------------------
BASE_PATTERNS: List[str] = [
    # Synology / system noise
    r'/@eaDir/', r'/#recycle/', r'/@tmp/', r'/@S2S/', r'/@SynologyDrive/', r'/@SynologyDriveShareSync/',
    r'/@synobtrfsreplic/', r'/@SynoFinder-', r'/@synocalendar/', r'/@synoconfd/', r'/@synoscgi/',
    r'/PlexMediaServer/', r'/docker/', r'/run/nas-pipelines/', r'/truth/', r'/staging/',
    # Backups / images we never ingest
    r'/backups/', r'/NetBackup/', r'/HomeAssistantPiCM4Backup/', r'/MacBookPro11_5_TimeMachine/', r'/ActiveBackupforBusiness/',
    # Synology Drive noise under homes
    r'/homes/[^/]+/Drive/\.SynologyDrive/', r'/homes/[^/]+/Drive/@eaDir/', r'/homes/[^/]+/Drive/#recycle/',
    r'/homes/[^/]+/Drive/Storage (?:Analyser|Analyzer) Logs/',
    # OS detritus (files)
    r'/\.DS_Store$', r'/desktop\.ini$', r'/Thumbs\.db$', r'/ehthumbs\.db$',
    # OS detritus (dirs)
    r'/\.Spotlight-V100/', r'/\.Trashes/', r'/\.fseventsd/', r'/\.AppleDouble/',
    # Generic caches / temps
    r'/cache/', r'/\.cache/', r'/tmp/', r'/temp/', r'/TemporaryItems/', r'/\.tmp/', r'/\.temp/',
]

# ------------------------
# Heuristic “noise tokens”
# (intentionally NO 'photos' here)
# ------------------------
NOISE_TOKENS: List[str] = [
    'log', 'logs', 'synoreport', 'analy', 'analyser', 'analyzer',
    'cache', 'tmp', 'temp', 'thumbnail', 'thumbs', 'thumb', 'indexdb',
    'synologydrive', 'photostation', 'plex', 'spotlight', 'trashes',
    'eaDir', '#recycle',
]

# ------------------------
# Helpers
# ------------------------
def read_lines(path: pathlib.Path) -> Iterable[str]:
    opener = gzip.open if str(path).endswith('.gz') else open
    with opener(path, 'rt', errors='ignore') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line:
                continue
            yield line

def normalize_path(p: str) -> str:
    """Normalize candidate path for pattern generation."""
    # remove leading './'
    p = re.sub(r'^\./', '/', p)
    # collapse duplicate slashes
    p = re.sub(r'/+', '/', p)
    return p

def generalize_path_for_regex(p: str) -> str:
    """Generalize user-specific segments etc. BEFORE escaping to regex."""
    p = normalize_path(p)
    # homes/<user>/ → homes/[^/]+/
    p = re.sub(r'/homes/[^/]+/', r'/homes/[^/]+/', p)
    return p

def fix_escaped_wildcards(pat: str) -> str:
    """
    After re.escape(), restore our intended [^/]+ wildcard where it might have been escaped.
    Handles both "\[\^/\]\+" and "\[\^\/\]\+" variants.
    """
    pat = re.sub(r'\\\[\^/\\\]\\\+', r'[^/]+', pat)   # -> \[\^/\]\+  → [^/]+
    pat = re.sub(r'\\\[\^\\/\\\]\\\+', r'[^/]+', pat) # -> \[\^\/\]\+ → [^/]+
    return pat

def path_contains_segment(p: str, segment: str) -> bool:
    return re.search(rf'/{re.escape(segment)}/', p, flags=re.IGNORECASE) is not None

# ------------------------
# Core discovery
# ------------------------
def discover_patterns(lines: Iterable[str], sample_limit: int, topk: int,
                      keep_paths: List[str], skip_photos: bool = True
                      ) -> Tuple[Dict[str, int], List[Tuple[int, str, List[str]]]]:
    token_hits: Dict[str, int] = collections.Counter()
    fam_counts: Dict[str, int] = collections.Counter()
    fam_samples: Dict[str, List[str]] = collections.defaultdict(list)

    token_re = re.compile('|'.join([re.escape(t) for t in NOISE_TOKENS]), re.IGNORECASE)

    seen = 0
    for ln in lines:
        seen += 1
        if sample_limit and seen > sample_limit:
            break

        nln = normalize_path(ln)
        if not token_re.search(nln):
            continue

        # Build a family window around the matching token segment
        seg = nln.lstrip('/').split('/')
        # locate the index of the segment that matched any noise token
        idx = None
        for i, s in enumerate(seg):
            if token_re.search(s):
                idx = i
                break
        if idx is None:
            idx = min(2, len(seg) - 1)
        start = max(0, idx - 2)
        end   = min(len(seg), idx + 3)

        fam = '/' + '/'.join(seg[start:end])
        if not fam.endswith('/'):
            fam += '/'

        # Never propose families that live under /Photos/ (unless explicitly allowed)
        if skip_photos and path_contains_segment(fam, 'Photos'):
            continue

        fam_gen = generalize_path_for_regex(fam)
        token_hits[seg[idx].lower()] += 1
        fam_counts[fam_gen] += 1
        if len(fam_samples[fam_gen]) < 3:
            fam_samples[fam_gen].append(nln)

    # Turn frequent families into regex patterns
    suggestions: List[Tuple[int, str, List[str]]] = []
    for fam, cnt in sorted(fam_counts.items(), key=lambda x: x[1], reverse=True)[:topk]:
        # If any keep-path appears inside this family, skip it
        if any(k for k in keep_paths if k and k.strip() and k.strip('/') in fam):
            continue

        # Prepare a regex: escape then restore our intended classes
        pat = re.escape(fam)
        # Allow both Analyzer/Analyser variants
        pat = pat.replace('Storage\\ Analyzer\\ Logs', r'Storage (?:Analyser|Analyzer) Logs')
        pat = fix_escaped_wildcards(pat)
        # Make it recursively match inside that family
        if not pat.endswith('/'):
            pat += '/'
        pat += r'.*'

        suggestions.append((cnt, pat, fam_samples[fam]))

    return token_hits, suggestions

# ------------------------
# Main
# ------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description="Suggest exclusion regexes from a candidates list.")
    ap.add_argument('--input', required=True, help='Path to candidates_*.lst (or .gz)')
    ap.add_argument('--outdir', required=True, help='Output directory for suggestions and report')
    ap.add_argument('--topk', type=int, default=60, help='Number of discovered families to include')
    ap.add_argument('--sample-limit', type=int, default=3_000_000,
                    help='Max number of lines to sample from input (0 = no limit)')
    ap.add_argument('--allow-photos', action='store_true',
                    help='If set, do NOT auto-skip families under /Photos/')
    args = ap.parse_args()

    inpath = pathlib.Path(args.input)
    outdir = pathlib.Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    # Load keep list (optional)
    keep_file = outdir / "include_keep.txt"
    keep_paths: List[str] = []
    if keep_file.exists():
        with open(keep_file, 'r', errors='ignore') as f:
            for ln in f:
                s = ln.strip()
                if not s or s.startswith('#'):
                    continue
                keep_paths.append(normalize_path(s))

    # Stream lines; do not load everything in memory
    lines = read_lines(inpath)

    token_hits, suggestions = discover_patterns(
        lines=lines,
        sample_limit=args.sample_limit,
        topk=args.topk,
        keep_paths=keep_paths,
        skip_photos=(not args.allow_photos)
    )

    today = datetime.date.today().isoformat()
    excl_path = outdir / f"exclude_suggested_{today}.txt"
    rep_path  = outdir / f"exclude_report_{today}.md"

    # Write suggestions file (curated base + discovered)
    with open(excl_path, 'w', encoding='utf-8') as g:
        g.write("# ==== SUGGESTED EXCLUDE PATTERNS (regex) ====\n")
        g.write("# Curated base (Synology/OS/apps/caches)\n")
        for p in BASE_PATTERNS:
            g.write(p + "\n")
        g.write("\n# Discovered families (topK)\n")
        for cnt, pat, _samples in suggestions:
            g.write(pat + "\n")

    # Write human-readable report
    with open(rep_path, 'w', encoding='utf-8') as r:
        r.write(f"# Auto-Exclude Report ({today})\n\n")
        if keep_paths:
            r.write("## Keep-list (never exclude)\n\n")
            for k in keep_paths:
                r.write(f"- `{k}`\n")
            r.write("\n")
        r.write("## Token hits (noise keywords)\n\n")
        for t, c in collections.Counter(token_hits).most_common(40):
            r.write(f"- `{t}`: {c}\n")
        r.write("\n## Suggested families (count → regex → samples)\n\n")
        for cnt, pat, samples in suggestions:
            r.write(f"- **{cnt} hits** — `{pat}`\n")
            for s in samples:
                r.write(f"  - {s}\n")
            r.write("\n")

    print(f"✅ Wrote suggestions: {excl_path}")
    print(f"✅ Wrote report     : {rep_path}")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        sys.exit(130)
