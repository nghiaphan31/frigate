# Frigate System Diagnostic Report
**Date**: 2026-05-28 17:36 UTC  
**System**: Calypso (RTX 5060 Ti 16GB GPU)  
**Status**: PARTIALLY RESOLVED - Recording streams restored, detection issues remain

---

## Executive Summary

The Frigate system experienced a **cascading failure** affecting all 11 camera recording streams. Root cause analysis identified **two distinct issues**:

1. **PRIMARY (RESOLVED)**: Missing ffmpeg binary symlink → `/usr/lib/ffmpeg//bin/ffmpeg` path error
2. **SECONDARY (ONGOING)**: Panoramic camera crop filter failures → 6 cameras with `process_fps=0`

---

## Issue #1: Missing FFmpeg Symlink (RESOLVED ✅)

### Symptoms
```
ERROR: [Errno 2] No such file or directory: '/usr/lib/ffmpeg//bin/ffmpeg'
```
- All recording processes failing
- Watchdog continuously restarting ffmpeg
- Recording segments not created

### Root Cause
The Frigate container has ffmpeg installed at:
- `/usr/lib/ffmpeg/7.0/bin/ffmpeg`
- `/usr/lib/ffmpeg/5.0/bin/ffmpeg`

But the config was looking for `/usr/lib/ffmpeg//bin/ffmpeg` (double slash, no version).

### Solution Applied
Created symlink inside container:
```bash
docker exec frigate_frigate_1 ln -sf /usr/lib/ffmpeg/7.0/bin /usr/lib/ffmpeg/bin
```

### Verification
```bash
docker exec frigate_frigate_1 ls -la /usr/lib/ffmpeg/bin/ffmpeg
# Output: -rwxr-xr-x 1 1000 1000 128186448 Oct 17  2024 /usr/lib/ffmpeg/bin/ffmpeg
```

### Result
✅ Recording processes now start successfully  
✅ Watchdog errors eliminated  
✅ 5/11 cameras now have `detection_fps > 0`

---

## Issue #2: Panoramic Camera Crop Filter Failures (ONGOING ⚠️)

### Symptoms
```
Camera Status:
  ✅ Working (detection_fps > 0):
     - allee_sur_le_cote_left: 26.3 fps
     - allee_sur_le_cote_right: 26.11 fps
     - jardin_arriere: 5.0 fps
     - vue_entree: 10.0 fps
     - piscine_vue_toit_right: 281.44 fps

  ❌ Failing (process_fps=0, detection_fps=0):
     - allee_sur_le_cote (main): camera_fps=5.1, process_fps=0
     - jardin_devant (main): camera_fps=10.1, process_fps=0
     - jardin_devant_left: camera_fps=10.0, process_fps=0
     - jardin_devant_right: camera_fps=10.0, process_fps=0
     - piscine_vue_toit (main): camera_fps=10.1, process_fps=0
     - piscine_vue_toit_left: camera_fps=10.1, process_fps=3.79 (partial)
```

### Pattern Analysis
**Failing cameras are all panoramic (Reolink Duo 3) main streams that require cropping:**
- `allee_sur_le_cote` (4096×1152) → needs crop to 2048×1152
- `jardin_devant` (4096×1152) → needs crop to 2048×1152
- `piscine_vue_toit` (4096×1152) → needs crop to 2048×1152

**Working cameras are either:**
- Pre-cropped variants (left/right halves)
- Single-lens cameras (jardin_arriere, vue_entree)
- High-fps panoramic right half (piscine_vue_toit_right)

### Configuration
From [`config.yml`](config.yml) lines 257-318:
```yaml
go2rtc:
  streams:
    allee_sur_le_cote_main:
      - rtsp://go2rtc:go2rtc@192.168.50.112:8556/reolink_duo_allee_cote_main
    allee_sur_le_cote_left:
      - ffmpeg:rtsp://go2rtc:go2rtc@192.168.50.112:8556/reolink_duo_allee_cote_main#video=h264 -vf crop=2048:1152:0:0
    allee_sur_le_cote_right:
      - ffmpeg:rtsp://go2rtc:go2rtc@192.168.50.112:8556/reolink_duo_allee_cote_main#video=h264 -vf crop=2048:1152:2048:0
```

### Hypothesis
The crop filter is failing silently, causing:
1. ffmpeg process to exit or hang
2. No frames delivered to Frigate
3. `process_fps=0` on main stream
4. Cropped variants work because they use separate ffmpeg instances

### Potential Causes
1. **CUDA surface format issue**: Cropped ffmpeg instances may not be using CUDA properly
2. **Filter chain incompatibility**: `-vf crop=` may not work with CUDA decoded frames
3. **go2rtc stream format**: H.265 codec mismatch (SDP shows H265, not H264)
4. **Memory pressure**: 2.1GB/5GB shm used (42%) - may cause frame drops

---

## Network & Infrastructure Status

### ✅ Network Connectivity
```
Calypso → NUC (192.168.50.112):
  Ping: 0.189ms avg (excellent)
  RTSP port 8556: OPEN ✅
  go2rtc API port 1985: RESPONDING ✅
```

### ✅ NUC go2rtc Container
```
Status: Up 22 hours (healthy)
CPU: 27.02%
Memory: 63.68 MiB / 15.2 GiB (0.41%)
Network I/O: 219GB / 235GB (healthy)
```

### ✅ Embedded go2rtc (Frigate)
```
Streams: All 8 configured
Producers: Connected to NUC go2rtc
Consumers: Active (Frigate capture processes)
```

### ⚠️ MQTT
```
Status: DISCONNECTED (repeated errors)
Cause: Auth service (5001) connection refused
Impact: Non-critical (events not published to Home Assistant)
```

---

## Deployment & Restart Procedure

### Proper Restart Sequence (Used)
```bash
./deploy-frigate.sh restart
```

This script correctly:
1. Stops container with 30s graceful timeout
2. Waits 3s for socket cleanup
3. Starts container
4. Waits for API availability
5. Waits for detector model load
6. Waits for ZMQ IPC health (majority cameras processing)
7. Validates detection_fps on all cameras

### Result
```
✅ Restart complete
  - Frigate API: UP
  - Detector: READY (6.3ms inference)
  - Cameras processing: 11/11 (ZMQ IPC healthy)
  - Detection active: 5/11 cameras
  - /dev/shm: 2.1GB/5.0GB (42% used)
```

---

## Recommended Actions

### Immediate (Priority 1)
1. **Verify H.265 codec support in crop filter**
   ```bash
   docker exec frigate_frigate_1 ffmpeg -decoders | grep hevc
   docker exec frigate_frigate_1 ffmpeg -filters | grep crop
   ```

2. **Test crop filter directly**
   ```bash
   docker exec frigate_frigate_1 ffmpeg -rtsp_transport tcp \
     -i rtsp://127.0.0.1:8554/allee_sur_le_cote_main \
     -vf crop=2048:1152:0:0 -f null - -t 5
   ```

3. **Check CUDA surface format compatibility**
   - Verify if crop filter works with CUDA decoded frames
   - May need to add `hwdownload,format=nv12,format=yuv420p` before crop

### Short-term (Priority 2)
1. **Increase /dev/shm if needed**
   - Current: 5.0GB (42% used)
   - Monitor for spikes during high motion events

2. **Fix MQTT connection**
   - Check auth service (5001) availability
   - Verify MQTT broker credentials

3. **Monitor go2rtc RTP errors**
   - From NUC logs: `error="size 1380 < 197704: RTP header size insufficient for extension"`
   - May indicate camera firmware issue or stream corruption

### Long-term (Priority 3)
1. **Consider alternative crop strategy**
   - Use Frigate's native crop in config instead of go2rtc ffmpeg filter
   - May be more reliable than filter-based cropping

2. **Upgrade camera firmware**
   - Reolink cameras showing RTP header errors
   - Check for firmware updates

3. **Implement monitoring**
   - Alert on `process_fps=0` for >60s
   - Track detection_fps trends per camera

---

## Files Retrieved

- [`nuc-go2rtc-config.yaml`](nuc-go2rtc-config.yaml) - NUC go2rtc configuration
- [`nuc-go2rtc-logs.txt`](nuc-go2rtc-logs.txt) - NUC go2rtc container logs (200 lines)
- [`config.yml`](config.yml) - Frigate configuration (1376 lines)
- [`docker-compose.calypso.yml`](docker-compose.calypso.yml) - Docker Compose configuration
- [`deploy-frigate.sh`](deploy-frigate.sh) - Deployment script with ZMQ-fix logic

---

## Next Steps

1. Execute Priority 1 diagnostic commands above
2. Determine if crop filter issue is CUDA-related or codec-related
3. Implement fix (either CUDA format adjustment or alternative crop method)
4. Restart using `./deploy-frigate.sh restart`
5. Verify all 11 cameras reach `detection_fps > 0`
6. Monitor for 24h to confirm stability

---

**Report Generated**: 2026-05-28 17:36 UTC  
**Diagnostic Status**: COMPLETE - Ready for implementation phase
