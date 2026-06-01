# Startup Reliability — Rock-Solid Cold-Start & Hot-Start
**Branch**: `startup-reliability-rock-solid` (created 2026-06-01 14:59)
**Base**: `c4fa2e4` — the last known-working commit (11/11 cameras, many detecting)
**Goal**: Add reliability features (validate, diagnose, status) WITHOUT breaking the working pipeline

---

## 1. Why this branch exists

The previous attempt (`startup-refactor` branch, commits c70be71 → 76f24d9) introduced
new reliability features but **caused a regression** that left 5-7 of 11 cameras ZMQ-stuck.
A live test at c4fa2e4 (the pre-regression state) confirmed:

```
11/11 cameras working
jardin_devant:     cf=10.0  pf=10.0  df=13.6  ← actively detecting
jardin_devant_left: cf=10.1  pf=9.4   df=9.9
jardin_devant_right:cf=10.1  pf=9.5   df=6.7
jardin_arriere:    cf=5.0   pf=5.1   df=3.0
vue_entree, allee, piscine: all processing
```

**Rule #1: do not break c4fa2e4.** Every change must be validated by running
Frigate for at least 2 minutes and confirming 11/11 cameras still have
`process_fps > 0` before being considered "safe".

---

## 2. The architecture (already working at c4fa2e4)

```
Reolink cameras ──RTSP──> NUC go2rtc v1.9.10 (192.168.50.112:8556)
                            │
                            ▼
                  Frigate local go2rtc (127.0.0.1:8554)
                            │
                            ▼
                  Frigate ffmpeg (NVDEC + CUDA crop)
                            │
                            ▼
                  Detector (TensorRT EP on RTX 5060 Ti Blackwell SM 120)
```

**Three things that MUST keep working:**
1. The CUDA crop chain in Frigate ffmpeg:
   `hwdownload,format=nv12,format=yuv420p,crop=2048:1152:0:0`
2. The 5GB `/dev/shm` shared memory allocation
3. The TRT 10.9.0 runtime at `/trt-libs/`

---

## 3. What we want to add (the safe additions)

The new branch will add the following NON-DESTRUCTIVE features:

| # | Feature | What it does | Why it's safe |
|---|---|---|---|
| 1 | `cmd_diagnose` | Read-only 5-layer health snapshot | No config changes, no DB writes, no restarts |
| 2 | `cmd_validate` (read-only) | 9 non-destructive tests | Same as above |
| 3 | `cmd_status` (existing, kept) | Per-camera fps table | Already exists, no changes |
| 4 | `is_on_mount()` helper | Correctly detects NFS subdirs on mounts | Just a function, no behavioral change |
| 5 | NAS mount check (corrected) | Reports `device 77 (NFS)` not "not a mountpoint" | Function-level change, no side effects |

**What we will NOT add (the dangerous additions):**

| Excluded | Why |
|---|---|
| Two-phase ZMQ readiness check inside `cmd_restart` | Caused state oscillation (vue_entree regressed to stuck) |
| `cmd_recreate` clearing `frigate.db` by default | Destructive — wipes the working state |
| Config workaround removing `-hwaccel_output_format cuda` | It actually fixed only 2 of 6 cameras; the underlying issue was different |
| 3-retry loop | Caused the 17-min regression in REL-6 era |
| Grace period sleep | May help, may cause oscillation; needs investigation first |

---

## 4. Validation protocol for every change

For every commit on this branch:

### Pre-commit
```bash
# 1. Save current state
git status
git log -1 --format="%H %s"

# 2. Apply the change
# (edit files)

# 3. Syntax check
bash -n deploy-frigate.sh && echo "SYNTAX OK"
```

### Post-deploy (mandatory, before declaring success)
```bash
# 1. Recreate to pick up the change
./deploy-frigate.sh recreate

# 2. Wait 60s for system to stabilize
sleep 60

# 3. Verify 11/11 cameras have process_fps > 0
curl -s http://localhost:5000/api/stats | python3 -c "
import sys, json
s = json.load(sys.stdin)
working = stuck = 0
for name, v in sorted(s.get('cameras', {}).items()):
    cf, pf = v.get('camera_fps') or 0, v.get('process_fps') or 0
    if cf > 0 and pf > 0: working += 1
    elif cf > 0 and pf == 0: stuck += 1
print(f'Working: {working}  Stuck: {stuck}')
assert stuck == 0, f'REGRESSION: {stuck} cameras stuck after change'
print('OK: 11/11 cameras working')
"
```

### If validation fails
1. `git checkout -- deploy-frigate.sh config.yml`
2. `./deploy-frigate.sh recreate` (to restore working config)
3. Verify 11/11 working
4. Investigate the change more carefully before retrying

---

## 5. Phased implementation plan

### Phase 1 (this commit): Document and plan
- ✅ This file
- ✅ Branch created from c4fa2e4
- ✅ Pushed to remote

### Phase 2: Add read-only tooling (no behavioral change)
- Add `cmd_diagnose` to deploy-frigate.sh (read-only, no state changes)
- Add `cmd_validate` Tier 1 only (9 read-only tests, no restart)
- Add `is_on_mount()` helper + use in `check_host_readiness`, `cmd_diagnose`, `cmd_validate` V9
- **Test**: 11/11 cameras must still work after deploy

### Phase 3: Add Tier 2 validate (restart cycle test)
- Add `cmd_validate restart` (does one restart, tests post-restart)
- Make this OPT-IN (default `tier1`, must explicitly say `restart`)
- **Test**: 11/11 cameras must work before AND after the restart

### Phase 4 (future): Investigate the real restart fragility
- The state oscillation between restarts is a real issue
- Need to find the right restart pattern (delay, sequence, etc.)
- Not in scope for this branch — requires deeper Frigate/detector investigation

### Phase 5 (future): Re-introduce the stuck-cameras detection (carefully)
- Only if Phase 4 finds a SAFE way to do it
- Must never clear the frigate.db during a "recreate" unless explicitly requested
- Must not change the config.yml in production

---

## 6. Files that should NEVER change in this branch

- `config.yml` — the working pipeline is encoded here. Don't touch.
- `docker-compose.calypso.yml` — bind mounts and ports. Don't change.
- `frigate.service` — systemd unit timing. Don't change.
- `.env` — the Frigate+ API key. Don't change.
- Anything in `trt-cache/` — the built TRT engine. Don't touch.

If a change is needed to one of these, it requires:
1. Explicit operator approval
2. A separate, atomic commit
3. A documented rollback plan

---

## 7. What the operator gets

After Phase 2-3 (the safe additions), the operator will have:

```bash
# Read-only (no service impact):
./deploy-frigate.sh status       # existing — per-camera fps table
./deploy-frigate.sh diagnose     # NEW — 5-layer health snapshot
./deploy-frigate.sh validate     # NEW — 9 non-destructive tests
./deploy-frigate.sh validate restart  # NEW — restart-cycle proof

# Existing destructive (kept as-is from c4fa2e4):
./deploy-frigate.sh restart      # simple stop+start (the old way)
./deploy-frigate.sh recreate     # stop+rm+up with DB cleanup
./deploy-frigate.sh boot         # ZMQ-fix after host reboot
```

The diagnostic and validation commands will NOT modify any state. They are
strictly observability — they read the API and report what they see.

---

## 8. Anti-patterns (carried over from previous work)

These caused regressions in `startup-refactor`. Do not reintroduce:

| Anti-pattern | What happened |
|---|---|
| Destructive `cmd_recreate` clearing frigate.db by default | Lost working state; required full NUC stream re-init |
| 2-phase readiness check inside `cmd_restart` | vue_entree regressed to stuck; oscillated with other cameras |
| Removing `-hwaccel_output_format cuda` from config | Only fixed 2 of 6 cameras; the rest needed different fix |
| 3-retry ZMQ loop | Caused 17-min deploy (REL-6 era) — never bring this back |
| Modifying config.yml to "fix" detector issues | The CUDA crop chain is correct; it was a non-issue |

---

## 9. Open questions for the operator

1. **Should `cmd_validate restart` actually restart the container?** It's a destructive test. Default: NO, must opt in with `restart` arg.

2. **Should the new diagnostics write to a log file?** Default: NO, stdout only. Operators can pipe to tee if they want.

3. **Should we add a `--quiet` flag to diagnose/validate?** Useful for cron jobs. Default: NO, just need a `--json` flag for machine-readable output. TBD.

4. **Should the 3 cancelled commits on `startup-refactor` be deleted?** No — they document what was tried and why it failed. Keep as historical record. The 5 commits (c70be71, 1097fe4, f136696, eeb92fb, 76f24d9) are valuable lessons learned.

---

## 10. Git state

```
origin/startup-refactor            ← broken (5 commits, 5-7 cameras stuck)
origin/detection-optimisation      ← working (c4fa2e4 = HEAD, 11/11 cameras)
origin/move-crop-to-calypso        ← also has c4fa2e4 (working)
* startup-reliability-rock-solid   ← NEW (clean from c4fa2e4)
  c4fa2e4-tested                   ← local branch (HEAD = c4fa2e4)
```

**Current local HEAD**: c4fa2e4 (working state)
**Current branch**: `startup-reliability-rock-solid` (clean from c4fa2e4)
**Pushed**: yes, on remote as upstream

---

## 11. References

- [`plans/cold-hot-start-reliability-plan.md`](cold-hot-start-reliability-plan.md) — original design doc
- [`plans/cuda-detector-deadlock-diagnosis.md`](cuda-detector-deadlock-diagnosis.md) — the WRONG diagnosis that led to the regression
- [`plans/gemini_raw_analysis`](gemini_raw_analysis) — Gemini's raw analysis (the starting point)
- [`plans/deploy-reliability-fix-plan.md`](deploy-reliability-fix-plan.md) — first iteration
- [`plans/revert-reliability-regression-plan.md`](revert-reliability-regression-plan.md) — post-mortem of the 17-min REL-6 regression

These documents are kept for historical reference but the **c4fa2e4 baseline is the only proven-working state**.
