#!/usr/bin/env python3
# ==============================================================================
# tests/iter0.py — iter0 default manager for Frigate camera detection params
# ==============================================================================
# Iter0 = the physics-derived detection parameters, computed once from each
# camera's mount geometry (see ARCHITECTURE.md §4.6). The authoritative
# manifest for iter0 lives in tests/camera_spec.py — this tool reads it
# and writes/inspects the corresponding block in config.yml.
#
# Subcommands:
#   show   <cam>      pretty-print the iter0 spec for one camera
#   diff   <cam>      show current config.yml vs iter0 (per key, exit 1 on drift)
#   revert <cam|all>  rewrite cameras.<cam> from the spec (preserves comments
#                     and all non-iter0 keys: ffmpeg, mqtt, live, motion.mask,
#                     zone coordinates, loitering_time, inertia, etc.)
#
# Round-trip preservation:
#   Uses ruamel.yaml (NOT PyYAML) so the 1100+ lines of physics-derivation
#   comments above each camera block survive the rewrite. The resulting
#   `git diff` of a revert is a tiny, surgical set of value changes —
#   no comment churn, no key reordering, no quote-style changes.
#
# What gets overwritten (and what doesn't):
#   OVERWRITTEN per camera:
#     detect.{width, height, fps}                  ← from stream_w/h_px + expected_fps
#     objects.filters.person.{min_area, max_area,
#                             min_ratio, max_ratio,
#                             threshold, min_score} ← from expected_* keys
#     zones.<name>.filters.person.*                 ← from expected_zones map
#   PRESERVED (never touched):
#     detect.enabled                                ← revert doesn't toggle on/off
#     ffmpeg, live, mqtt, snapshots, audio, motion
#     zone coordinates, loitering_time, inertia, objects
#     all hardware / mount-geometry comments above the camera block
#
# Safety:
#   `revert` always prints a diff first and prompts for y/N confirmation,
#   unless --yes is passed (the Makefile target uses --yes for non-interactive
#   use). Detection-disabled cameras (indoor Tapo) still get their placeholder
#   filter values rewritten — this is the only way to keep spec vs config
#   in lockstep — but detect.enabled is preserved.
#
# Install dependency (one-time):
#   pip3 install --user ruamel.yaml
# ==============================================================================
import argparse
import re
import sys
from pathlib import Path

try:
    from ruamel.yaml import YAML
except ImportError:
    sys.exit(
        "ruamel.yaml not installed.\n"
        "Install with:  pip3 install --user ruamel.yaml\n"
        "(required for round-trip YAML preservation — PyYAML would strip comments)"
    )

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tests"))
from camera_spec import CAMERAS  # noqa: E402

CONFIG_PATH = REPO_ROOT / "config.yml"

# Single, shared ruamel.yaml instance — comment-preserving round-trip.
# width=1e9 prevents ruamel from wrapping long inline sequences like the
# zone coordinates and motion.mask values (each of which is a single long
# line of comma-separated floats in config.yml). Without this, a no-op
# revert would still produce a 50-line diff because every `coordinates:`
# line gets wrapped to multi-line.
_yaml = YAML()
_yaml.preserve_quotes = True
_yaml.indent(mapping=2, sequence=4, offset=2)
_yaml.width = 1_000_000_000


# ------------------------------------------------------------------------------
# Iter0 derivation
# ------------------------------------------------------------------------------
def iter0_for(cam_name, spec):
    """Compute the iter0 values for a single camera.

    Returns a nested dict whose structure mirrors the iter0-managed subset
    of config.yml's cameras.<cam>:
        {
          "detect":  {"fps": ...},                # detection-fps, not stream geometry
          "objects": {"filters": {"person": {...6 keys...}}},
          "zones":   {<name>: {"filters": {"person": {...}}}, ...}
        }

    ITER0 SCOPE (the user-facing contract):
      INCLUDED (physics-derived detection parameters that the operator
      may need to hand-tune for reliability in various light / field
      conditions):
        - detect.fps
        - objects.filters.person.{min_area, max_area, min_ratio,
                                  max_ratio, threshold, min_score}
        - zones.<name>.filters.person.{threshold, min_area,
                                       min_ratio, max_ratio}
      EXCLUDED (deliberately left alone by iter0 — see git history for
      the discussion on 2026-06-03):
        - detect.width, detect.height   (stream resolution / geometry;
                                          changing them requires re-deriving
                                          the physics from scratch)
        - detect.enabled                (on/off toggle — manual decision)
        - objects.track                 (configuration choice: outdoor
                                          cameras re-affirm [person], indoor
                                          cameras set [] because detect is off)
        - zones.<name>.coordinates      (zone geometry — the user explicitly
                                          said this "will never change")
        - motion.mask                   (motion-mask geometry)
        - ffmpeg, live, mqtt, audio, snapshots
                                      (not detection parameters)
    """
    return {
        "detect": {
            "fps": spec["expected_fps"],
        },
        "objects": {
            "filters": {
                "person": {
                    "min_area":  spec["expected_min_area"],
                    "max_area":  spec["expected_max_area"],
                    "min_ratio": spec["expected_min_ratio"],
                    "max_ratio": spec["expected_max_ratio"],
                    "threshold": spec["expected_threshold"],
                    "min_score": spec["expected_min_score"],
                },
            },
        },
        "zones": {
            zname: {"filters": {"person": dict(zfilt)}}
            for zname, zfilt in spec.get("expected_zones", {}).items()
        },
    }


# ------------------------------------------------------------------------------
# Flatten / diff helpers
# ------------------------------------------------------------------------------
def _flatten(prefix, d, out):
    """Flatten a nested dict to dotted paths ('a.b.c' -> value)."""
    for k, v in d.items():
        path = f"{prefix}.{k}" if prefix else str(k)
        if isinstance(v, dict):
            _flatten(path, v, out)
        else:
            out[path] = v


def _actual_flat(cam_cfg):
    """Extract the iter0-relevant keys from a config.yml camera block.

    Only the keys that iter0 manages are included; everything else
    (ffmpeg, mqtt, motion, zone coordinates, etc.) is left alone and
    not diffed. For detection parameters that are NOT iter0-managed
    (detect.width / detect.height / detect.enabled / objects.track), use
    tests/test-math.sh which asserts the spec's stream_w_px / stream_h_px
    / detect_enabled — but iter0 does not write those values.
    """
    out = {}
    det = cam_cfg.get("detect") or {}
    if "fps" in det:
        out["detect.fps"] = det["fps"]
    pf = ((cam_cfg.get("objects") or {}).get("filters") or {}).get("person") or {}
    for k in ("min_area", "max_area", "min_ratio", "max_ratio", "threshold", "min_score"):
        if k in pf:
            out[f"objects.filters.person.{k}"] = pf[k]
    for zname, z in (cam_cfg.get("zones") or {}).items():
        zpf = ((z.get("filters") or {}).get("person") or {})
        for k, v in zpf.items():
            out[f"zones.{zname}.filters.person.{k}"] = v
    return out


def _diff_one(cam_name):
    """Return list of (key, iter0_value, actual_value) tuples for one camera.
    Empty list = camera matches iter0. Raises if the camera is unknown.
    """
    if cam_name not in CAMERAS:
        sys.exit(f"unknown camera '{cam_name}' (not in tests/camera_spec.py CAMERAS)")
    spec = CAMERAS[cam_name]
    iter0 = iter0_for(cam_name, spec)
    iter0_flat = {}
    _flatten("", iter0, iter0_flat)

    with open(CONFIG_PATH) as f:
        cfg = _yaml.load(f)
    cam_cfg = (cfg.get("cameras") or {}).get(cam_name)
    if not cam_cfg:
        sys.exit(
            f"camera '{cam_name}' is in tests/camera_spec.py but missing from "
            f"config.yml — add the cameras.{cam_name} block first, then run iter0 revert"
        )
    actual_flat = _actual_flat(cam_cfg)

    deltas = []
    for k in sorted(set(iter0_flat) | set(actual_flat)):
        iv = iter0_flat.get(k)
        av = actual_flat.get(k)
        if iv != av:
            deltas.append((k, iv, av))
    return deltas


# ------------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------------
def cmd_show(args):
    spec = CAMERAS[args.camera]
    it = iter0_for(args.camera, spec)
    g = f"dist={spec['dist_m']}m, h={spec['height_m']}m, tilt={spec['tilt_deg']}°, " \
        f"V-FOV={spec['v_fov_deg']}°, H-FOV={spec['h_fov_deg']}°"
    s = f"{spec['stream_w_px']}×{spec['stream_h_px']} @ {spec['expected_fps']}fps, " \
        f"detect_enabled={spec['detect_enabled']}"
    print(f"# iter0 spec for '{args.camera}'")
    print(f"# geometry: {g}")
    print(f"# stream:   {s}")
    print()
    print("detect:")
    print(f"  fps:    {it['detect']['fps']}    # iter0-managed (from expected_fps)")
    print(f"# detect.width/height are NOT iter0-managed (stream geometry,")
    print(f"#                          tied to the physics derivation in stream_w/h_px)")
    print(f"# detect.enabled is NOT iter0-managed (on/off toggle — manual decision)")
    print("objects:")
    print("  filters:")
    print("    person:")
    for k, v in it["objects"]["filters"]["person"].items():
        print(f"      {k}: {v}")
    # objects.track is not iter0-managed (see iter0_for docstring).
    print("# NOTE: objects.track is not iter0-managed (it's a config choice,")
    print("#       not a physics derivation: outdoor re-affirms [person],")
    print("#       indoor sets [] because detect.enabled is false).")
    if it["zones"]:
        print("zones:")
        for zname, zblock in it["zones"].items():
            print(f"  {zname}:")
            print("    filters:")
            print("      person:")
            for k, v in zblock["filters"]["person"].items():
                print(f"        {k}: {v}")
    else:
        print("# zones: <none> (detection disabled for this camera)")


def cmd_diff(args):
    deltas = _diff_one(args.camera)
    if not deltas:
        print(f"[OK] cameras.{args.camera} matches iter0 spec (no drift)")
        return 0
    print(f"[DRIFT] cameras.{args.camera} differs from iter0 spec in {len(deltas)} key(s):")
    width = max(len(k) for k, _, _ in deltas)
    for k, iv, av in deltas:
        ivs = "<unset>" if iv is None else repr(iv)
        avs = "<unset>" if av is None else repr(av)
        print(f"  {k.ljust(width)}  config.yml={avs}  iter0={ivs}")
    return 1


# ------------------------------------------------------------------------------
# Surgical text-based replacement for the revert step.
#
# Why not ruamel round-trip?  Even with _yaml.width=1e9, ruamel's emitter
# re-formats long multi-line sequences (the zone `coordinates:` blocks and
# `motion.mask:` values) into single-line flow sequences on dump. That makes
# the very first `iter0 revert` produce a 50-line `git diff` for what is
# semantically a 2-line change. The user explicitly excluded coordinates
# and motion masks from iter0, so we MUST preserve them byte-for-byte.
#
# Strategy: read config.yml as text, find the camera's text block, and for
# each iter0-managed key do a single-line regex replacement at the known
# indent. Everything else (comments, zone coordinates, motion.mask, ffmpeg,
# mqtt, etc.) is byte-identical to the input.
# ------------------------------------------------------------------------------


def _cam_span(text, cam):
    """Return (start, end) char offsets for the camera's text block.

    Block starts at the camera's `  <cam>:` line and ends at the next
    camera's `  <word>:` line, the next top-level key (indent 0), or EOF.
    """
    m = re.search(rf"^  {re.escape(cam)}:", text, re.MULTILINE)
    if not m:
        raise ValueError(f"camera '{cam}' not found in config.yml")
    start = m.start()
    after = text[start + 1:]
    nxt = re.match(r"^(?:  [a-z_]\w*:|[a-z_]\w*:)", after, re.MULTILINE)
    end = start + 1 + nxt.start() if nxt else len(text)
    return start, end


def _fmt_scalar(v):
    """Format a Python value as a YAML scalar (unquoted, no trailing space)."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        # Avoid 0.45 → 0.45000000000000005; print at full repr precision
        return repr(v) if v not in (0.0,) else "0.0"
    return str(v)


def _replace_value_on_line(block, indent, key, new_value):
    """Find the first line in `block` matching `<indent-spaces><key>: <value>`
    and replace the value with `new_value`. Returns (new_block, replaced).
    The line's leading whitespace, key, colon, and trailing comment (if any)
    are all preserved.
    """
    # Match: leading-spaces + key + colon + whitespace + value + (optional
    # trailing whitespace + inline comment) + newline-or-EOF
    pat = re.compile(
        rf"^( {{{indent}}})({re.escape(key)}:\s*)([^\n]*)",
        re.MULTILINE
    )
    m = pat.search(block)
    if not m:
        return block, False
    new_v = _fmt_scalar(new_value)
    new_line = f"{m.group(1)}{m.group(2)}{new_v}"
    return block[:m.start()] + new_line + block[m.end():], True


def _sub_block_span(block, header_indent, header_key):
    """Return (start, end) char offsets of the sub-block opened by
    `<header_indent-spaces><header_key>:` (a mapping).  The end is the
    next sibling line at the SAME indent, or EOF. Comments / blank lines
    within the sub-block don't affect the boundaries.
    """
    pat = re.compile(rf"^ {{{header_indent}}}{re.escape(header_key)}:\s*$", re.MULTILINE)
    m = pat.search(block)
    if not m:
        return None, None
    start = m.end()
    # Next line that starts with header_indent spaces + a non-blank, non-comment char
    nxt = re.search(rf"^ {{{header_indent}}}\S", block[start:], re.MULTILINE)
    end = start + nxt.start() if nxt else len(block)
    return start, end


def _apply_surgical_revert(text, cam, spec):
    """Apply iter0 revert to <cam>'s block using line-level text edits.
    Returns (new_text, n_changes). Touches ONLY iter0-managed lines; every
    other byte (zone coordinates, motion.mask, comments, ffmpeg, mqtt, …)
    is preserved exactly.
    """
    start, end = _cam_span(text, cam)
    block = text[start:end]
    n = 0

    # 1) detect.fps at indent 6 (under detect: at indent 4)
    block, ok = _replace_value_on_line(block, 6, "fps", spec["expected_fps"])
    n += int(ok)

    # 2) objects.filters.person.<6 keys> at indent 10, scoped to the
    #    `objects:` sub-block so we can't accidentally match a zone filter.
    obj_start, obj_end = _sub_block_span(block, 4, "objects")
    if obj_start is not None:
        obj_block = block[obj_start:obj_end]
        for k in ("min_area", "max_area", "min_ratio", "max_ratio",
                  "threshold", "min_score"):
            obj_block, ok = _replace_value_on_line(
                obj_block, 10, k, spec[f"expected_{k}"]
            )
            n += int(ok)
        block = block[:obj_start] + obj_block + block[obj_end:]

    # 3) zones.<zname>.filters.person.<4 keys> at indent 12, scoped to
    #    each zone's sub-block. If the spec defines a zone the config
    #    doesn't have, warn and skip (matches the ruamel-based behavior).
    for zname, zfilt in spec.get("expected_zones", {}).items():
        z_start, z_end = _sub_block_span(block, 6, zname)
        if z_start is None:
            print(
                f"[WARN] spec defines zone '{zname}' for '{cam}' but config.yml "
                f"is missing it; skipping (add the zone manually if needed)"
            )
            continue
        z_block = block[z_start:z_end]
        for k, v in zfilt.items():
            z_block, ok = _replace_value_on_line(z_block, 12, k, v)
            n += int(ok)
        block = block[:z_start] + z_block + block[z_end:]

    return text[:start] + block + text[end:], n


def cmd_revert(args):
    targets = list(CAMERAS.keys()) if args.camera == "all" else [args.camera]
    for cam in targets:
        if cam not in CAMERAS:
            sys.exit(f"unknown camera '{cam}' (not in tests/camera_spec.py CAMERAS)")

    # 1) Read config.yml as TEXT (not ruamel) so the surgical step
    #    below can edit single lines without re-serializing the rest.
    with open(CONFIG_PATH) as f:
        text = f.read()

    # 2) Pre-flight: every target must exist in config.yml
    for cam in targets:
        if _cam_span(text, cam)[0] is None:
            sys.exit(
                f"camera '{cam}' is in the spec but missing from config.yml — "
                f"add the cameras.{cam} block manually first, then run iter0 revert"
            )

    # 3) Always show the diff first (even for --yes — the operator needs to
    #    see what's about to change).
    any_drift = False
    for cam in targets:
        print(f"--- {cam} ---")
        rc = cmd_diff(argparse.Namespace(camera=cam))
        if rc != 0:
            any_drift = True
    if not any_drift:
        print()
        print("[OK] all targets already match iter0; nothing to do")
        return 0

    # 4) Confirm (unless --yes)
    print()
    if not args.yes:
        try:
            resp = input("Apply revert? This overwrites cameras.<cam> in config.yml. [y/N] ")
        except EOFError:
            print("aborted (no TTY)")
            return 1
        if resp.strip().lower() not in ("y", "yes"):
            print("aborted")
            return 1

    # 5) Apply surgical text replacement. For each target, only the
    #    iter0-managed lines are touched; everything else (including
    #    zone coordinates, motion.mask, and all comments) is byte-identical.
    total_changes = 0
    for cam in targets:
        spec = CAMERAS[cam]
        text, n = _apply_surgical_revert(text, cam, spec)
        print(f"[REVERT] cameras.{cam} → iter0 spec ({n} line(s) changed)")
        total_changes += n

    # 6) Write back
    with open(CONFIG_PATH, "w") as f:
        f.write(text)
    print(f"[OK] wrote {CONFIG_PATH} ({total_changes} line(s) total)")
    return 0


# ------------------------------------------------------------------------------
# CLI
# ------------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(
        prog="iter0",
        description=(
            "iter0 default manager for Frigate camera detection parameters. "
            "The spec in tests/camera_spec.py is the single source of truth; "
            "this tool reads it and rewrites (or inspects) the corresponding "
            "block in config.yml."
        ),
    )
    sp = ap.add_subparsers(dest="cmd", required=True, metavar="SUBCOMMAND")

    p_show = sp.add_parser("show", help="show iter0 spec for one camera")
    p_show.add_argument("camera", help="camera name (e.g. allee_sur_le_cote)")
    p_show.set_defaults(func=cmd_show)

    p_diff = sp.add_parser(
        "diff",
        help="show current config.yml vs iter0 (per key, exits 1 on drift)",
    )
    p_diff.add_argument("camera", help="camera name (or 'all')")
    p_diff.set_defaults(func=cmd_diff)

    p_revert = sp.add_parser(
        "revert",
        help="rewrite cameras.<cam> from the spec (preserves comments + non-iter0 keys)",
    )
    p_revert.add_argument("camera", help="camera name or 'all'")
    p_revert.add_argument(
        "--yes", "-y", action="store_true",
        help="skip the confirmation prompt (for scripts / Makefile)",
    )
    p_revert.set_defaults(func=cmd_revert)

    args = ap.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
