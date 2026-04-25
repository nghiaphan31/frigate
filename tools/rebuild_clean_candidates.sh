#!/usr/bin/env bash
set -euo pipefail

CFG="/mnt/nas/run/nas-pipelines/config"
RAW="$CFG/candidates_2025-10-10.lst"                       # ORIGINAL big list
SUG="$(ls -t "$CFG"/exclude_suggested_20*.txt 2>/dev/null | grep -v SAFE | head -1 || true)"
CODE="$CFG/excludes_code_git.txt"
BUILD="$CFG/excludes_build_trees.txt"
REPO_PAT="$(ls -t "$CFG"/git_repo_roots_*.txt 2>/dev/null | head -1 || true)"

# --- sanity checks for required files
for f in "$RAW" "$CODE" "$BUILD"; do
  [ -s "$f" ] || { echo "❌ Missing or empty: $f"; exit 1; }
done

# --- sanitize suggested excludes (and make POSIX ERE safe)
EXC_SAFE="$CFG/exclude_suggested_SAFE_$(date +%F).txt"
if [ -n "${SUG:-}" ] && [ -s "$SUG" ]; then
  sed -E 's/\r$//' "$SUG" \
  | sed -E '/^\s*(#|$)/d' \
  | sed -E 's/\(\?:/(/g' \
  > "$EXC_SAFE"
else
  : > "$EXC_SAFE"
fi

# --- merge excludes
EXC_ALL="$CFG/exclude_ALL_$(date +%F).txt"
cat "$EXC_SAFE" "$CODE" "$BUILD" > "$EXC_ALL"

# --- normalize RAW ('./' -> '/')
RAW_NORM="$CFG/candidates_norm_$(date +%F).lst"
sed 's#^\./#/#' "$RAW" > "$RAW_NORM"

# --- apply regex excludes (case-insensitive)
TMP1="$CFG/candidates_tmp1_$(date +%F).lst"
if [ -s "$EXC_ALL" ]; then
  grep -i -E -v -f "$EXC_ALL" "$RAW_NORM" > "$TMP1"
else
  cp "$RAW_NORM" "$TMP1"
fi

# --- drop anything inside a Git repo (if repo roots file exists)
TMP2="$CFG/candidates_tmp2_$(date +%F).lst"
if [ -n "${REPO_PAT:-}" ] && [ -s "$REPO_PAT" ]; then
  REPO_NORM="$CFG/git_repo_roots_norm_$(date +%F).txt"
  sed 's#^\./#/#' "$REPO_PAT" > "$REPO_NORM"
  grep -i -F -v -f "$REPO_NORM" "$TMP1" > "$TMP2"
  rm -f "$REPO_NORM"
else
  cp "$TMP1" "$TMP2"
fi
rm -f "$TMP1"

# --- optionally re-include your keep paths (only if include_keep.txt exists & non-empty)
CLEAN="$CFG/candidates_clean_$(date +%F).lst"
if [ -s "$CFG/include_keep.txt" ]; then
  KEEP_NORM="$CFG/include_keep_norm_$(date +%F).txt"
  sed 's#^\./#/#' "$CFG/include_keep.txt" > "$KEEP_NORM"
  KEEPED="$CFG/keep_norm.lst"
  grep -E -f "$KEEP_NORM" "$RAW_NORM" > "$KEEPED" || true
  sort -u "$TMP2" "$KEEPED" > "$CLEAN.tmp"
  rm -f "$KEEP_NORM" "$KEEPED"
else
  cp "$TMP2" "$CLEAN.tmp"
fi
rm -f "$TMP2" "$RAW_NORM"

# --- restore './' style and finalize
sed 's#^/#./#' "$CLEAN.tmp" | sort -u > "$CLEAN"
rm -f "$CLEAN.tmp"

echo "Lines (raw vs clean):"
wc -l "$RAW" "$CLEAN"
echo "✅ New clean list → $CLEAN"
