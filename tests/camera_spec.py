# ==============================================================================
# tests/camera_spec.py — per-camera physics spec (single source of truth for L2)
# ==============================================================================
# Each camera's filter values (min_area, max_area, min_ratio, max_ratio,
# threshold, min_score) are derived from the camera's mount geometry
# using the standard physics projection:
#
#   slant_range   = sqrt(dist^2 + height^2)        # m, camera to person
#   elev_angle    = atan(height / dist)             # rad, ground-to-camera
#   depress_angle = tilt - elev_angle               # rad, optical-axis-to-person
#   H_px          = H_person * (V_FOV_rad / H_px_stream) * cos(depress_angle)
#   W_px          = W_person * (H_FOV_rad / W_px_stream) * cos(depress_angle)
#   area          = H_px * W_px                     # px², person footprint
#
#   min_area = area_far  * 0.5  (50% of smallest expected footprint)
#   max_area = area_near * 1.5  (150% of largest expected footprint)
#
# Person reference: H_person=1.6 m, W_person=0.5 m.
#
# The test (test-math.sh) loads this spec, re-derives the diagnostic
# geometry, then asserts that:
#   (a) actual config.yml filter values match the operator-verified
#       expected_min_area / expected_max_area / expected_threshold /
#       expected_min_score (within a 5 % tolerance), and
#   (b) the operator-verified min_area is itself within [0.3, 1.0] of
#       the derived area_far (i.e. the spec hasn't drifted from the
#       geometry).
#
# If either (a) or (b) fails, the camera is reported as failing L2.
# The fix is either: change config.yml to match the spec (typo), or
# change the spec to match reality (new tuning), or change the spec's
# min_area_margin (the spec was derived with the wrong margin).
# ==============================================================================
from math import sqrt, atan, cos, radians

# Person reference (matches ARCHITECTURE.md §4.6)
PERSON_H_M = 1.6   # metres, head-to-toe
PERSON_W_M = 0.5   # metres, shoulder width
PERSON_RATIO = PERSON_H_M / PERSON_W_M  # 3.2 (aspect ratio H:W)

# Detection model defaults (Frigate+ custom model; per model card)
THRESHOLD_BASE = 0.5     # model default
THRESHOLD_HOOK = 0.05    # our +0.05 noise-floor buffer
MIN_SCORE_BASE = 0.4
MIN_SCORE_HOOK = 0.05

# Geometry-vs-actual bounds.  The spec's min_area is derived from
# area_far with a margin (typically 0.5).  The geometry derivation
# has its own error (the FOV is approximate, the mount tilt is +/-2°,
# the cos correction is small-angle).  We tolerate the spec's
# min_area being between 0.3× and 1.0× the derived area_far.
GEOMETRY_MIN_LOWER  = 0.30  # 30 % of derived area_far (very generous)
GEOMETRY_MIN_UPPER  = 1.00  # 100 % of derived area_far (no over-counting)
# max_area: 150 % of derived area_near.  Same generosity.
GEOMETRY_MAX_LOWER  = 1.00
GEOMETRY_MAX_UPPER  = 2.00  # 200 % of derived area_near

# Tolerance for "spec's expected value matches config.yml's actual value"
SPEC_TOLERANCE = 0.05  # 5 %


def derive_geometry(cam):
    """Re-derive H_px, W_px, area_far, area_near from the geometry.

    Returns a dict with the derived values. The values are the diagnostic
    part of the L2 report — the assertion is the spec's expected_min_area
    matching the config.yml value.
    """
    dist  = cam["dist_m"]
    h     = cam["height_m"]
    tilt  = cam["tilt_deg"]
    vfov  = cam["v_fov_deg"]
    hfov  = cam["h_fov_deg"]
    sw    = cam["stream_w_px"]
    sh    = cam["stream_h_px"]
    near  = cam.get("near_m", 1.5)

    # Far edge (smallest footprint, worst case)
    r_far       = sqrt(dist**2 + h**2)
    elev_far    = atan(h / dist)
    depress_far = max(radians(tilt) - elev_far, 0.0)
    # Standard pinhole projection (matches Frigate's iter0 formula):
    #   angular size of person = H / r  (radians, small-angle)
    #   pixels for that angle   = (H / r) * (stream_h_px / V_FOV_rad)
    #   tilt correction         = × cos(depress_angle) (perspective foreshortening)
    H_px_far = (PERSON_H_M / r_far) * (sh / radians(vfov)) * cos(depress_far)
    W_px_far = (PERSON_W_M / r_far) * (sw / radians(hfov)) * cos(depress_far)
    area_far = H_px_far * W_px_far

    # Near edge (largest footprint)
    r_near       = sqrt(near**2 + h**2)
    elev_near    = atan(h / near)
    depress_near = max(radians(tilt) - elev_near, 0.0)
    H_px_near = (PERSON_H_M / r_near) * (sh / radians(vfov)) * cos(depress_near)
    W_px_near = (PERSON_W_M / r_near) * (sw / radians(hfov)) * cos(depress_near)
    area_near = H_px_near * W_px_near

    return {
        "slant_far_m":  round(r_far, 2),
        "depress_far":  round(degrees_safe(depress_far), 2),
        "H_px_far":     round(H_px_far, 1),
        "W_px_far":     round(W_px_far, 1),
        "area_far":     round(area_far),
        "slant_near_m": round(r_near, 2),
        "depress_near": round(degrees_safe(depress_near), 2),
        "H_px_near":    round(H_px_near, 1),
        "W_px_near":    round(W_px_near, 1),
        "area_near":    round(area_near),
    }


def degrees_safe(rad):
    from math import degrees
    return degrees(rad)


# ------------------------------------------------------------------------------
# Per-camera registry.  Add a new entry in the same commit that adds
# the camera to config.yml.  L1 (test-config.sh) and L2 (test-math.sh)
# then both pass for that commit.
#
# Key fields:
#   dist_m, height_m, tilt_deg, v_fov_deg, h_fov_deg,
#   stream_w_px, stream_h_px, near_m (optional, default 1.5)
#
# Operator-verified filter values:
#   expected_min_area   — must match config.yml within 5 %
#   expected_max_area   — must match config.yml within 5 %
#   expected_min_ratio  — bounding-box min H/W ratio
#   expected_max_ratio  — bounding-box max H/W ratio
#   expected_threshold  — model confidence threshold
#   expected_min_score  — model min_score for non-max-suppression
#   min_area_margin     — (optional) spec's margin from area_far to min_area
#   max_area_margin     — (optional) spec's margin from area_near to max_area
#   detect_stream       — (informational) go2rtc stream used for detect
#   live_stream         — (informational) go2rtc stream used for live view
#   zones               — (informational) required zone names; the test
#                         asserts they exist in config.yml (does NOT
#                         assert geometry)
# ------------------------------------------------------------------------------
CAMERAS = {
    "allee_sur_le_cote": {
        # Geometry
        "dist_m":       20.0,
        "height_m":      3.4,
        "tilt_deg":     50.0,
        "v_fov_deg":    55.0,
        "h_fov_deg":   180.0,
        "stream_w_px": 1536,
        "stream_h_px":  432,
        "near_m":        3.0,
        # Operator-verified filter values (from current config.yml)
        "expected_min_area":   124,
        "expected_max_area": 22500,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":          5,
        "detect_enabled":    True,
        "expected_zones": {
            "prive":  {"threshold": 0.55, "min_area": 124, "min_ratio": 1.0, "max_ratio": 4.0},
            "rodage": {"threshold": 0.55, "min_area": 124, "min_ratio": 1.0, "max_ratio": 4.0},
        },
        "min_area_margin":     0.50,
        # 22500 / area_near (8556) = 2.63; reflects the operator's
        # iter0 physics derivation for the allee near boundary.
        "max_area_margin":     2.63,
        # Streams
        "detect_stream": "allee_sur_le_cote_sub",
        "live_stream":   "allee_sur_le_cote_sub",
        # Required zones
        "zones": ["prive", "rodage"],
    },
    "jardin_arriere": {
        # Reolink RLC-810A 4 mm, 2.2 m mount, 10° tilt, 4K main detect
        "dist_m":       20.0,
        "height_m":      2.2,
        "tilt_deg":     10.0,
        "v_fov_deg":    44.0,
        "h_fov_deg":    87.0,
        "stream_w_px": 1920,
        "stream_h_px": 1080,
        "near_m":        5.0,
        # Post-iter1 production spec (2026-07-31). The 2026-06-04
        # training-collection relaxation (track:[person,face], fps 10,
        # threshold 0.4, min_score 0.3) has been reverted; the new
        # yolonas model (plus://c1aa04320f389aa6c7702bf9ddd3fe6d)
        # is trained on the relaxed data, so the iter0 contract is
        # now appropriate.
        #
        # The prive zone min_area is tightened 300 → 500 (relative to
        # the iter0 base) to suppress the occasional far-garden false
        # positive that the new model produces in IR mode at 15-20 m
        # — see config.yml:684-690 (the 2026-06-05 "TIGHTERED" note).
        # The detect.fps stays at 5 (iter0 contract).
        #
        # The 4K → 1080p detect stream downscale (4c77d3d, 2026-06-22)
        # is a deliberate CPU-saving production change and is NOT a
        # training-collection artefact. iter0.py leaves detect.width /
        # detect.height alone for this reason.
        "expected_min_area":   300,
        "expected_max_area": 117000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":          5,
        "detect_enabled":    True,
        "expected_zones": {
            "prive":  {"threshold": 0.55, "min_area": 500, "min_ratio": 1.0, "max_ratio": 4.0},
        },
        # The margins below were re-derived for the 1080p detect
        # stream (4c77d3d, 2026-06-22). The original 4K values were
        # 0.022 (min) and 0.61 (max) for an area_far ≈ 14 000 and
        # area_near ≈ 177 000. With the 4K→1080p downscale, the
        # areas dropped to ≈ 3 500 (far) and ≈ 47 700 (near), so
        # the margins re-derive to 0.086 (300/3499) and 2.45
        # (117 000/47 700) respectively. min_area=300 is a
        # deliberate noise-floor (catches close-range persons
        # ~3 m on 1080p, well below the physics-derived 3 500
        # area_far); max_area=117 000 is a generous upper bound
        # (operator chose to err on the side of accepting rather
        # than rejecting close-range persons).
        "min_area_margin":     0.0857,
        "max_area_margin":     2.4540,
        "detect_stream": "jardin_arriere_main",
        "live_stream":   "jardin_arriere_sub",
        "zones": ["prive"],
    },
    "vue_entree": {
        # Reolink Doorbell POE, 1.7 m mount, 0° tilt (eye level), main detect
        "dist_m":       20.0,
        "height_m":      1.7,
        "tilt_deg":      0.0,
        "v_fov_deg":   100.0,
        "h_fov_deg":   135.0,
        "stream_w_px": 2560,
        "stream_h_px": 1920,
        "near_m":        3.0,
        # Post-iter1 production spec (2026-07-31). The 2026-06-04
        # training-collection relaxation (track:[person,face], fps 10,
        # threshold 0.4, min_score 0.3, diagnostic 0.10) has been
        # reverted; the new yolonas model
        # (plus://c1aa04320f389aa6c7702bf9ddd3fe6d) is trained on the
        # relaxed data and the iter0 contract is now appropriate.
        # detect.fps is back to 7 (iter0 contract).
        #
        # The prive zone min_area is tightened 300 → 500 to suppress
        # the diagnostic-mode (0.10 threshold) FPs the relaxed camera-
        # level filter was leaking into the alert chain — see
        # config.yml:891-901 (the 2026-06-05 "TIGHTERED" note on the
        # vue_entree prive zone).
        "expected_min_area":   300,
        "expected_max_area": 144000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":          7,
        "detect_enabled":    True,
        "expected_zones": {
            "prive":  {"threshold": 0.55, "min_area": 500, "min_ratio": 1.0, "max_ratio": 4.0},
        },
        "min_area_margin":     0.126,
        "max_area_margin":     1.79,
        "detect_stream": "vue_entree_main",
        "live_stream":   "vue_entree_sub",
        "zones": ["prive"],
    },
    "jardin_devant": {
        # Reolink Duo 3, 6 m mount, 50° tilt, sub-stream detect
        "dist_m":       15.0,
        "height_m":      6.0,
        "tilt_deg":     50.0,
        "v_fov_deg":    55.0,
        "h_fov_deg":   180.0,
        "stream_w_px": 1536,
        "stream_h_px":  432,
        "near_m":        3.0,
        "expected_min_area":    72,
        "expected_max_area": 13500,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":          5,
        "detect_enabled":    True,
        "expected_zones": {
            "prive":  {"threshold": 0.55, "min_area":  72, "min_ratio": 1.0, "max_ratio": 4.0},
            "rodage": {"threshold": 0.55, "min_area":  72, "min_ratio": 1.0, "max_ratio": 4.0},
        },
        "min_area_margin":     0.138,
        "max_area_margin":     3.46,
        "detect_stream": "jardin_devant_sub",
        "live_stream":   "jardin_devant_sub",
        "zones": ["prive", "rodage"],
    },
    "piscine_vue_toit": {
        # Reolink Duo 3, 6 m mount, 25° tilt, sub-stream detect
        "dist_m":       20.0,
        "height_m":      6.0,
        "tilt_deg":     25.0,
        "v_fov_deg":    55.0,
        "h_fov_deg":   180.0,
        "stream_w_px": 1536,
        "stream_h_px":  432,
        "near_m":        5.0,
        # Post-iter1 production spec (2026-07-31). The 2026-06-04
        # training-collection relaxation (track:[person,face], fps 10,
        # threshold 0.30, min_score 0.25) has been reverted; the new
        # yolonas model is trained on the relaxed data and the iter0
        # contract is now appropriate. The 4c77d3d CPU fix (fps 5,
        # post 10-fps training bump) is already reflected below.
        "expected_min_area":   158,
        "expected_max_area": 27000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        # 4c77d3d (2026-06-22, CPU fix): reduced 10 → 5 fps. The
        # 180° panoramic sub stream has persistent noise that the
        # motion pre-filter can't reject by threshold alone — at
        # 10 fps the detector was invoked 3.4× per frame
        # (detection_fps=34.4 vs process_fps=10.1), driving process
        # CPU to 45%. Halving to 5 fps halves the detector
        # invocations regardless of motion region count. The
        # 1.4 m/s walker still gets ~3-4 chances/sec at 5 fps
        # (sufficient for the 20 m max walkable).
        "expected_fps":          5,
        "detect_enabled":    True,
        "expected_zones": {
            "prive":  {"threshold": 0.55, "min_area": 158, "min_ratio": 1.0, "max_ratio": 4.0},
        },
        "min_area_margin":     0.399,
        "max_area_margin":     9.36,
        "detect_stream": "piscine_vue_toit_sub",
        "live_stream":   "piscine_vue_toit_sub",
        "zones": ["prive"],
    },

    # ===================================================================
    # INDOOR TP-LINK TAPO C210 CAMERAS (added 2026-06-03)
    # ===================================================================
    # Detection is DISABLED per-camera (detect.enabled: false in config.yml).
    # The entries below exist so that tests/test-math.sh can verify the
    # symmetry "every camera in config.yml has a CAMERAS entry" (item 7
    # in the L2 test), and so the geometry is documented for the day
    # detection is enabled. The min_area / max_area / threshold / min_score
    # values match the L1 placeholder values in config.yml exactly (300 /
    # 100000 / 0.55 / 0.45); the geometry-derived margins are non-standard
    # (much < 0.5 for min, much < 1.0 for max) which is intentional —
    # the person is large in pixels in these small rooms even at the far
    # boundary, so a generous noise floor is the right operator choice.
    #
    # The PTZ motion-tracking caveat applies: at runtime the camera may
    # physically pan/tilt to follow a person, invalidating the static
    # mount orientation assumed by the physics formula. The fixed values
    # here are the DEFAULT orientation at boot; PTZ behaviour is the
    # Tapo device's own responsibility.
    # ===================================================================
    "salon": {
        # TP-Link Tapo C210, 5×7m living room, ceiling 2.5m, ~45° tilt, motion-tracking ON
        "dist_m":        6.0,
        "height_m":      2.5,
        "tilt_deg":     45.0,
        "v_fov_deg":    58.0,
        "h_fov_deg":   110.0,
        "stream_w_px": 2304,
        "stream_h_px": 1296,
        "near_m":        1.0,
        # Values mirror the L1 placeholder in config.yml (detection is off
        # per-camera, so these are documentation values not actual filters).
        "expected_min_area":   300,
        "expected_max_area": 100000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":         10,
        "detect_enabled":   False,  # motion-tracking ON; physics values are placeholders
        "expected_zones": {},
        # Margins are non-standard (very low) because the person is large
        # in pixels at the far boundary (area_far ≈ 24 875 px² for a 1.6m
        # person at 6m on 2304×1296 with 110° H-FOV / 58° V-FOV). min_area=300
        # is the iter0 noise-floor default; max_area=100000 ≈ 1.5× the
        # area at the near boundary of 1m (area_near ≈ 169 537 px²).
        "min_area_margin":     0.01206,   # = 300 / 24875
        "max_area_margin":     0.58984,   # = 100000 / 169537
        "detect_stream": "tapo_c210_salon_main",
        "live_stream":   "tapo_c210_salon_sub",
        # No zones — detection disabled, so no zone-based event filtering.
        "zones": [],
    },
    "buro": {
        # TP-Link Tapo C210, 3.5×2.5m small office, wall 1m, ~10° tilt, motion-tracking ON
        "dist_m":        3.5,
        "height_m":      1.0,
        "tilt_deg":     10.0,
        "v_fov_deg":    58.0,
        "h_fov_deg":   110.0,
        "stream_w_px": 2304,
        "stream_h_px": 1296,
        "near_m":        0.5,
        # Values mirror the L1 placeholder in config.yml (detection is off).
        "expected_min_area":   300,
        "expected_max_area": 100000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":         10,
        "detect_enabled":   False,  # motion-tracking ON; physics values are placeholders
        "expected_zones": {},
        # Low mount (1m) + small room (3.5m) → very large person footprint
        # even at the far boundary (area_far ≈ 92 765 px²). min_area=300 is
        # the iter0 noise-floor default (margin 0.00323 ≈ 300 / 92 765).
        "min_area_margin":     0.00323,
        "max_area_margin":     0.10170,
        "detect_stream": "tapo_c210_buro_main",
        "live_stream":   "tapo_c210_buro_sub",
        "zones": [],
    },
    "cuisine": {
        # TP-Link Tapo C210, 7×7m kitchen, ceiling 2.5m, ~45° tilt, motion-tracking ON
        "dist_m":        7.0,
        "height_m":      2.5,
        "tilt_deg":     45.0,
        "v_fov_deg":    58.0,
        "h_fov_deg":   110.0,
        "stream_w_px": 2304,
        "stream_h_px": 1296,
        "near_m":        1.0,
        # Values mirror the L1 placeholder in config.yml (detection is off).
        "expected_min_area":   300,
        "expected_max_area": 100000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "expected_fps":         10,
        "detect_enabled":   False,  # motion-tracking ON; physics values are placeholders
        "expected_zones": {},
        # 7m diagonal across a 7×7m room, 2.5m ceiling. area_far ≈ 18 170 px²
        # (smaller than salon because the room is larger), so min_area_margin
        # is 0.01651 (still low). max_area_margin is identical to salon
        # (0.58984) because both have the same near/far ratio.
        "min_area_margin":     0.01651,
        "max_area_margin":     0.58984,
        "detect_stream": "tapo_c210_cuisine_main",
        "live_stream":   "tapo_c210_cuisine_sub",
        "zones": [],
    },
}
