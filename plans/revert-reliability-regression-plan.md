# Frigate Deploy Reliability — Regression Revert Plan
**Date**: 2026-05-30  
**Author**: Zoo (Architect)  
**Target**: [`deploy-frigate.sh`](../deploy-frigate.sh)  
**Triggered by**: Regression from [`plans/deploy-reliability-fix-plan.md`](deploy-reliability-fix-plan.md) implementation

---

## Problem Summary

Since the reliability-fix plan was implemented, Frigate **cannot be deployed at all** — every
`./deploy-frigate.sh` attempt takes 15–20 minutes and cameras still show "no frames received."

---

## Root Cause Analysis

Three plan changes interact to create the regression:

### Immediate cause — REL-6 + REL-9: 3 retries × 4 min = 12 min overhead per deploy

Each `while ! all_processing` retry iteration costs approximately:
```
zmq_fix_cycle:           ~50s  (docker stop -t30 + sleep 20 + dc start)
wait_healthy:            ~60s  (typically; up to 120s)
wait_detector_ready:      ~5s  (TRT cache hit)
wait_all_processing:    ~120s  (if stuck, always times out)
                        -----
per retry:              ~235s ≈ 4 min
```

With `MAX_ZMQ_RETRIES=3`, worst case = **12 min just for retries**, plus ~5 min baseline = **~17 min total**.

### Deeper cause — REL-8: new `all_processing()` is dramatically stricter than the old one

Old majority check: `process_fps > 0` on **>50% of cameras** (6 of 11) → "done".  
New stuck-camera check: **even 1 camera** with `camera_fps > 0 AND process_fps = 0` → retry.

Combined with the startup gate (waits for majority to reconnect via RTSP before evaluating),
the new logic means a single marginal camera that reconnects 1 second before the poll triggers
an entire extra retry cycle. With 11 cameras and ZMQ timing variability, this fires on nearly
every deploy.

### Root trigger — BUG-1 fix changed which command runs

Before BUG-1 was fixed, `auto` mode crashed on `${DB_MTIME}` before reaching `cmd_recreate`.
After the fix, `cmd_recreate` is correctly called on every config.yml-changed deploy. But
`cmd_recreate` now runs the 3-retry while loop — turning every deploy into a 17-minute ordeal.

---

## Decision: Surgical Revert

Keep the four verified bug fixes (BUG-1 through BUG-4) and the minor timing improvement (REL-5).
Revert the reliability changes (REL-6, REL-8, REL-9) that caused the regression.

`REBOOT-7` (`TimeoutStartSec=1800`) is also kept — the original 600s was already insufficient
for the pre-plan cmd_boot worst case (120+300+25+120+120+120 = 805s > 600s).

---

## What to Keep

| Fix | File | Why |
|-----|------|-----|
| BUG-1: `${DB_MTIME}` → `${CONTAINER_CREATED}` | `deploy-frigate.sh` | Critical unbound-variable crash under `set -eu` |
| BUG-2: `wait_detector_ready 120 \|\| true` in recreate retry | `deploy-frigate.sh` | Prevents `set -e` exit on timeout |
| BUG-3: `wait_detector_ready 300 \|\| true` in cmd_boot | `deploy-frigate.sh` | Same as BUG-2 |
| BUG-4: dynamic `cid` lookup in `check_shm` | `deploy-frigate.sh` | Docker Compose V2 compatibility |
| REL-5: `sleep 15` → `sleep 20` in `zmq_fix_cycle` | `deploy-frigate.sh` | Port-release safety margin (low risk) |
| REBOOT-7: `TimeoutStartSec=1800` | `frigate.service` | 600s was already insufficient for cold-boot timing |

---

## What to Revert

### REVERT-1 — Remove `MAX_ZMQ_RETRIES=3` constant

**Location**: [`deploy-frigate.sh:33`](../deploy-frigate.sh:33)

```bash
# REMOVE these lines:
# Maximum number of extra ZMQ-fix stop+start retries after the initial cycle.
# 3 retries (4 total cycles) gives P(any camera still ZMQ-stuck) < 0.55% at 15% per-cycle
# failure probability. See plans/deploy-reliability-fix-plan.md § REL-9 for the math.
MAX_ZMQ_RETRIES=3
```

---

### REVERT-2 — Restore `all_processing()` to simple majority check

**Location**: [`deploy-frigate.sh:182`](../deploy-frigate.sh:182)

Replace the current stuck-camera / startup-gate implementation with the original majority check:

```bash
# Returns 0 (success) if >50% of detection-enabled cameras have process_fps > 0.
# Returns 1 (failure) if majority do not — caller should retry a ZMQ cycle.
#
# WHY majority (not all): ZMQ IPC startup is a race. Requiring ALL cameras to
# have process_fps > 0 immediately after a stop+start would trigger spurious
# retries while cameras reconnect their RTSP streams (10-30s after dc start).
# The majority threshold gives enough signal that ZMQ is healthy while tolerating
# the last few cameras still reconnecting.
all_processing() {
    curl -sf "${FRIGATE_API}/api/stats" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    s = json.load(sys.stdin)
    cams = s.get('cameras', {})
    if not cams:
        print(0)
        sys.exit()
    enabled = {c: v for c, v in cams.items() if v.get('detection_enabled', True)}
    if not enabled:
        print(1)  # no detection-enabled cameras — nothing to wait for
        sys.exit()
    processing = sum(1 for v in enabled.values() if (v.get('process_fps') or 0) > 0)
    total = len(enabled)
    print(1 if processing > total / 2 else 0)
except Exception:
    print(0)
" 2>/dev/null | grep -q '^1$'
}
```

Also update `wait_all_processing()` messages to match the restored majority semantics:

```bash
wait_all_processing() {
    local max_wait="${1:-120}"
    local interval=5
    local elapsed=0
    log "Waiting for majority of cameras to start processing (timeout=${max_wait}s)..."
    while true; do
        if all_processing; then
            ok "Majority of cameras processing (process_fps > 0)"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        if [[ $elapsed -ge $max_wait ]]; then
            warn "Cameras not yet processing after ${max_wait}s — ZMQ IPC may need another cycle"
            return 1  # caller MUST use || true — set -e is active
        fi
        log "  ...waiting: majority of cameras don't have process_fps>0 yet (${elapsed}s elapsed)"
    done
}
```

---

### REVERT-3 — Replace while-loop retries with single `if` retry in all three commands

Replace the `while ! all_processing && [[ $zmq_retry -lt $MAX_ZMQ_RETRIES ]]; do` block
in **cmd_boot**, **cmd_restart**, and **cmd_recreate** with the original single-retry pattern:

```bash
# One ZMQ retry if majority of cameras are not yet processing
if ! all_processing; then
    warn "process_fps=0 on majority of cameras — doing one more ZMQ reset..."
    zmq_fix_cycle
    wait_healthy
    wait_detector_ready 120 || true
    wait_all_processing 120 || true
fi
```

---

## Files to Modify

| File | Changes |
|------|---------|
| [`deploy-frigate.sh`](../deploy-frigate.sh) | REVERT-1 (remove constant) + REVERT-2 (restore majority check) + REVERT-3 (restore single retry × 3 locations) |
| [`frigate.service`](../frigate.service) | No change — keep TimeoutStartSec=1800 |

---

## Post-Revert Behaviour

Each `cmd_recreate` invocation:

```
dc stop + alpine DB clear + dc up -d:   ~40s
wait_healthy:                            ~30-60s
wait_detector_ready 300 (cache):         ~5s
zmq_fix_cycle:                           ~50s
wait_healthy 300:                        ~30-60s
wait_detector_ready 120 || true:         ~5s
wait_all_processing 120 || true:         ~30-60s (majority connects within 30s)
[optional: 1 retry if majority stuck]   ~235s
                                        -----
Total without retry:                    ~3-4 min
Total with 1 retry:                     ~7-8 min
```

This is the timing profile that was working before the plan was implemented (minus the BUG-1
crash path which is now correctly fixed).

---

## Validation Checklist (after revert)

- [ ] `./deploy-frigate.sh` (auto) completes in under 10 min — no while-loop spinning
- [ ] `./deploy-frigate.sh status` shows `/dev/shm` actual values (BUG-4 kept working)
- [ ] `./deploy-frigate.sh recreate` completes cleanly without `DB_MTIME: unbound variable`
- [ ] Majority of cameras show `process_fps > 0` after deploy completes
- [ ] No `warn "ZMQ IPC still unhealthy after N retries"` in the output
