# Frigate+ Training Data Collection Branch

## Purpose
This branch (`frigate-plus-training-data`) contains ultra-permissive detection settings designed to maximize the number of captured events for Frigate+ model training.

## ⚠️  WARNING
- **DO NOT use for normal operation** — excessive false positives
- Designed solely for capturing training images to send to Frigate+
- After training, return to the normal branch

## How to Switch Branches

### Capturing Training Images (use this branch)
```bash
git checkout frigate-plus-training-data
docker compose restart frigate
```

### Back to Normal Operation
```bash
git checkout pass-01-media-2025-10-12_103216
docker compose restart frigate
```

## What Changes in Training Mode

| Parameter | Normal | Training Mode |
|-----------|--------|---------------|
| `min_score` | 0.72 | 0.25 |
| `threshold` | 0.72 | 0.25 |
| `min_area` | 3000 | 500 |
| `motion.threshold` | 26 | 10 |
| `motion.contour_area` | 200 | 50 |
| `motion.frame_alpha` | 0.4 | 0.2 |
| `motion.delta_alpha` | 0.5 | 0.3 |

## Workflow for Frigate+ Training
1. Switch to this branch & restart Frigate
2. Go outside and act like a potential intruder (dark clothes, cap, etc.)
3. Test at night under IR illumination
4. Return to Frigate UI → Events tab
5. Select ALL events where you appear (even bad frames)
6. Click "Send to Frigate+"
7. Also send false positives (bushes triggering) labeled correctly
8. On Frigate+: Annotate precisely — frame EVERY person visible
9. Click "Train Model" (uses 1 credit)
10. Switch back to normal branch
