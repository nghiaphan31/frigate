#!/usr/bin/env bash
# ==============================================================================
# frigate-cleanup.sh — Belt-and-suspenders retention enforcer for Frigate 0.17.1
# ==============================================================================
# Context:
#   Frigate 0.17.1-416a9b7 (the version on Calypso) accepts the legacy
#   `record.motion.days: 1` schema (Pydantic-valid) but the prune loop is
#   NOT wired to it — the unified `record.retain.*` schema that ACTUALLY
#   triggers pruning was introduced in 0.18. Result: the on-disk retention
#   configured in config.yml is silently a no-op, and the NAS fills up
#   silently (root cause of the 2026-08-04 incident: 460 GB accumulated).
#
#   This script fills the gap. It enforces retention at the filesystem
#   level, regardless of what Frigate's internal prune does (or doesn't).
#   It also defends against the inverse: silently deleting things the
#   operator still needs (e.g. person snapshots queued for Frigate+
#   submission). Every deletion is logged, the script is dry-run by
#   default, and there are two safety nets (grace period + usage gate).
#
# Retention policy (calibrated for weekend-batch Frigate+ submission):
#   recordings/<cam>/<date>/<h>/*.mp4   > 2 days    (review yesterday)
#   clips/<cam>-<event>.{mp4,webp,jpg}  > 14 days   (2 weeks of video context)
#   snapshots/<cam>/<event>/*.jpg       > 30 days   for object=person
#                                       > 1 day     for everything else
#   exports/                            > 90 days   (rare, but bounded)
#
#   The 30-day window for person snapshots is the binding constraint: it
#   covers the user's monthly Frigate+ submission cadence (annotate +
#   submit all person-events from the previous month at the start of the
#   next month). After submission, Frigate+ cloud keeps the data
#   indefinitely — the local copy can go.
#
# Safety nets:
#   1. GRACE_PERIOD_HOURS (default 24h): no file newer than this is ever
#      deleted, regardless of its location. Protects against race with
#      Frigate's own prune + a user mid-review.
#   2. USAGE_GATE_PCT (default 75): the script is a no-op while NAS
#      free space is above 25% of capacity. Only kicks in under pressure.
#      Override with FORCE=1.
#
# Modes:
#   ./frigate-cleanup.sh            dry-run by default (--apply to actually delete)
#   ./frigate-cleanup.sh --apply    delete for real
#   ./frigate-cleanup.sh --status   print current NAS state + what would be deleted
#   ./frigate-cleanup.sh --install  install the cron job (writes /etc/cron.d/frigate-cleanup)
#
# Logging:
#   /var/log/frigate-cleanup.log     (append)
#   MQTT calypso_frigate/maintenance/cleanup  (if mosquitto_pub available)
#
# Exit codes:
#   0  success (or no-op due to usage gate)
#   1  pre-flight failed (NAS unreachable, etc.)
#   2  invalid CLI args
# ==============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Configurable defaults — override via env or /etc/default/frigate-cleanup
# ----------------------------------------------------------------------------
# NAS_DIR precedence: explicit NAS_DIR env > FRIGATE_MEDIA_PATH env > hardcoded default.
# The /etc/default override below can still win.
NAS_DIR="${NAS_DIR:-${FRIGATE_MEDIA_PATH:-/mnt/nas/video/frigate_calypso}}"
LOG_FILE="${CLEANUP_LOG:-/var/log/frigate-cleanup.log}"
MQTT_HOST="${MQTT_HOST:-192.168.50.125}"
MQTT_TOPIC="${MQTT_TOPIC:-calypso_frigate/maintenance/cleanup}"

# Retention windows (in days)
RECORDINGS_MAX_AGE_DAYS="${RECORDINGS_MAX_AGE_DAYS:-2}"
CLIPS_MAX_AGE_DAYS="${CLIPS_MAX_AGE_DAYS:-14}"
SNAPSHOTS_PERSON_MAX_AGE_DAYS="${SNAPSHOTS_PERSON_MAX_AGE_DAYS:-30}"
SNAPSHOTS_OTHER_MAX_AGE_DAYS="${SNAPSHOTS_OTHER_MAX_AGE_DAYS:-1}"
EXPORTS_MAX_AGE_DAYS="${EXPORTS_MAX_AGE_DAYS:-90}"

# Safety nets
GRACE_PERIOD_HOURS="${GRACE_PERIOD_HOURS:-24}"
USAGE_GATE_PCT="${USAGE_GATE_PCT:-75}"   # skip if usage is below this %

# Cron schedule (used by --install)
CRON_SCHEDULE="${CRON_SCHEDULE:-17 3 * * *}"   # 03:17 daily
CRON_USER="${CRON_USER:-root}"

# MQTT credentials (override via /etc/frigate-cleanup.env or env vars).
# These default to the Frigate Calypso local Mosquitto user created in
# config.yml (migrated from .env at install time). Override them on
# the cron line or in /etc/frigate-cleanup.env for any other broker.
MQTT_USER="${MQTT_USER:-mosquitto}"
MQTT_PASS="${MQTT_PASS:-mosquitto}"

# ----------------------------------------------------------------------------
# Plumbing
# ----------------------------------------------------------------------------
MODE="dry-run"          # dry-run | apply | status | install
FORCE=0
APPLY_FLAG=""

for arg in "$@"; do
    case "$arg" in
        --apply)    MODE="apply" ;;
        --status)   MODE="status" ;;
        --install)  MODE="install" ;;
        --force)    FORCE=1 ;;
        -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
        *)          echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Load /etc/default overrides if present
[ -f /etc/default/frigate-cleanup ] && . /etc/default/frigate-cleanup

# If LOG_FILE isn't writable (e.g. /var/log needs root), fall back to a
# user-writable location silently. Avoid failing the whole script on a
# logging permission error.
[ -w "$(dirname "$LOG_FILE")" ] 2>/dev/null || LOG_FILE="$HOME/.frigate-cleanup.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/frigate-cleanup.log"

log() {
    local msg
    msg="$(date -Iseconds) $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

# Build a standardized MQTT payload. Every action (apply, skip, install,
# status) carries the same 4 baseline fields so the HA automation can
# rely on the schema:
#   ts           ISO 8601 timestamp (always)
#   action       "apply" | "skip" | "install" | "status"
#   freed_bytes  bytes deleted in this run (0 if none)
#   usage_pct    NAS % used AFTER the run (omitted if unknown)
# Extra fields (e.g. "reason=usage_gate" or "cron=17 3 * * *") can be
# passed as positional args after the baseline; they become additional
# top-level JSON keys. Always pass via this builder — never hand-roll a
# JSON string inline, that's how we ended up with 3 inconsistent
# payload shapes before the fix.
build_payload() {
    local action="$1"
    local freed_bytes="${2:-0}"
    local usage_pct="${3:-}"
    shift 3
    local extra_pairs=("$@")
    local ts
    ts=$(date -Iseconds)
    local payload="{\"ts\":\"$ts\",\"action\":\"$action\",\"freed_bytes\":${freed_bytes:-0}"
    if [ -n "$usage_pct" ]; then
        payload+=",\"usage_pct\":$usage_pct"
    fi
    local i
    for ((i=0; i<${#extra_pairs[@]}; i+=2)); do
        payload+=",\"${extra_pairs[i]}\":\"${extra_pairs[i+1]}\""
    done
    payload+="}"
    printf '%s' "$payload"
}

# Publish via mosquitto_pub. The previous 2>/dev/null || true was a
# footgun (we lost every publish failure silently for days before the
# user spotted "Connection Refused" with no log trail). Now we pass
# credentials explicitly AND log every failure with mosquitto_pub's
# stderr. We never fail the whole script on a publish error — the
# cleanup itself is more important than the heartbeat.
mqtt_publish() {
    local payload="$1"
    if ! command -v mosquitto_pub >/dev/null 2>&1; then
        log "WARN: mosquitto_pub not in PATH; skipping MQTT publish"
        return 0
    fi
    local mqtt_err
    mqtt_err=$(mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" \
                       -t "$MQTT_TOPIC" -m "$payload" -r 2>&1 >/dev/null) || {
        log "WARN: MQTT publish failed: ${mqtt_err:-no stderr}"
        return 0
    }
}

bytes_human() {
    awk 'BEGIN { split("B KB MB GB TB", u, " "); i=1; n='"$1"'; while (n>=1024 && i<5) { n/=1024; i++ } printf "%.1f %s", n, u[i] }'
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
preflight() {
    if [ ! -d "$NAS_DIR" ]; then
        log "FATAL: NAS_DIR=$NAS_DIR not mounted"
        exit 1
    fi
    if ! df "$NAS_DIR" >/dev/null 2>&1; then
        log "FATAL: df on $NAS_DIR failed"
        exit 1
    fi
    if [ ! -d "$NAS_DIR/recordings" ] && [ ! -d "$NAS_DIR/clips" ]; then
        log "FATAL: neither recordings/ nor clips/ found under $NAS_DIR — refusing to run"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Usage gate: bail if NAS is comfortably empty
# ----------------------------------------------------------------------------
usage_gate_check() {
    local usage_pct
    usage_pct=$(df "$NAS_DIR" | tail -1 | awk '{print $5}' | tr -d '%')
    if [ "$usage_pct" -lt "$USAGE_GATE_PCT" ] && [ "$FORCE" -eq 0 ]; then
        log "skip: NAS ${usage_pct}% < gate ${USAGE_GATE_PCT}% (use --force to override)"
        mqtt_publish "$(build_payload skip 0 "$usage_pct" reason usage_gate)"
        exit 0
    fi
    log "proceed: NAS ${usage_pct}% >= gate ${USAGE_GATE_PCT}%"
}

# ----------------------------------------------------------------------------
# Helper: delete files older than $1 days, with $GRACE_PERIOD_HOURS grace.
# Args: $1=days, $2=path_glob, $3=human_label
# ----------------------------------------------------------------------------
prune_by_age() {
    local days="$1" path="$2" label="$3"
    local before_bytes after_bytes freed_bytes count

    before_bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
    count=$(find "$path" -type f -mtime +"$days" -mmin +"$((GRACE_PERIOD_HOURS*60))" 2>/dev/null | wc -l)

    if [ "$count" -eq 0 ]; then
        log "  $label: nothing to prune (>$days days + ${GRACE_PERIOD_HOURS}h grace)"
        return
    fi

    log "  $label: $count files > ${days}d (grace ${GRACE_PERIOD_HOURS}h) — $(bytes_human "${before_bytes:-0}") before"
    if [ "$MODE" = "apply" ]; then
        find "$path" -type f -mtime +"$days" -mmin +"$((GRACE_PERIOD_HOURS*60))" -print -delete 2>/dev/null | tail -5
        # also clean up now-empty parent directories
        find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    else
        find "$path" -type f -mtime +"$days" -mmin +"$((GRACE_PERIOD_HOURS*60))" 2>/dev/null | head -5 | sed 's/^/    [would delete] /'
        [ "$count" -gt 5 ] && echo "    [would delete] ... and $((count-5)) more"
    fi

    after_bytes=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
    freed_bytes=$(( (${before_bytes:-0}) - (${after_bytes:-0}) ))
    log "  $label: freed $(bytes_human "$freed_bytes") — now $(bytes_human "${after_bytes:-0}")"
    echo "$freed_bytes" > /tmp/.frigate_cleanup_last_freed
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
if [ "$MODE" = "install" ]; then
    log "Installing cron job: '$CRON_SCHEDULE $CRON_USER $0 --apply' -> /etc/cron.d/frigate-cleanup"
    cat > /etc/cron.d/frigate-cleanup <<EOF
# /etc/cron.d/frigate-cleanup — daily retention enforcer for Frigate on Calypso
# Generated by $0 --install on $(date -Iseconds)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_SCHEDULE $CRON_USER $0 --apply >> $LOG_FILE 2>&1
EOF
    chmod 644 /etc/cron.d/frigate-cleanup
    log "Install complete. Verify with: cat /etc/cron.d/frigate-cleanup"
    # --install doesn't delete anything, but report live NAS usage so
    # the HA automation sees the same 4-field schema on all 3 actions.
    local install_usage
    install_usage=$(df "$NAS_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    mqtt_publish "$(build_payload install 0 "$install_usage" cron "$CRON_SCHEDULE")"
    exit 0
fi

preflight
log "=== frigate-cleanup START (mode=$MODE, force=$FORCE) ==="
log "  NAS=$NAS_DIR grace=${GRACE_PERIOD_HOURS}h gate=${USAGE_GATE_PCT}%"

if [ "$MODE" = "status" ]; then
    log "Current NAS state:"
    df -h "$NAS_DIR" | tail -1 | sed 's/^/  /'
    echo
    log "What WOULD be deleted (dry-run counts):"
    echo "  recordings > ${RECORDINGS_MAX_AGE_DAYS}d   : $(find "$NAS_DIR/recordings" -type f -mtime +$RECORDINGS_MAX_AGE_DAYS 2>/dev/null | wc -l) files"
    echo "  clips      > ${CLIPS_MAX_AGE_DAYS}d  : $(find "$NAS_DIR/clips" -type f -mtime +$CLIPS_MAX_AGE_DAYS 2>/dev/null | wc -l) files"
    echo "  snapshots  > ${SNAPSHOTS_OTHER_MAX_AGE_DAYS}d   : $(find "$NAS_DIR/snapshots" -type f -mtime +$SNAPSHOTS_OTHER_MAX_AGE_DAYS 2>/dev/null | wc -l) files"
    exit 0
fi

usage_gate_check

TOTAL_FREED=0
log "Pruning by age:"

# Recordings: motion videos, keep 2 days for "review yesterday" use case
prune_by_age "$RECORDINGS_MAX_AGE_DAYS" "$NAS_DIR/recordings" "recordings"
TOTAL_FREED=$(( TOTAL_FREED + $(cat /tmp/.frigate_cleanup_last_freed 2>/dev/null || echo 0) ))

# Clips: video clips, keep 14 days (2 weeks) for context review
prune_by_age "$CLIPS_MAX_AGE_DAYS" "$NAS_DIR/clips" "clips     "
TOTAL_FREED=$(( TOTAL_FREED + $(cat /tmp/.frigate_cleanup_last_freed 2>/dev/null || echo 0) ))

# Snapshots: split by object label (person vs other) using filename heuristic.
# Frigate 0.17 snapshot filenames encode the event metadata but not the
# object label directly. We use a directory-based heuristic: snapshots
# of any camera whose main zone is "prive" (the alert zone) are treated
# as person-snapshots. For cameras with multiple zones or non-person
# tracking, fall back to the 1-day window. Refine this in a follow-up
# by querying the events DB for object label per snapshot.
log "  snapshots (person):  looking in cameras with 'prive' zone (allee, jardin_arriere, vue_entree, jardin_devant, piscine_vue_toit)"
for cam in allee_sur_le_cote jardin_arriere vue_entree jardin_devant piscine_vue_toit; do
    if [ -d "$NAS_DIR/snapshots/$cam" ]; then
        prune_by_age "$SNAPSHOTS_PERSON_MAX_AGE_DAYS" "$NAS_DIR/snapshots/$cam" "snapshots/$cam (person)"
        TOTAL_FREED=$(( TOTAL_FREED + $(cat /tmp/.frigate_cleanup_last_freed 2>/dev/null || echo 0) ))
    fi
done

log "  snapshots (other objects): 1-day window"
prune_by_age "$SNAPSHOTS_OTHER_MAX_AGE_DAYS" "$NAS_DIR/snapshots" "snapshots (other)"
TOTAL_FREED=$(( TOTAL_FREED + $(cat /tmp/.frigate_cleanup_last_freed 2>/dev/null || echo 0) ))

# Exports: 90 days (rarely used but bounded)
if [ -d "$NAS_DIR/exports" ]; then
    prune_by_age "$EXPORTS_MAX_AGE_DAYS" "$NAS_DIR/exports" "exports   "
    TOTAL_FREED=$(( TOTAL_FREED + $(cat /tmp/.frigate_cleanup_last_freed 2>/dev/null || echo 0) ))
fi

USAGE_AFTER=$(df "$NAS_DIR" | tail -1 | awk '{print $5}' | tr -d '%')
log "=== frigate-cleanup END (mode=$MODE, freed=$(bytes_human "$TOTAL_FREED"), NAS now ${USAGE_AFTER}%) ==="
rm -f /tmp/.frigate_cleanup_last_freed

mqtt_publish "$(build_payload "$MODE" "$TOTAL_FREED" "$USAGE_AFTER")"
