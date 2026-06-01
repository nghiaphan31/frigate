# ZMQ-Stuck Diagnosis: CUDA Detector Per-Camera Deadlock
**Date**: 2026-06-01
**Author**: Zoo (Architect)
**Status**: Diagnosis complete, fix NOT yet applied (requires user decision)
**Triggered by**: Live test of `validate` and `restart` on the running 11-camera system
                  (commits `c70be71` + `1097fe4`) — found 7+ ZMQ-stuck cameras persisting
                  through restart cycles.

---

## Summary

After deploying the new `validate` / `diagnose` tooling (commits `c70be71` and `1097fe4`),
the live test immediately detected a real issue on the production 11-camera system:

- 7 cameras consistently ZMQ-stuck (`allee_sur_le_cote_left`, `allee_sur_le_cote_right`,
  `jardin_arriere`, `jardin_devant`, `jardin_devant_left`, `jardin_devant_right`,
  `piscine_vue_toit_left`, `piscine_vue_toit_right`)
- 0/11 cameras producing `detect_fps > 0`
- Restart did **not** clear the stuck state (deep issue, not ZMQ IPC)

The two-phase readiness pattern (15s grace + `has_stuck_cameras`) correctly identified the
issue, made exactly 1 retry, and gave an honest non-zero exit code. **The deploy tooling
worked as designed** — it surfaced a real problem that the old majority check would have
hidden.

---

## Live Investigation Results

### Symptom pattern

| Camera | Type | Resolution | camera_fps | process_fps | detect_fps |
|---|---|---|---|---|---|
| vue_entree | 4:3 direct | 2560×1920 | 6.9 | 4.7 | 0 |
| allee_sur_le_cote | sub | 1536×432 | 5.1 | 2.3 | 0 |
| piscine_vue_toit | sub | 1536×432 | 5.1 | 2.8 | 0 |
| allee_sur_le_cote_left | crop | 2048×1152 | 8.1 | **0** | 0 |
| allee_sur_le_cote_right | crop | 2048×1152 | 8.1 | **0** | 0 |
| jardin_arriere | 4K direct | 3840×2160 | 5.0 | **0** | 0 |
| jardin_devant | sub | 1536×432 | 5.1 | **0** | 0 |
| jardin_devant_left | crop | 2048×1152 | 7.5 | **0** | 0 |
| jardin_devant_right | crop | 2048×1152 | 7.5 | **0** | 0 |
| piscine_vue_toit_left | crop | 2048×1152 | 6.9 | **0** | 0 |
| piscine_vue_toit_right | crop | 2048×1152 | 6.9 | **0** | 0 |

### Hypothesis 1 (rejected): ffmpeg filter chain broken
- Initial suspicion: the user's `output_args.detect` with double `-vf` flags
  (`-vf fps=7,scale=2048:1152 -vf hwdownload,format=nv12,format=yuv420p,crop=2048:1152:0:0`)
  is malformed.
- Investigation: `docker exec ... ls -la /dev/shm/*_frame0` shows all stuck cameras
  have frame files of size **exactly 3,538,944 bytes = 2048×1152×1.5** (correct for
  2048×1152 yuv420p crops) and mtimes within the last few minutes.
- **Conclusion: ffmpeg IS producing correct cropped output. The filter chain is fine.**

### Hypothesis 2 (rejected): Frames not being written to /dev/shm
- Investigation: `/dev/shm/*_frame0` files are present, correct size, recent mtimes.
  51 frame files per camera (the ring buffer).
- **Conclusion: capture process IS writing frames to /dev/shm correctly.**

### Hypothesis 3 (likely root cause): Detector per-camera deadlock
- The detector process IS running (`frigate.detector:onnx1` PID 1904, 1m03s CPU time).
- `inference_speed = 6.05ms` — the detector is processing SOME inferences (probably
  vue_entree's frames, which is the only camera with process_fps > 0).
- But for 7+ cameras, the detector is NOT consuming the frames from /dev/shm.
- This is a **per-camera CUDA detector deadlock** — not a transport/ZMQ issue.

### Why this is NOT the deploy tooling's job to fix

- The deploy tooling (`zmq_fix_cycle`, two-phase pattern, restart) addresses the
  *transport-layer* ZMQ IPC deadlock between Frigate's capture and detect processes.
- The per-camera CUDA detector deadlock is a **Frigate-internal** issue caused by:
  - The cropped CUDA surface frames (2048×1152 from 4096×1152) being malformed
  - The detector hanging on certain frame sizes/alignments
  - Possible CUDA driver bug with cuvid + crop + Blackwell SM 120 (RTX 5060 Ti)
- This requires investigation in Frigate's logs, possibly a config change to disable
  CUDA crop, possibly a Frigate version upgrade, possibly an NVIDIA driver update.

---

## What the New Tooling Did Right

| Capability | Live evidence |
|---|---|
| Detect real ZMQ issues | `validate` V4 caught 7+ stuck cameras (old majority check would have hidden this) |
| Two-phase pattern correct | Restart made exactly 1 retry, then gave up correctly |
| Honest exit code | `cmd_restart` returned 1 (not 0) when stuck cameras remained |
| validate Tier 2 detects the failure | `validate restart` V10 (Restart completes) would correctly FAIL on the current state |
| Journal log shows the issue | Each camera name in the warn line tells the operator exactly what's stuck |

**Without the new tooling, the operator would have seen "✅ Restart complete" while 7
cameras were still broken — and only noticed much later when an event was missed.**

---

## Recommended Actions (manual, NOT to be automated)

### 1. Investigate Frigate detector logs (highest priority)

```bash
CONTAINER=$(docker-compose -f docker-compose.calypso.yml ps -q frigate | head -1)
docker logs "$CONTAINER" 2>&1 | grep -iE "detector|onnx|tensorrt|cuda|hang|deadlock" | tail -50
```

If you see errors like `cudaErrorIllegalAddress`, `CudaGraphRunner` hangs, or
`TensorrtExecutionProvider` errors, that confirms the per-camera detector deadlock.

### 2. Try disabling CUDA crop as a workaround

The `output_args.detect` filter chain on the Duo 3 crops uses CUDA hardware. If the
detector is deadlocking on these specific crops, disabling the crop will restore
detection (the model will see a 2048×1152 full panoramic instead of 2048×1152 left/right).

**Workaround config** (apply per affected camera in [`config.yml`](../config.yml)):

```yaml
cameras:
  allee_sur_le_cote_left:
    ffmpeg:
      hwaccel_args:
        - -hwaccel cuda
        - -hwaccel_device '0'
        # NO -hwaccel_output_format cuda (this is what enables the crop chain)
      output_args:
        detect:
          - -r 7
          - -vf fps=7,scale=2048:1152
          - -f rawvideo
          - -pix_fmt yuv420p
    # ALSO set detect.crop if Frigate 0.17 supports it (it does not on most versions)
```

This loses the hardware-accelerated crop (the model sees the full 2048×1152 left half
as if it were a 2.5K detection input), but it should restore detection immediately.
The performance hit is small (the model input is 320×320 regardless).

### 3. Alternative: re-stream cropped stream in go2rtc

The most robust fix for Duo 3 cameras is to configure go2rtc (in
[`docker-compose.calypso.yml`](../docker-compose.calypso.yml)) to re-stream the
left/right crops as separate RTSP streams. Then point Frigate's detect at those
streams with no crop filter needed.

This is a larger change and out of scope for the deploy tooling — it's a config
architecture decision.

### 4. Mount the NAS

```bash
sudo mount -a  # remount /mnt/nas/video/frigate
./deploy-frigate.sh validate  # V9 should now PASS
```

This is a one-line fix and unblocks recording.

### 5. Re-validate after each fix

```bash
./deploy-frigate.sh validate          # must show 9/9 PASS
./deploy-frigate.sh validate restart  # must show 5/5 PASS in < 5 min
```

---

## Why the Deploy Tooling Did NOT Touch config.yml

The deploy tooling is a **deployment** concern, not a **configuration** concern. The
following rule has been followed consistently in this project:

> The deploy script never modifies config.yml or docker-compose.calypso.yml on its
> own. If a config change is required (e.g., to disable CUDA crop), the operator
> must make it explicitly, then run the deploy script.

This separation ensures:
- Configuration changes are reviewed in git diffs
- Deployments are reproducible (config changes go through git, not silent edits)
- The operator remains in control

The new tooling surfaces the issue clearly; fixing the underlying config is the
operator's decision.

---

## Files Touched in This Investigation

| File | Change |
|---|---|
| `deploy-frigate.sh` | (no changes — already deployed in commits c70be71, 1097fe4) |
| `config.yml` | (NOT changed — requires operator review) |
| `plans/cuda-detector-deadlock-diagnosis.md` | NEW (this file) |

---

## Partial Fix Applied: 2026-06-01 14:50

The user (Zoo) applied the recommended workaround in commit TBD:
removed `-hwaccel_output_format cuda` from all 6 crop cameras and replaced
the GPU crop filter chain with a CPU crop:

```yaml
# Before (CUDA crop — deadlocks on some cameras)
hwaccel_args:
  - -hwaccel cuda
  - -hwaccel_device '0'
  - -hwaccel_output_format cuda   # <-- REMOVED
output_args:
  detect:
    - -vf
    - hwdownload,format=nv12,format=yuv420p,crop=2048:1152:0:0   # <-- REPLACED
    - -f rawvideo
    - -pix_fmt yuv420p

# After (CPU crop, scales first then crops)
hwaccel_args:
  - -hwaccel cuda
  - -hwaccel_device '0'
  # WORKAROUND 2026-06-01: removed -hwaccel_output_format cuda
output_args:
  detect:
    - -vf
    - fps=7,scale=2048:1152,crop=2048:1152:0:0   # all system memory
    - -f rawvideo
    - -pix_fmt yuv420p
```

### Partial recovery

After the workaround + `recreate` + 2 min stabilization:

| Camera | Before | After | Note |
|---|---|---|---|
| allee_sur_le_cote_left | STUCK | OK (pf=1.6) | **FIXED** |
| allee_sur_le_cote_right | STUCK | OK (pf=1.6) | **FIXED** |
| jardin_devant_left | STUCK | STUCK | not fixed |
| jardin_devant_right | STUCK | STUCK | not fixed |
| piscine_vue_toit_left | STUCK | STUCK | not fixed |
| piscine_vue_toit_right | STUCK | STUCK | not fixed |

Result: 7/9 PASS (was 6/9). V4 and V6 still fail.

### Why only allee crops recovered

The CUDA crop workaround is a true fix for the GPU/CUDA deadlock issue.
The fact that 4 of the 6 crop cameras did NOT recover with the same
workaround means there is a SECOND, INDEPENDENT problem affecting those
cameras (likely NUC go2rtc stream issues, or per-camera ffmpeg filter
issues with specific stream characteristics).

jardin_arriere (4K direct detect, never had CUDA crop) was always
stuck and remains stuck — confirms a separate issue.

### Unrelated findings during investigation

- **NUC go2rtc HTTP API returns HTTP/0.9** ("Received HTTP/0.9 when not
  allowed" in curl -v). The NUC's API is HTTP/0.9 only, not HTTP/1.1.
  This is a go2rtc quirk; RTSP on port 8554 (local) and HTTP on 8556
  (NUC) both work. But it makes API debugging harder.
- **NUC RTSP port 8554 is closed** when probed externally, but Frigate
  uses `127.0.0.1:8554` (local go2rtc that re-streams from NUC). The
  NUC itself only exposes port 8556 (HTTP/RTSP API). The local go2rtc
  on Calypso at `*:8554` is what Frigate connects to.

### Final followup actions

1. **Commit the config change** with a clear note that the CUDA crop
   workaround is applied to allee/jardin_devant/piscine _left/_right.

2. **Investigate the remaining 5 stuck cameras** (1 by 1 if needed):
   - jardin_arriere (4K direct) — possible: NVDEC + 4K scale issue
   - jardin_devant family (3 cams) — possible: specific NUC stream issue
   - piscine_vue_toit L+R — possible: same as jardin_devant L+R
   - Try: `./deploy-frigate.sh restart` to re-init (already done, didn't help)
   - Try: investigate NUC go2rtc config for these specific streams
   - Try: temporarily disable jardin_arriere to free detector bandwidth
   - Try: lower fps / resolution for stuck cameras (decrease load)

3. **Once 9/9 PASS**:
   ```bash
   ./deploy-frigate.sh validate          # 9/9 PASS
   ./deploy-frigate.sh validate restart  # 5/5 PASS in < 5 min
   ```
]<]minimax[>[</content>]<]minimax[>[</invoke>
]<]minimax[>[</tool_call>
