#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

usage() {
  echo "Usage: $0 --pass-id <id> --list </mnt/nas/run/nas-pipelines/config/candidates_...lst> [--mount-root /mnt/nas] [--no-hash] [--sample 200] [--per-ext-cap 25]"
  exit 1
}

PASS_ID="unknown"
LIST=""
MOUNT_ROOT="/mnt/nas"
DO_HASH=1
SAMPLE=200
PER_EXT_CAP=25

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pass-id) PASS_ID="$2"; shift 2;;
    --list) LIST="$2"; shift 2;;
    --mount-root) MOUNT_ROOT="$2"; shift 2;;
    --no-hash) DO_HASH=0; shift;;
    --sample) SAMPLE="$2"; shift 2;;
    --per-ext-cap) PER_EXT_CAP="$2"; shift 2;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[[ -f "$LIST" ]] || { echo "List not found: $LIST"; exit 2; }
[[ -d "$MOUNT_ROOT" ]] || { echo "Mount root not found: $MOUNT_ROOT"; exit 2; }

TS="$(date +%F_%H%M%S)"
OUT_ROOT="/mnt/nas/run/nas-pipelines/checks"
OUT_DIR="$OUT_ROOT/${TS}_pass-${PASS_ID}"
mkdir -p "$OUT_DIR"

RAW_NORM="$OUT_DIR/candidates_norm.lst"
# Normaliser: ./homes/... -> /mnt/nas/homes/...
sed -E 's#^\./#/#' "$LIST" | sed -E "s#^/#${MOUNT_ROOT}/#" > "$RAW_NORM"

# Filtrer fichiers existants et lisibles
EXISTING="$OUT_DIR/candidates_existing.lst"
MISSING="$OUT_DIR/candidates_missing.lst"
: > "$EXISTING"; : > "$MISSING"

while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if [[ -f "$p" ]]; then
    printf '%s\n' "$p" >> "$EXISTING"
  else
    printf '%s\n' "$p" >> "$MISSING"
  fi
done < "$RAW_NORM"

# Stats globales & par extension
STATS="$OUT_DIR/stats.tsv"
echo -e "metric\tvalue" > "$STATS"
TOTAL=$(wc -l < "$LIST" || echo 0)
EXISTS=$(wc -l < "$EXISTING" || echo 0)
MISS=$(wc -l < "$MISSING" || echo 0)
echo -e "total_listed\t$TOTAL" >> "$STATS"
echo -e "total_existing\t$EXISTS" >> "$STATS"
echo -e "total_missing\t$MISS" >> "$STATS"

# Somme des tailles
SIZE_BYTES=$(xargs -r stat -c '%s' < "$EXISTING" | awk '{s+=$1} END{print s+0}')
echo -e "total_size_bytes\t$SIZE_BYTES" >> "$STATS"

# Répartition par extension (minuscule)
EXT_TSV="$OUT_DIR/per_extension.tsv"
echo -e "ext\tcount\tsize_bytes" > "$EXT_TSV"
awk -F/ '
  {
    f=$NF; n=split(f,a,".");
    if (n>1) { e=tolower(a[n]); } else { e="(none)"; }
    print e "\t" $0;
  }' "$EXISTING" \
| awk -F'\t' '{ext[$1]++; path[$1]=path[$1] $2 "\n"} END{for (e in ext) print e "\t" ext[e] "\t" path[e] }' \
| while IFS=$'\t' read -r e cnt paths; do
    size=$(echo -n "$paths" | xargs -r stat -c '%s' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    echo -e "${e}\t${cnt}\t${size}"
  done \
| sort -k2,2nr >> "$EXT_TSV"

# Echantillonnage pour hashing (si activé)
if [[ "$DO_HASH" -eq 1 ]]; then
  SAMPLE_DIR="$OUT_DIR/pilot_sha256"
  mkdir -p "$SAMPLE_DIR"
  # Construire un pool échantillon: cap par extension
  POOL="$OUT_DIR/sample_pool.lst"
  : > "$POOL"
  tail -n +2 "$EXT_TSV" | cut -f1 | while read -r e; do
    # Extraire les chemins de l’extension e
    awk -v ext="$e" -F/ '
      {
        f=$NF; n=split(f,a,".");
        if (n>1) { ee=tolower(a[n]); } else { ee="(none)"; }
        if (ee==ext) print $0;
      }' "$EXISTING" | shuf -n "$PER_EXT_CAP" >> "$POOL"
  done
  # Limite globale SAMPLE
  shuf -n "$SAMPLE" "$POOL" > "$SAMPLE_DIR/paths.lst" || true

  # Hashing
  echo -e "sha256\tsize\tmtime\tpath" > "$SAMPLE_DIR/hashes.tsv"
  while IFS= read -r p; do
    [[ -f "$p" ]] || continue
    sz=$(stat -c '%s' "$p" 2>/dev/null || echo 0)
    mt=$(stat -c '%y' "$p" 2>/dev/null || echo "-")
    sh=$(sha256sum "$p" | awk '{print $1}')
    echo -e "${sh}\t${sz}\t${mt}\t${p}"
  done < "$SAMPLE_DIR/paths.lst"

  # Petit résumé hashing
  echo -e "pilot_hashed\t$(wc -l < "$SAMPLE_DIR/paths.lst" 2>/dev/null || echo 0)" >> "$STATS"
  cut -f1 "$SAMPLE_DIR/hashes.tsv" | tail -n +2 | sort | uniq -d > "$SAMPLE_DIR/dupe_hashes.lst" || true
fi

# Rapport Markdown lisible
REP="$OUT_DIR/report.md"
{
  echo "# Mini-check — pass ${PASS_ID}"
  echo
  echo "- Timestamp: **${TS}**"
  echo "- Input list: \`${LIST}\`"
  echo "- Mount root: \`${MOUNT_ROOT}\`"
  echo
  echo "## Totaux"
  echo "- total_listed: **${TOTAL}**"
  echo "- total_existing: **${EXISTS}**"
  echo "- total_missing: **${MISS}**"
  echo "- total_size_bytes: **${SIZE_BYTES}**"
  if [[ ${DO_HASH} -eq 1 ]]; then
    PH=$(awk -F'\t' '$1=="pilot_hashed"{print $2}' "$STATS")
    echo "- pilot_hashed: **${PH}**"
  fi
  echo
  echo "## Extensions (top 20)"
  echo
  head -n 21 "$EXT_TSV" | sed 's/^/    /'
  echo
  echo "## Fichiers générés"
  echo "- \`$STATS\`"
  echo "- \`$EXT_TSV\`"
  [[ ${DO_HASH} -eq 1 ]] && echo "- \`$SAMPLE_DIR/hashes.tsv\`"
  echo "- \`$EXISTING\`"
  echo "- \`$MISSING\`"
} > "$REP"

echo "✅ Mini-check done → $OUT_DIR"
echo "📝 Report: $REP"
