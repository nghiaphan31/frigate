# Intermediate Optimization Plan — Resolution & FPS per Role per Camera

## Context

Before proceeding to **Phase 2** (walking tests and data-driven parameter refinement), this intermediate phase reviews and optimizes **resolution and FPS settings** for each role (detect, record, audio, live) on each of the 11 logical cameras.

The goal is to **minimize resource usage** (GPU decode load, CPU ffmpeg overhead, network bandwidth, storage I/O) without sacrificing detection quality. The Frigate+ model input is always 320×320 regardless of detection stream resolution, so excess resolution only wastes resources.

---

## Walkable Area Reference Data

The following walkable area dimensions were provided to determine minimum FPS requirements:

| Camera | Walkable Area | Source |
|--------|---------------|--------|
| allee_sur_le_cote | 22m × 3m | User input |
| jardin_arriere | 5m × 12m | User input |
| piscine_vue_toit | 5m × 12m | User input |
| vue_entree | 6m × 3m | User input |
| jardin_devant | 3m × 3m | User input |

**FPS Calculation Basis:** A person walking at ~1.4 m/s (average walking speed) crossing the smallest dimension of the walkable area.

| Camera | Smallest dimension | Crossing time at 1.4 m/s | Min frames at current FPS | Min frames at proposed FPS |
|--------|-------------------|--------------------------|---------------------------|----------------------------|
| allee_sur_le_cote | 3m | 2.14s | 10.7 @ 5fps | 10.7 @ 5fps |
| jardin_arriere | 5m | 3.57s | 17.9 @ 5fps | 17.9 @ 5fps |
| piscine_vue_toit | 5m | 3.57s | 17.9 @ 5fps | 17.9 @ 5fps |
| vue_entree | 3m | 2.14s | 21.4 @ 10fps | 15 @ 7fps |
| jardin_devant | 3m | 2.14s | 21.4 @ 10fps | 10.7 @ 5fps |

---

## 2. Per-Camera FPS Rationale

### 2.1 allee_sur_le_cote

**Walkable area:** 22m × 3m (smallest dimension = 3m)
*Source: "allee_sur_le_cote: the smallest walkable area which is visible by the camera is 22m × 3m"*

**Current FPS:** 5 | **Proposed FPS:** 5 (no change)

At 5 FPS with a 3m crossing distance (2.14s crossing time at 1.4 m/s), this camera captures **10.7 frames** of a person crossing — well above minimum. The camera is already at optimal 5 FPS. Further reduction would risk missing fast-moving individuals.

---

### 2.2 allee_sur_le_cote_left / allee_sur_le_cote_right

**Parent walkable area:** 22m × 3m (same physical camera as allee_sur_le_cote)

**Current FPS:** 10 | **Proposed FPS:** 7

These are half-crop detection cameras covering approximately half the parent's 3m width (~1.5m effective). At 7 FPS, crossing time (~2.14s for 1.5m), yields **~15 frames** per crossing. Sufficient temporal coverage while reducing decode load by 30%.

**Resource savings:** 23.6 MP/s → 16.5 MP/s per camera

---

### 2.3 jardin_arriere

**Walkable area:** 5m × 12m (smallest dimension = 5m)
*Source: "jardin_arriere: the smallest walkable area which is visible by the camera is 5m × 12m"*

**Current FPS:** 5 | **Proposed FPS:** 5 (no change)

At 5 FPS with a 5m crossing distance (3.57s crossing time at 1.4 m/s), this camera captures **17.9 frames** of a person crossing — the highest frame count of all cameras due to the large walkable area. 5 FPS is already optimal for this 4K camera.

---

### 2.4 vue_entree

**Walkable area:** 6m × 3m (smallest dimension = 3m)
*Source: "vue_entree: the smallest walkable area which is visible by the camera is 6m × 3m"*

**Current FPS:** 10 | **Proposed FPS:** 7

At 7 FPS with a 3m crossing distance (2.14s crossing time at 1.4 m/s), this camera captures **15 frames** of a person crossing — well above minimum. The doorbell camera at 1.7m height (eye level) with 135° H-FOV covers a large area. Visitors approach from the street and move relatively slowly (doorbell context). 7 FPS is sufficient for reliable detection while reducing decode load by 30%.

**Resource savings:** 49.2 MP/s → 34.4 MP/s

---

### 2.5 jardin_devant

**Walkable area:** 3m × 3m (smallest dimension = 3m)
*Source: "jardin_devant: the smallest walkable area which is visible by the camera is 3m × 3m"*

**Current FPS:** 10 | **Proposed FPS:** 5

This is a panoramic overview camera. The actual detection work is done by the half-crop cameras (jardin_devant_left and jardin_devant_right). At 5 FPS with a 3m crossing distance (2.14s crossing time), this camera captures **10.7 frames** of a person crossing — sufficient for zone coverage while the half-crop cameras handle high-resolution detection.

**Resource savings:** 6.6 MP/s → 3.3 MP/s (50% reduction)

---

### 2.6 jardin_devant_left / jardin_devant_right

**Parent walkable area:** 3m × 3m (same physical camera as jardin_devant)

**Current FPS:** 10 | **Proposed FPS:** 7

These are half-crop detection cameras covering approximately half the parent's 3m width (~1.5m effective). At 7 FPS, crossing time (~2.14s for 1.5m), yields **~15 frames** per crossing. Sufficient temporal coverage while reducing decode load by 30%.

**Resource savings:** 23.6 MP/s → 16.5 MP/s per camera

---

### 2.7 piscine_vue_toit

**Walkable area:** 5m × 12m (smallest dimension = 5m)
*Source: "piscine_vue_toit: the smallest walkable area which is visible by the camera is 5m × 12m"*

**Current FPS:** 10 | **Proposed FPS:** 5

This is a panoramic overview camera (roof/gutter mount, 6m height, 25° tilt). The actual detection work is done by the half-crop cameras (piscine_vue_toit_left and piscine_vue_toit_right). At 5 FPS with a 5m crossing distance (3.57s crossing time), this camera captures **17.9 frames** of a person crossing — the highest frame count of all overview cameras due to the large walkable area.

**Resource savings:** 6.6 MP/s → 3.3 MP/s (50% reduction)

---

### 2.8 piscine_vue_toit_left / piscine_vue_toit_right

**Parent walkable area:** 5m × 12m (same physical camera as piscine_vue_toit)

**Current FPS:** 10 | **Proposed FPS:** 7

These are half-crop detection cameras covering approximately half the parent's 5m width (~2.5m effective). At 7 FPS, crossing time (~1.79s for 2.5m at 1.4 m/s), yields **~12.5 frames** per crossing. Sufficient temporal coverage while reducing decode load by 30%.

**Resource savings:** 23.6 MP/s → 16.5 MP/s per camera

---

## 3. Current State Audit

### 1.1 Detection Streams — Resolution & FPS

| Camera | Role | Stream | Resolution | FPS | Decode | Notes |
|--------|------|--------|------------|-----|--------|-------|
| allee_sur_le_cote | detect | sub | 1536×432 | **5** | CPU | Full panoramic overview |
| allee_sur_le_cote_left | detect | main crop | 2048×1152 | **10** | CUDA | Left half, GPU crop |
| allee_sur_le_cote_right | detect | main crop | 2048×1152 | **10** | CUDA | Right half, GPU crop |
| jardin_arriere | detect | main | 3840×2160 | **5** | CUDA | 4K UHD |
| vue_entree | detect | main | 2560×1920 | **10** | CUDA | 4:3 ~5MP |
| jardin_devant | detect | sub | 1536×432 | **10** | CPU | Full panoramic overview |
| jardin_devant_left | detect | main crop | 2048×1152 | **10** | CUDA | Left half, GPU crop |
| jardin_devant_right | detect | main crop | 2048×1152 | **10** | CUDA | Right half, GPU crop |
| piscine_vue_toit | detect | sub | 1536×432 | **10** | CPU | Full panoramic overview |
| piscine_vue_toit_left | detect | main crop | 2048×1152 | **10** | CUDA | Left half, GPU crop |
| piscine_vue_toit_right | detect | main crop | 2048×1152 | **10** | CUDA | Right half, GPU crop |

### 1.2 Record Streams

| Camera | Role | Stream | Resolution | Codec | Notes |
|--------|------|--------|------------|-------|-------|
| allee_sur_le_cote | record | main | 4096×1152 | copy | Full panoramic |
| allee_sur_le_cote_left | record | main | 4096×1152 | copy | Shared with allee_sur_le_cote |
| allee_sur_le_cote_right | record | main | 4096×1152 | copy | Shared with allee_sur_le_cote |
| jardin_arriere | record | main | 3840×2160 | copy | 4K UHD |
| vue_entree | record | main | 2560×1920 | copy | 4:3 ~5MP |
| jardin_devant | record | main | 4096×1152 | copy | Full panoramic |
| jardin_devant_left | record | main | 4096×1152 | copy | Shared with jardin_devant_right |
| jardin_devant_right | record | main | 4096×1152 | copy | Shared with jardin_devant_left |
| piscine_vue_toit | record | main | 4096×1152 | copy | Full panoramic |
| piscine_vue_toit_left | record | main | 4096×1152 | copy | Shared with piscine_vue_toit_right |
| piscine_vue_toit_right | record | main | 4096×1152 | copy | Shared with piscine_vue_toit_left |

### 1.3 ffmpeg Process Count

| Physical Camera | Logical Cameras | ffmpeg Processes | Notes |
|-----------------|-----------------|------------------|-------|
| allee_sur_le_cote (Duo 3) | 3 | 5 | allee_sur_le_cote (detect+record+audio) + left (detect+record) + right (detect+record) |
| jardin_arriere (RLC-810A) | 1 | 2 | detect + record+audio |
| vue_entree (Doorbell) | 1 | 2 | detect + record+audio |
| jardin_devant (Duo 3) | 3 | 5 | jardin_devant (detect+record) + left (detect+record) + right (detect+record) |
| piscine_vue_toit (Duo 3) | 3 | 5 | piscine_vue_toit (detect+record+audio) + left (detect+record+audio) + right (detect+record) |
| **Total** | **11** | **19** | |

---

## 3. Resource Optimization Analysis

### 3.1 Detection Decode Load

**Current state vs. proposed FPS:**

| Camera | Resolution | Current FPS | Proposed FPS | Current MP/s | Proposed MP/s |
|--------|------------|-------------|--------------|--------------|---------------|
| allee_sur_le_cote | 1536×432 | 5 | 5 | 3.3 | 3.3 |
| allee_sur_le_cote_left | 2048×1152 | 10 | 7 | 23.6 | 16.5 |
| allee_sur_le_cote_right | 2048×1152 | 10 | 7 | 23.6 | 16.5 |
| jardin_arriere | 3840×2160 | 5 | 5 | 41.5 | 41.5 |
| vue_entree | 2560×1920 | 10 | 7 | 49.2 | 34.4 |
| jardin_devant | 1536×432 | 10 | 5 | 6.6 | 3.3 |
| jardin_devant_left | 2048×1152 | 10 | 7 | 23.6 | 16.5 |
| jardin_devant_right | 2048×1152 | 10 | 7 | 23.6 | 16.5 |
| piscine_vue_toit | 1536×432 | 10 | 5 | 6.6 | 3.3 |
| piscine_vue_toit_left | 2048×1152 | 10 | 7 | 23.6 | 16.5 |
| piscine_vue_toit_right | 2048×1152 | 10 | 7 | 23.6 | 16.5 |
| **Total** | | **100** | **62** | **249 MP/s** | **168 MP/s** |

### 3.2 Resource Savings Summary

| Metric | Before | After | Savings |
|--------|--------|-------|---------|
| Total detection FPS | 100 | **62** | **-38%** |
| vue_entree decode load | 49.2 MP/s | 34.4 MP/s | -30% |
| jardin_devant decode load | 6.6 MP/s | 3.3 MP/s | -50% |
| piscine_vue_toit decode load | 6.6 MP/s | 3.3 MP/s | -50% |
| Half-crop cameras (6×) | 23.6 MP/s each | 16.5 MP/s each | -30% each |
| **Total decode load** | ~249 MP/s | **~168 MP/s** | **-33%** |

---

## 4. Stream Unification Optimization

### 4.1 Problem: Different Streams for Detect and Record

Three overview cameras currently use **different streams** for detect and record:

| Camera | Detect Stream | Record Stream | Issue |
|--------|-------------|--------------|-------|
| allee_sur_le_cote | sub (1536×432) | main (4096×1152) | Frigate must decode BOTH streams |
| jardin_devant | sub (1536×432) | main (4096×1152) | Frigate must decode BOTH streams |
| piscine_vue_toit | sub (1536×432) | main (4096×1152) | Frigate must decode BOTH streams |

When detect and record use different streams, Frigate cannot share decoded frames — it must decode each stream separately.

### 4.2 Solution: Use Same Stream for Both Detect and Record

For the three overview cameras, use **sub-stream for BOTH detect and record**:

| Camera | Detect Stream | Record Stream | Benefit |
|--------|-------------|--------------|---------|
| allee_sur_le_cote | sub | sub | Frigate decodes sub once, shares for detect+record |
| jardin_devant | sub | sub | Frigate decodes sub once, shares for detect+record |
| piscine_vue_toit | sub | sub | Frigate decodes sub once, shares for detect+record |

**Tradeoff:**
- ✓ Frigate decodes only one stream per camera (CPU/GPU savings)
- ✓ Significant disk savings on recordings (1536×432 vs 4096×1152 = 87% less pixels)
- ❌ Lower quality recordings (sub-stream quality)

**This is the recommended approach for overview cameras** — the resource savings outweigh the marginal quality difference for review purposes.

### 4.3 Half-Crop Cameras: Already Optimized

Half-crop cameras (allee_sur_le_cote_left/right, jardin_devant_left/right, piscine_vue_toit_left/right) already use the same main stream for both detect and record — no changes needed.

### 4.4 Single-Lens Cameras: Already Optimized

`jardin_arriere` and `vue_entree` already use main for both detect and record — no changes needed.

---

## 5. No Changes to Other Settings

### 5.1 Detection Resolution
All detection resolutions remain unchanged — they are appropriate for their roles.

### 5.2 Detection Parameters
Object filters (min_area, threshold, min_score, etc.) are unchanged — they are resolution-independent.

### 5.3 Audio
Audio streams remain on main stream as before.

---

## 6. Implementation

### 6.1 FPS Reductions

```yaml
cameras:
  allee_sur_le_cote_left:
    detect:
      fps: 7  # was 10

  allee_sur_le_cote_right:
    detect:
      fps: 7  # was 10

  vue_entree:
    detect:
      fps: 7  # was 10

  jardin_devant:
    detect:
      fps: 5  # was 10

  jardin_devant_left:
    detect:
      fps: 7  # was 10

  jardin_devant_right:
    detect:
      fps: 7  # was 10

  piscine_vue_toit:
    detect:
      fps: 5  # was 10

  piscine_vue_toit_left:
    detect:
      fps: 7  # was 10

  piscine_vue_toit_right:
    detect:
      fps: 7  # was 10
```

### 6.2 Stream Unification for Overview Cameras

For `allee_sur_le_cote`, `jardin_devant`, and `piscine_vue_toit`, change record to use sub-stream (same as detect):

**allee_sur_le_cote:**
```yaml
  allee_sur_le_cote:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/allee_sur_le_cote_sub
          roles: [detect, record, audio]  # was: detect, then main for record+audio
```

**jardin_devant:**
```yaml
  jardin_devant:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/jardin_devant_sub
          roles: [detect, record]  # was: detect, then main for record+audio
```

**piscine_vue_toit:**
```yaml
  piscine_vue_toit:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/piscine_vue_toit_sub
          roles: [detect, record, audio]  # was: detect, then main for record+audio
```

**Note:** Audio will also come from sub-stream for these cameras. This is acceptable for security event audio detection.

### 5.2 Verification After Deploy

1. All 11 cameras start without errors
2. `det_fps` > 0 for all cameras
3. Check Frigate logs for decode errors or performance warnings
4. Monitor GPU utilization during first hour

---

## 6. Decision Required

Please confirm:

1. **Approve all FPS changes as proposed above?**
2. **Any cameras that should keep current FPS?**
3. **Any additional optimizations before implementation?**

---

## 7. Relationship to Phase 2

Once this intermediate optimization is deployed and stable, Phase 2 (walking tests) proceeds with the optimized resource settings.

```mermaid
graph LR
    A[Phase 1<br/>Physics-based params] --> B[Intermediate<br/>FPS & Resolution Optimization]
    B --> C[Phase 2<br/>Walking Tests]
    C --> D[Phase 3<br/>Data-driven refinement]