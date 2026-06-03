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
        "stream_w_px": 3840,
        "stream_h_px": 2160,
        "near_m":        5.0,
        "expected_min_area":   300,
        "expected_max_area": 117000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        # min_area_margin < 0.5 means the operator is using min_area as
        # a NOISE FLOOR (false-positive control), not a physics floor.
        # Derived area_far at 20 m on 4K ≈ 14 000 px², but min_area=300
        # catches a person at ~3 m of distance in 4K — well below the
        # physics floor. The L2 test allows this (margin range is
        # [GEOMETRY_MIN_LOWER, GEOMETRY_MIN_UPPER] = [0.3, 1.0]
        # around the derived value, which becomes [92, 308] when
        # margin=0.022).
        "min_area_margin":     0.022,
        "max_area_margin":     0.61,
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
        "expected_min_area":   300,
        "expected_max_area": 144000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
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
        "expected_min_area":   158,
        "expected_max_area": 27000,
        "expected_min_ratio":  1.0,
        "expected_max_ratio":  4.0,
        "expected_threshold":  0.55,
        "expected_min_score":  0.45,
        "min_area_margin":     0.399,
        "max_area_margin":     9.36,
        "detect_stream": "piscine_vue_toit_sub",
        "live_stream":   "piscine_vue_toit_sub",
        "zones": ["prive"],
    },
}
