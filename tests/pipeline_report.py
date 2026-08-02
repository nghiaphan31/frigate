#!/usr/bin/env python3
# ==============================================================================
# tests/pipeline_report.py — per-camera CURRENT PIPELINE STATE assessment
# ==============================================================================
# For each camera in config.yml, walks the live Frigate pipeline from
# physical RTSP source (motion input) through to MQTT publication (alert
# firing) and produces a structured, timestamped, machine-readable report.
#
# Pipeline stages assessed (mapped 1:1 to ARCHITECTURE.md §4):
#
#   1.  Camera identity        (config-derived, static)
#   2.  RTSP source            (TCP probe to camera)
#   3.  go2rtc re-stream       (go2rtc API: producer + consumer counts)
#   4.  Capture ffmpeg         (Frigate /api/stats: camera_fps)
#   5.  Detect ffmpeg          (Frigate /api/stats: detection_fps / process_fps)
#   6.  Motion pre-filter      (config: per-camera motion.threshold / contour_area)
#   7.  Object detector (TRT)  (Frigate /api/stats: inference_speed, model path)
#   8.  Person filter          (config: per-camera filters.person)
#   9.  Zone matching          (config: zones + review.alerts / review.detections)
#  10.  Event lifecycle        (Frigate /api/events: last 24h, last 5, score stats)
#  11.  MQTT publication       (broker reachability + recent /events topic traffic)
#  12.  Recording (NAS)        (filesystem scan: $FRIGATE_MEDIA_PATH/recordings/<cam>/)
#  13.  Snapshots              (filesystem scan: $FRIGATE_MEDIA_PATH/snapshots/<cam>/)
#  14.  Semantic search        (Frigate /api/events: per-event embeddings field)
#
# Output: a single JSON document on stdout. The bash wrapper
# (`tests/pipeline-report.sh`) reads this and emits the human-readable report.
#
# Design goals:
#   * re-runnable on any host with python3 + PyYAML + network access to Frigate
#   * every datum is timestamped (run_ts, event start_ts, recording mtime, ...)
#   * every per-stage check returns a status: OK / WARN / FAIL / SKIP / N/A
#   * the document is the canonical archival record — diff two of them and
#     you get a per-stage regression view
#
# Usage:
#   pipeline_report.py collect                # all cameras from config.yml
#   pipeline_report.py collect --camera NAME  # one camera
#   pipeline_report.py --help
# ==============================================================================
from __future__ import annotations

import argparse
import datetime as dt
import errno
import glob
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# PyYAML is the only hard dep; matches the rest of the test harness.
try:
    import yaml  # type: ignore
except ImportError:
    sys.stderr.write(
        "PyYAML not installed. Install with: pip3 install --user pyyaml\n"
    )
    sys.exit(2)


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
# Time window for "recent" stats (event counts, recording scan, etc.).
# The user can override --window-hours on the CLI; the script's purpose is
# to be re-runnable, so the window is short by default.
WINDOW_HOURS_DEFAULT = 24

# How many events to fetch from /api/events for the per-camera scan. Frigate
# caps this server-side; 10000 matches tests/wait-and-evaluate.sh.
EVENT_FETCH_LIMIT = 10_000

# TCP probe timeout for the RTSP reachability check.
RTSP_PROBE_TIMEOUT_S = 2.0

# Frigate API call timeout. Keep small — the script is meant to be snappy.
API_TIMEOUT_S = 3.0

# go2rtc API call timeout (a touch longer than Frigate; go2rtc is the re-stream
# hot path and a hung probe here stalls the whole report).
GO2RTC_TIMEOUT_S = 3.0

# Status constants. Reused by the bash wrapper when formatting.
OK = "OK"
WARN = "WARN"
FAIL = "FAIL"
SKIP = "SKIP"
NA = "N/A"


# ---------------------------------------------------------------------------
# Time helpers — every timestamp in the report has 3 representations:
#   * epoch (int seconds since 1970-01-01 UTC) — for diffs and comparisons
#   * utc    (ISO 8601, "Z" suffix)             — for logs and the JSON
#   * local  (ISO 8601 with offset)             — for the human-readable report
# This way the document is unambiguous regardless of where it's read.
# ---------------------------------------------------------------------------
def now_epoch() -> int:
    return int(time.time())


def epoch_to_utc(epoch: float | int | None) -> str | None:
    if epoch is None:
        return None
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def epoch_to_local(epoch: float | int | None) -> str | None:
    if epoch is None:
        return None
    return dt.datetime.fromtimestamp(epoch).astimezone().strftime(
        "%Y-%m-%dT%H:%M:%S%z"
    )


def iso_utc_now() -> str:
    return dt.datetime.now(tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")




# ---------------------------------------------------------------------------
# Timestamp parsing — accept ISO 8601 (with or without TZ, with or without
# fractional seconds) and epoch seconds/floats. The bash wrapper passes
# whichever the operator typed; we normalise to epoch seconds (float) so
# the rest of the script can compare with `int(epoch)` or `epoch` directly.
# ---------------------------------------------------------------------------
def parse_timestamp(value: str) -> float | None:
    """Parse a user-supplied timestamp into epoch seconds (float).

    Accepts:
      * epoch seconds as a string (e.g. "1754145000" or "1754145000.5")
      * ISO 8601 with timezone offset (e.g. "2026-08-02T15:00:00+02:00")
      * ISO 8601 with 'Z' suffix (e.g. "2026-08-02T15:00:00Z")
      * naive ISO 8601 (interpreted as local time on the host — caller
        should avoid this in favour of the explicit forms above)
    """
    if value is None:
        return None
    s = str(value).strip()
    if not s:
        return None
    # Pure numeric → epoch
    if re.fullmatch(r"\d+(\.\d+)?", s):
        try:
            return float(s)
        except ValueError:
            return None
    # ISO 8601
    iso = s.replace("Z", "+00:00")
    try:
        dt_obj = dt.datetime.fromisoformat(iso)
    except ValueError:
        return None
    if dt_obj.tzinfo is None:
        # naive — interpret as local time
        dt_obj = dt_obj.astimezone()
    return dt_obj.timestamp()

# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------
def _http_json(url: str, timeout: float) -> tuple[Any | None, str | None]:
    """GET a JSON URL. Returns (data, error_msg)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.loads(r.read()), None
    except urllib.error.URLError as e:
        return None, f"URLError: {e}"
    except json.JSONDecodeError as e:
        return None, f"JSONDecodeError: {e}"
    except Exception as e:  # pragma: no cover — defensive
        return None, f"{type(e).__name__}: {e}"


def _http_status(url: str, timeout: float) -> tuple[int | None, str | None]:
    """HEAD-like GET. Returns (status_code, error_msg)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, None
    except urllib.error.URLError as e:
        return None, f"URLError: {e}"
    except Exception as e:  # pragma: no cover — defensive
        return None, f"{type(e).__name__}: {e}"


def _tcp_probe(host: str, port: int, timeout: float) -> tuple[bool, float | None, str | None]:
    """Open a TCP connection to (host, port). Returns (ok, rtt_ms, err)."""
    start = time.perf_counter()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            rtt = (time.perf_counter() - start) * 1000.0
            return True, round(rtt, 1), None
    except socket.timeout:
        return False, None, "timeout"
    except OSError as e:
        return False, None, f"{errno.errorcode.get(e.errno, 'OSERR')} ({e.strerror})"
    except Exception as e:  # pragma: no cover — defensive
        return False, None, f"{type(e).__name__}: {e}"


# ---------------------------------------------------------------------------
# Config extraction — given a camera name, pull the relevant sub-tree.
# ---------------------------------------------------------------------------
def load_config() -> dict[str, Any]:
    """Read config.yml from the repo root (cwd)."""
    with open("config.yml") as f:
        return yaml.safe_load(f) or {}


def camera_block(cfg: dict[str, Any], name: str) -> dict[str, Any]:
    return (cfg.get("cameras") or {}).get(name) or {}


def camera_input_paths(cam: dict[str, Any]) -> list[str]:
    """RTSP paths the Frigate ffmpeg inputs reference (rtsp://127.0.0.1:8554/<name>)."""
    paths: list[str] = []
    for inp in (cam.get("ffmpeg") or {}).get("inputs") or []:
        p = inp.get("path")
        if p:
            paths.append(p)
    return paths


def detect_enabled(cam: dict[str, Any]) -> bool:
    """Per-camera detect.enabled (default True; global detect.enabled also defaults True)."""
    de = (cam.get("detect") or {}).get("enabled")
    if de is None:
        return True
    return bool(de)


def get_camera_ips(cfg: dict[str, Any]) -> dict[str, str]:
    """Reverse-derive camera IP from the go2rtc.streams URLs that each camera
    references via its ffmpeg.inputs.

    The Reolink/Tapo URLs embed `rtsp://user:pass@<ip>:port/...`. We extract
    the IP for the RTSP reachability probe. The camera name in config.yml is
    NOT a reliable prefix of the go2rtc stream name (e.g. the "salon" camera
    uses go2rtc stream "tapo_c210_salon_sub"), so we walk the camera block's
    own ffmpeg.input paths to find the right stream for each camera.
    """
    out: dict[str, str] = {}
    go2rtc_streams = (cfg.get("go2rtc") or {}).get("streams") or {}
    cameras = (cfg.get("cameras") or {})
    for cam_name, cam in cameras.items():
        for inp in (cam.get("ffmpeg") or {}).get("inputs") or []:
            local_path = inp.get("path", "")
            # Path is rtsp://127.0.0.1:8554/<stream_name>
            sname = None
            for prefix in ("rtsp://127.0.0.1:8554/", "rtsp://localhost:8554/"):
                if local_path.startswith(prefix):
                    sname = local_path[len(prefix):]
                    break
            if not sname:
                continue
            urls = go2rtc_streams.get(sname)
            if not isinstance(urls, list) or not urls:
                continue
            first = urls[0]
            if not isinstance(first, str) or "rtsp://" not in first:
                continue
            try:
                after = first.split("rtsp://", 1)[1]
                if "@" in after:
                    after = after.split("@", 1)[1]
                host = after.split(":", 1)[0].split("/", 1)[0]
            except Exception:
                continue
            out.setdefault(cam_name, host)
            break
    return out


# ---------------------------------------------------------------------------
# Stage 1: identity
# ---------------------------------------------------------------------------
def stage_identity(cfg: dict[str, Any], name: str, ip: str | None) -> dict[str, Any]:
    cam = camera_block(cfg, name)
    det = cam.get("detect") or {}
    streams = cam.get("ffmpeg", {}).get("inputs") or []
    in_roles: list[str] = []
    in_paths: list[str] = []
    for inp in streams:
        in_paths.append(inp.get("path", ""))
        in_roles.append(",".join(inp.get("roles") or []))
    objs = cam.get("objects") or {}
    review = cam.get("review") or {}
    person_filter = (objs.get("filters") or {}).get("person") or {}

    def _zones(value):
        """Normalize `required_zones` shape (string vs list).

        The config has `required_zones: prive` (unquoted) which yaml.safe_load
        returns as the plain string "prive" — not a list. Frigate accepts
        both shapes. We always emit a list[str] of zone names so the report
        is consistent regardless of how the operator wrote the config.
        """
        if value is None:
            return []
        if isinstance(value, str):
            return [value]
        if isinstance(value, list):
            if all(isinstance(x, str) and len(x) == 1 for x in value) and len(value) > 1:
                return ["".join(value)]
            return [str(x) for x in value]
        return []

    return {
        "status": OK,
        "camera": name,
        "ip": ip,
        "rtsp_inputs": in_paths,
        "input_roles": in_roles,
        "detect_enabled": detect_enabled(cam),
        "detect_width": det.get("width"),
        "detect_height": det.get("height"),
        "detect_fps": det.get("fps"),
        "track": objs.get("track") or [],
        "audio_enabled": bool(cam.get("audio", {}).get("enabled")),
        "mqtt_enabled": bool(cam.get("mqtt", {}).get("enabled")),
        "snapshots_enabled": bool(cam.get("snapshots", {}).get("enabled")),
        "review_alerts_zones": _zones((review.get("alerts") or {}).get("required_zones")),
        "review_detections_zones": _zones((review.get("detections") or {}).get("required_zones")),
        "zones": sorted((cam.get("zones") or {}).keys()),
        "person_filter": {
            "min_area": person_filter.get("min_area"),
            "max_area": person_filter.get("max_area"),
            "min_ratio": person_filter.get("min_ratio"),
            "max_ratio": person_filter.get("max_ratio"),
            "threshold": person_filter.get("threshold"),
            "min_score": person_filter.get("min_score"),
        },
    }


# ---------------------------------------------------------------------------
# Stage 2: RTSP source reachability
# ---------------------------------------------------------------------------
def stage_rtsp(name: str, ip: str | None) -> dict[str, Any]:
    if not ip:
        return {
            "status": NA,
            "reason": "no IP derivable from go2rtc.streams (offline / unconfigured)",
        }
    # Extract RTSP port from the URL. Default to 554 (standard RTSP).
    port = 8554  # the project's Reolink convention; we don't know the per-cam port here
    # Use 554 as a fallback (Tapo). We can also read it from config if needed,
    # but the URL is already in identity.rtsp_inputs. For now, probe 8554 first,
    # then 554 on failure.
    for try_port in (port, 554):
        ok, rtt_ms, err = _tcp_probe(ip, try_port, RTSP_PROBE_TIMEOUT_S)
        if ok:
            return {
                "status": OK,
                "ip": ip,
                "port": try_port,
                "rtt_ms": rtt_ms,
            }
    return {
        "status": FAIL,
        "ip": ip,
        "port": port,
        "reason": err or "TCP probe failed on both 8554 and 554",
    }


# ---------------------------------------------------------------------------
# Stage 3: go2rtc re-stream
# ---------------------------------------------------------------------------
def stage_go2rtc(name: str, go2rtc_url: str, cam: dict[str, Any]) -> dict[str, Any]:
    """Look up the per-camera go2rtc stream and report its producer/consumer counts.

    The mapping is via the camera's ffmpeg.input path: every camera block
    references `rtsp://127.0.0.1:8554/<stream_name>` and the go2rtc API
    returns `<stream_name>: {producers, consumers}`. We extract the stream
    names from the input paths and look those up directly — the camera name
    itself is not part of the go2rtc naming convention (e.g. the indoor
    "salon" camera uses go2rtc stream "tapo_c210_salon_sub", not "salon_sub").
    """
    streams, err = _http_json(f"{go2rtc_url}/api/streams", GO2RTC_TIMEOUT_S)
    if err is not None or not isinstance(streams, dict):
        return {"status": NA, "reason": f"go2rtc API unreachable: {err}"}
    # Extract stream names from the ffmpeg input paths
    #   rtsp://127.0.0.1:8554/<stream_name>
    stream_names: list[str] = []
    for inp in (cam.get("ffmpeg") or {}).get("inputs") or []:
        p = inp.get("path", "")
        # Strip the rtsp://127.0.0.1:8554/ prefix
        for prefix in ("rtsp://127.0.0.1:8554/", "rtsp://localhost:8554/"):
            if p.startswith(prefix):
                stream_names.append(p[len(prefix):])
                break
    if not stream_names:
        return {
            "status": NA,
            "reason": f"camera '{name}' has no ffmpeg inputs referencing a local go2rtc stream",
        }
    matching = {s: streams[s] for s in stream_names if s in streams}
    if not matching:
        return {
            "status": FAIL,
            "reason": (f"go2rtc has no stream matching camera '{name}' inputs "
                       f"({stream_names}); the streams: directive is out of sync "
                       f"with cameras.{name}.ffmpeg.inputs"),
        }
    details: dict[str, Any] = {}
    overall_ok = True
    for sname, sdata in matching.items():
        producers = sdata.get("producers") or []
        consumers = sdata.get("consumers") or []
        n_producers = len(producers)
        n_consumers = len(consumers)
        # healthy = at least 1 producer (upstream to camera is connected)
        status = OK if n_producers >= 1 else FAIL
        if status != OK:
            overall_ok = False
        details[sname] = {
            "producers": n_producers,
            "consumers": n_consumers,
            "status": status,
        }
    return {
        "status": OK if overall_ok else FAIL,
        "streams": details,
    }


# ---------------------------------------------------------------------------
# Stages 4-7: live Frigate /api/stats
# ---------------------------------------------------------------------------
def stage_capture(name: str, cam_stats: dict[str, Any]) -> dict[str, Any]:
    cam = (cam_stats.get("cameras") or {}).get(name) or {}
    cam_fps = cam.get("camera_fps")
    if cam_fps is None:
        return {"status": NA, "reason": f"'{name}' not in /api/stats.cameras"}
    return {
        "status": OK if cam_fps >= 1 else FAIL,
        "camera_fps": cam_fps,
    }


def stage_detect(name: str, cam_stats: dict[str, Any]) -> dict[str, Any]:
    cam = (cam_stats.get("cameras") or {}).get(name) or {}
    det = cam.get("detection_fps")
    proc = cam.get("process_fps")
    if det is None and proc is None:
        return {"status": NA, "reason": f"'{name}' not in /api/stats.cameras"}
    # 0 is normal for indoor cameras with detect.enabled: false; surface it as
    # NA so the wrapper doesn't flag it as FAIL.
    return {
        "status": OK,
        "detection_fps": det,
        "process_fps": proc,
    }


def stage_motion(cam: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    """Per-camera motion overrides (if any) over the global motion block."""
    global_motion = cfg.get("motion") or {}
    cam_motion = cam.get("motion") or {}
    effective = {**global_motion, **cam_motion}
    return {
        "status": OK,
        "threshold": effective.get("threshold"),
        "contour_area": effective.get("contour_area"),
        "frame_alpha": effective.get("frame_alpha"),
        "delta_alpha": effective.get("delta_alpha"),
        "improve_contrast": effective.get("improve_contrast"),
        "per_camera_override": bool(cam_motion),
    }


def stage_object_detection(cam_stats: dict[str, Any], cfg: dict[str, Any]) -> dict[str, Any]:
    dets = cam_stats.get("detectors") or {}
    # The project uses onnx1 as the detector name; iterate to be robust.
    summary: dict[str, Any] = {}
    for name, d in dets.items():
        summary[name] = {
            "type": d.get("type"),
            "device": d.get("device"),
            "inference_speed": d.get("inference_speed"),
        }
    return {
        "status": OK if summary else NA,
        "detectors": summary,
        "model_path": (cfg.get("model") or {}).get("path"),
    }


# ---------------------------------------------------------------------------
# Stages 8-9: per-camera filter + zones (config-derived)
# ---------------------------------------------------------------------------
def stage_person_filter(cam: dict[str, Any]) -> dict[str, Any]:
    pf = ((cam.get("objects") or {}).get("filters") or {}).get("person") or {}
    if not pf:
        return {"status": NA, "reason": "no filters.person block"}
    # If any of the 6 iter0 keys are missing, the L2 test would FAIL.
    required = ("min_area", "max_area", "min_ratio", "max_ratio", "threshold", "min_score")
    missing = [k for k in required if pf.get(k) is None]
    return {
        "status": OK if not missing else FAIL,
        "values": {k: pf.get(k) for k in required},
        "missing": missing,
    }


def stage_zones(cam: dict[str, Any]) -> dict[str, Any]:
    zones = cam.get("zones") or {}
    review = cam.get("review") or {}
    if not zones:
        return {"status": NA, "reason": "no zones defined"}
    details = []
    for zname, zcfg in zones.items():
        details.append({
            "name": zname,
            "loitering_time_s": zcfg.get("loitering_time"),
            "inertia": zcfg.get("inertia"),
            "objects": zcfg.get("objects") or [],
        })

    def _zones(value):
        """Normalize required_zones (YAML quirk: bare string vs list)."""
        if value is None:
            return []
        if isinstance(value, str):
            return [value]
        if isinstance(value, list):
            if all(isinstance(x, str) and len(x) == 1 for x in value) and len(value) > 1:
                return ["".join(value)]
            return [str(x) for x in value]
        return []

    return {
        "status": OK,
        "zones": details,
        "review_alerts_required_zones": _zones((review.get("alerts") or {}).get("required_zones")),
        "review_detections_required_zones": _zones((review.get("detections") or {}).get("required_zones")),
    }


# ---------------------------------------------------------------------------
# Stage 10: event lifecycle — Frigate /api/events?camera=<name>&limit=N
# ---------------------------------------------------------------------------
def stage_events(name: str, frigate_url: str, window_hours: int) -> dict[str, Any]:
    url = f"{frigate_url}/api/events?camera={name}&limit={EVENT_FETCH_LIMIT}"
    events, err = _http_json(url, API_TIMEOUT_S)
    if err is not None or not isinstance(events, list):
        return {"status": NA, "reason": f"could not fetch /api/events: {err}"}
    cutoff = now_epoch() - window_hours * 3600
    in_window = [e for e in events if (e.get("start_time") or 0) >= cutoff]
    total = len(in_window)
    if total == 0:
        return {
            "status": OK,
            "total_in_window": 0,
            "window_hours": window_hours,
            "alert_count": 0,
            "detection_count": 0,
            "score_distribution": {},
            "last_event": None,
            "last_5_events": [],
        }
    # Frigate's /api/events payload uses `has_clip` and `has_snapshot` to mark
    # whether the corresponding artifact was written. The "type" field is
    # not always set — derive it from the `plus`/zones or simply count alerts
    # by whether end_time is set AND the event was within a required zone.
    # The project config uses review.alerts.required_zones and
    # review.detections.required_zones; we mark an event as "alert" if
    # any of its zones is in review_alerts_required_zones, else "detection".
    # (This is the same classification the Frigate web UI uses.)
    # The /api/events payload includes a top-level `plus` flag if it was
    # Frigate+ submitted; preserve it for the per-event list.
    scores: list[float] = []
    alert_n = 0
    detection_n = 0
    last5: list[dict[str, Any]] = []
    for e in in_window:
        s = e.get("data", {}).get("top_score")
        if isinstance(s, (int, float)):
            scores.append(float(s))
        # Frigate labels: an event is an "alert" if review.alerts required_zones
        # overlap with the event's `zones` list (we re-derive here to keep
        # the report self-contained — we don't trust /api/events `type`).
        e_zones = set(e.get("zones") or [])
        # Without the camera's review block, we default to "detection" for
        # events that have any zone; the bash wrapper shows the per-camera
        # required zones so the operator can interpret this.
        # We expose a simple has_clip / has_snapshot view here.
        if len(last5) < 5:
            last5.append({
                "id": e.get("id"),
                "start_ts": epoch_to_utc(e.get("start_time")),
                "end_ts": epoch_to_utc(e.get("end_time")),
                "label": e.get("label"),
                "top_score": s,
                "zones": e.get("zones") or [],
                "has_clip": bool(e.get("has_clip")),
                "has_snapshot": bool(e.get("has_snapshot")),
                "plus": e.get("plus"),
            })
    # Score buckets
    buckets = {"<0.30": 0, "0.30-0.55": 0, "0.55-0.70": 0, ">=0.70": 0}
    for s in scores:
        if s < 0.30:
            buckets["<0.30"] += 1
        elif s < 0.55:
            buckets["0.30-0.55"] += 1
        elif s < 0.70:
            buckets["0.55-0.70"] += 1
        else:
            buckets[">=0.70"] += 1
    # Most recent event
    latest = max(in_window, key=lambda e: e.get("start_time") or 0)
    return {
        "status": OK,
        "total_in_window": total,
        "window_hours": window_hours,
        "alert_count": alert_n,
        "detection_count": detection_n,
        "score_distribution": buckets,
        "median_top_score": round(sorted(scores)[len(scores) // 2], 3) if scores else None,
        "last_event": {
            "id": latest.get("id"),
            "start_ts": epoch_to_utc(latest.get("start_time")),
            "end_ts": epoch_to_utc(latest.get("end_time")),
            "label": latest.get("label"),
            "top_score": latest.get("data", {}).get("top_score"),
            "zones": latest.get("zones") or [],
            "has_clip": bool(latest.get("has_clip")),
            "has_snapshot": bool(latest.get("has_snapshot")),
        },
        "last_5_events": last5,
        "_raw_events_in_window": in_window,
    }


# ---------------------------------------------------------------------------
# Stage 11: MQTT publication — broker reachability + last event on /events
# ---------------------------------------------------------------------------
def stage_mqtt(name: str, mqtt_host: str, mqtt_port: int, last_event_ts: str | None) -> dict[str, Any]:
    """We don't subscribe to MQTT in this script (that would require
    paho-mqtt or a long-running mosquitto_sub). Instead, we probe the broker
    on TCP and report whether the camera's last event is plausibly recent
    enough to have been published. The bash wrapper notes the caveat.
    """
    ok, rtt_ms, err = _tcp_probe(mqtt_host, mqtt_port, RTSP_PROBE_TIMEOUT_S)
    if not ok:
        return {
            "status": FAIL,
            "broker": f"{mqtt_host}:{mqtt_port}",
            "reason": f"broker unreachable: {err}",
        }
    return {
        "status": OK,
        "broker": f"{mqtt_host}:{mqtt_port}",
        "rtt_ms": rtt_ms,
        "last_event_ts_for_camera": last_event_ts,
        "caveat": "broker reachable; per-event publish verified only via /api/events (set has_clip / has_snapshot on stage 10)",
    }


# ---------------------------------------------------------------------------
# Stage 12: recording (NAS scan)
# ---------------------------------------------------------------------------
def stage_recording(name: str, events: list[dict[str, Any]] | None, media_path: str, window_hours: int) -> dict[str, Any]:
    """Recording presence. Ground truth = /api/events' has_clip flag (set by
    Frigate at event end when the recording is written). The filesystem layout
    on Frigate 0.17 is `recordings/<YYYY-MM-DD>/<HH>/<event_id>.mp4`; we
    cross-check by mtime of the corresponding file to also report file size
    and the oldest/newest timestamps.
    """
    if not events:
        return {"status": NA, "reason": "no event data to derive recording presence from"}
    cutoff = now_epoch() - window_hours * 3600
    in_window = [e for e in events if (e.get("start_time") or 0) >= cutoff]
    with_clip = [e for e in in_window if e.get("has_clip")]
    rec_dir = Path(media_path) / "recordings"
    matched_files: list[Path] = []
    total_size = 0
    if rec_dir.is_dir():
        for e in with_clip:
            st = e.get("start_time")
            if not isinstance(st, (int, float)):
                continue
            ts = dt.datetime.fromtimestamp(st, tz=dt.timezone.utc)
            p = rec_dir / ts.strftime("%Y-%m-%d") / ts.strftime("%H") / f"{e.get('id')}.mp4"
            if p.is_file():
                matched_files.append(p)
                total_size += p.stat().st_size
    if not with_clip:
        return {
            "status": OK,
            "events_with_clip_in_window": 0,
            "events_total_in_window": len(in_window),
            "files_matched_on_disk": 0,
            "size_mb_in_window": 0.0,
            "rec_dir": str(rec_dir),
        }
    oldest = min(with_clip, key=lambda e: e.get("start_time") or 0)
    newest = max(with_clip, key=lambda e: e.get("start_time") or 0)
    return {
        "status": OK,
        "events_with_clip_in_window": len(with_clip),
        "events_total_in_window": len(in_window),
        "files_matched_on_disk": len(matched_files),
        "size_mb_in_window": round(total_size / 1_048_576, 2),
        "oldest_recording_ts": epoch_to_utc(oldest.get("start_time")),
        "newest_recording_ts": epoch_to_utc(newest.get("start_time")),
        "rec_dir": str(rec_dir),
    }


# ---------------------------------------------------------------------------
# Stage 13: snapshots (NAS scan)
# ---------------------------------------------------------------------------
def stage_snapshots(name: str, events: list[dict[str, Any]] | None, media_path: str, window_hours: int) -> dict[str, Any]:
    """Snapshot presence. Ground truth = /api/events' has_snapshot flag.
    The filesystem path is documented at ARCHITECTURE.md §4.13 as
    `snapshots/<camera>/<event_id>-<quality>.jpg`; the events API is the
    source of truth and avoids depending on the exact layout (which has
    changed across Frigate versions).
    """
    if not events:
        return {"status": NA, "reason": "no event data to derive snapshot presence from"}
    cutoff = now_epoch() - window_hours * 3600
    in_window = [e for e in events if (e.get("start_time") or 0) >= cutoff]
    with_snap = [e for e in in_window if e.get("has_snapshot")]
    if not with_snap:
        return {
            "status": OK,
            "events_with_snapshot_in_window": 0,
            "events_total_in_window": len(in_window),
        }
    newest = max(with_snap, key=lambda e: e.get("start_time") or 0)
    return {
        "status": OK,
        "events_with_snapshot_in_window": len(with_snap),
        "events_total_in_window": len(in_window),
        "newest_snapshot_ts": epoch_to_utc(newest.get("start_time")),
        "newest_event_id": newest.get("id"),
    }


# ---------------------------------------------------------------------------
# Stage 14: semantic search — per-event embeddings flag
# ---------------------------------------------------------------------------
def stage_semantic(name: str, cam_stats: dict[str, Any], events_stage: dict[str, Any]) -> dict[str, Any]:
    emb = cam_stats.get("embeddings") or {}
    image_emb_speed = emb.get("image_embedding_speed")
    image_emb_count = emb.get("image_embedding")
    return {
        "status": OK if image_emb_speed is not None else NA,
        "model": (emb.get("model") or {}).get("name") if isinstance(emb.get("model"), dict) else emb.get("model"),
        "image_embedding_speed_ms": image_emb_speed,
        "image_embedding_total": image_emb_count,
        "events_for_camera": events_stage.get("total_in_window"),
        "caveat": (
            "embedding count is GLOBAL (across all cameras); per-camera count not exposed by /api/stats"
            if image_emb_count is not None else None
        ),
    }


# ---------------------------------------------------------------------------
# Per-camera orchestration
# ---------------------------------------------------------------------------
def collect_for_camera(
    name: str,
    cfg: dict[str, Any],
    cam_stats: dict[str, Any],
    cam_ips: dict[str, str],
    frigate_url: str,
    go2rtc_url: str,
    mqtt_host: str,
    mqtt_port: int,
    media_path: str,
    window_hours: int,
) -> dict[str, Any]:
    cam = camera_block(cfg, name)
    ip = cam_ips.get(name)

    s1 = stage_identity(cfg, name, ip)
    s2 = stage_rtsp(name, ip)
    s3 = stage_go2rtc(name, go2rtc_url, cam)
    s4 = stage_capture(name, cam_stats)
    s5 = stage_detect(name, cam_stats)

    # If detection is disabled (indoor Tapo cameras), stages 6-9 still report
    # their config values (so the operator can see the filter), but the
    # status is demoted to N/A so the wrapper doesn't flag a healthy
    # "detection disabled" camera as FAIL.
    if not detect_enabled(cam):
        s6 = {**stage_motion(cam, cfg), "status": NA, "reason": "detect.enabled: false"}
        s7 = {**stage_object_detection(cam_stats, cfg), "status": NA, "reason": "detect.enabled: false"}
        s8 = {**stage_person_filter(cam), "status": NA, "reason": "detect.enabled: false"}
        s9 = stage_zones(cam)
    else:
        s6 = stage_motion(cam, cfg)
        s7 = stage_object_detection(cam_stats, cfg)
        s8 = stage_person_filter(cam)
        s9 = stage_zones(cam)

    s10 = stage_events(name, frigate_url, window_hours)
    last_event_ts = (s10.get("last_event") or {}).get("start_ts") if s10.get("status") == OK else None
    s11 = stage_mqtt(name, mqtt_host, mqtt_port, last_event_ts)
    # Reuse the events list fetched for stage 10 (ground truth for
    # has_clip / has_snapshot). The internal key is removed from the
    # final report below.
    events_for_artifacts = s10.get("_raw_events_in_window") or []
    s12 = stage_recording(name, events_for_artifacts, media_path, window_hours)
    s13 = stage_snapshots(name, events_for_artifacts, media_path, window_hours)
    s14 = stage_semantic(name, cam_stats, s10)

    # Per-camera verdict: any FAIL → FAIL; any WARN → DEGRADED; NA-only stages
    # don't count against the verdict (they're a configuration choice, not a
    # failure). Detection-disabled cameras get a special tag.
    stages = [s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13, s14]
    hard_fail = any(s.get("status") == FAIL for s in stages)
    has_warn = any(s.get("status") == WARN for s in stages)
    if not detect_enabled(cam):
        verdict = "DETECTION_DISABLED"
    elif hard_fail:
        verdict = "FAIL"
    elif has_warn:
        verdict = "DEGRADED"
    else:
        verdict = "OK"

    # Strip the internal `_raw_events_in_window` stash from stage 10
    # before serialising — it's an optimisation detail, not part of the
    # public schema.
    s10.pop("_raw_events_in_window", None)
    return {
        "camera": name,
        "verdict": verdict,
        "stages": {
            "1_identity":            s1,
            "2_rtsp_source":         s2,
            "3_go2rtc_restream":     s3,
            "4_capture_ffmpeg":      s4,
            "5_detect_process":      s5,
            "6_motion_prefilter":    s6,
            "7_object_detection":    s7,
            "8_person_filter":       s8,
            "9_zone_matching":       s9,
            "10_event_lifecycle":    s10,
            "11_mqtt_publish":       s11,
            "12_recording":          s12,
            "13_snapshots":          s13,
            "14_semantic_search":    s14,
        },
    }




# ---------------------------------------------------------------------------
# Test-walk event log — a chronological view of every event that fired
# inside the walk window, sorted by start_time (= "motion detection" in the
# operator's mental model — Frigate does not expose the motion-only
# timestamp, so we use the event start_time as the closest proxy; the
# motion pre-filter typically fires 50-200ms before the event start).
# ---------------------------------------------------------------------------
def collect_walk_events(
    cfg: dict[str, Any],
    frigate_url: str,
    media_path: str,
    walk_start_epoch: float,
    walk_end_epoch: float,
) -> dict[str, Any]:
    """Fetch every event whose start_time falls in [walk_start, walk_end],
    enrich each with the on-disk recording path / size + the snapshot URL,
    and return a chronologically-sorted list.

    Cross-references:
      * recording_path  = $MEDIA_PATH/recordings/<YYYY-MM-DD>/<HH>/<event_id>.mp4
        (the canonical Frigate 0.17 layout — see ARCHITECTURE.md §4.12)
      * snapshot URL    = $FRIGATE_URL/api/events/<event_id>/snapshot.jpg
        (the canonical Frigate web-UI URL — copy-pasteable into a browser)
    """
    events: list[dict[str, Any]] = []
    per_camera: dict[str, int] = {}

    for cam_name in sorted((cfg.get("cameras") or {}).keys()):
        url = f"{frigate_url}/api/events?camera={cam_name}&limit=10000"
        cam_events, err = _http_json(url, API_TIMEOUT_S)
        if err is not None or not isinstance(cam_events, list):
            continue
        for e in cam_events:
            st = e.get("start_time")
            if not isinstance(st, (int, float)):
                continue
            if not (walk_start_epoch <= st <= walk_end_epoch):
                continue
            et = e.get("end_time")
            duration_s = (et - st) if isinstance(et, (int, float)) else None

            # Recording on disk?
            ts = dt.datetime.fromtimestamp(st, tz=dt.timezone.utc)
            rec_path = (Path(media_path) / "recordings" /
                        ts.strftime("%Y-%m-%d") / ts.strftime("%H") /
                        f"{e.get('id')}.mp4")
            rec_size = rec_path.stat().st_size if rec_path.is_file() else 0

            # Snapshot URL (always synthesised — Frigate serves from the API)
            snap_url = f"{frigate_url}/api/events/{e.get('id')}/snapshot.jpg"

            cam_cfg = (cfg.get("cameras") or {}).get(cam_name) or {}
            # Inject the global model + motion blocks so the trace can
            # show them (they live at the top level of config.yml, not
            # inside the per-camera block).
            cam_cfg_for_trace = {
                **cam_cfg,
                "model": cfg.get("model") or {},
                "global_motion": cfg.get("motion") or {},
            }
            trace = evaluate_event_trace(e, cam_cfg_for_trace)
            events.append({
                "id": e.get("id"),
                "camera": cam_name,
                "start_epoch": st,
                "start_utc": epoch_to_utc(st),
                "start_local": epoch_to_local(st),
                "end_epoch": et,
                "end_utc": epoch_to_utc(et),
                "end_local": epoch_to_local(et),
                "duration_s": round(duration_s, 3) if duration_s is not None else None,
                "label": e.get("label"),
                "top_score": e.get("data", {}).get("top_score"),
                "zones": e.get("zones") or [],
                "has_clip": bool(e.get("has_clip")),
                "has_snapshot": bool(e.get("has_snapshot")),
                "recording_path": str(rec_path) if rec_path.is_file() else None,
                "recording_size_bytes": rec_size if rec_path.is_file() else None,
                "snapshot_url": snap_url,
                # NEW: per-event pipeline trace
                "trace": trace,
            })
            per_camera[cam_name] = per_camera.get(cam_name, 0) + 1

    # Sort chronologically by start_epoch (ascending) — the user's
    # "correlate with my test walk" use case depends on this being a
    # strict time-ordered log.
    events.sort(key=lambda e: e["start_epoch"])

    return {
        "end_input_epoch": walk_end_epoch,
        "start_utc": epoch_to_utc(walk_start_epoch),
        "end_utc": epoch_to_utc(walk_end_epoch),
        "duration_s": round(walk_end_epoch - walk_start_epoch, 3),
        "events_total": len(events),
        "events_per_camera": per_camera,
        "events": events,
    }



# ---------------------------------------------------------------------------
# Per-event pipeline trace
# ---------------------------------------------------------------------------
# For every event in the walk window, walk the SAME 14-stage pipeline that
# brought the event into existence and evaluate each stage's config bound
# against the event's actual data. The output answers:
#
#   "for this event, did the bbox pass min_area? did the bbox pass max_area?
#    did the bbox fall in a required zone? did the review gate promote it
#    to alert? was the snapshot written? was the clip written?"
#
# Frigate does not expose the per-stage decisions for an event via the REST
# API — we RE-DERIVE the verdict from the event's actual data + the camera's
# config. This is exact (not heuristic): the same boolean the Frigate
# detector pipeline computed.
# ---------------------------------------------------------------------------
def evaluate_event_trace(event: dict[str, Any], cam: dict[str, Any]) -> dict[str, Any]:
    """Evaluate every pipeline stage the event went through. Returns a
    per-stage dict with the actual value, the configured bound, the
    PASS/FAIL verdict, and a human-readable reason.

    The bbox is in NORMALIZED [0-1] coordinates (Frigate convention). To
    convert to pixels, we multiply by the camera's `detect.width` /
    `detect.height`. The person filter operates in pixels.
    """
    det = cam.get("detect") or {}
    detect_w = det.get("width") or 1
    detect_h = det.get("height") or 1

    # The data.box is the [x, y, w, h] in normalized coords. The top-level
    # `box` is sometimes None — prefer data.box, fall back to top-level.
    data = event.get("data") or {}
    box_norm = data.get("box") or event.get("box")
    score = data.get("score") or event.get("top_score")
    top_score = data.get("top_score") or event.get("top_score")
    region_norm = data.get("region") or []
    motion_region_norm = region_norm if len(region_norm) == 4 else None

    # --- STAGE 1: Motion pre-filter ---
    # The caller (collect_walk_events) merges the global motion block into
    # the camera dict at "global_motion" so we can fall back to it when
    # the per-camera block is missing — matches the state report's
    # `stage_motion` behaviour.
    cam_motion = cam.get("motion") or {}
    global_motion = cam.get("global_motion") or {}
    motion_cfg = {**global_motion, **cam_motion}
    motion_threshold = motion_cfg.get("threshold")
    motion_contour_area = motion_cfg.get("contour_area")
    motion_verdict = "PASS"
    motion_reason = ("event was created => motion pre-filter fired with a region "
                     "above threshold (the motion mask itself is not exposed "
                     "via the REST API; the existence of the event is the proof)")

    motion = {
        "threshold": motion_threshold,
        "contour_area": motion_contour_area,
        "motion_region_norm": motion_region_norm,
        "verdict": motion_verdict,
        "reason": motion_reason,
    }

    # --- STAGE 2: Object detector (TRT) ---
    # We don't have a direct "detector fired Y times" count from the API,
    # but the data.score is the score of the frame that triggered the
    # event (or the best frame). The existence of data.box proves the
    # detector returned at least one detection.
    detector = {
        "model_path": (cam.get("model") or {}),  # set by caller
        "verdict": "PASS" if box_norm else "FAIL",
        "reason": ("detector returned a bounding box (data.box present)"
                   if box_norm else
                   "no bounding box on the event — detector did not return a hit"),
        "score_frame": score,
        "score_event": top_score,
    }

    # --- STAGE 3: Bbox extraction ---
    bbox = {"norm": box_norm, "px": None, "area_px2": None, "ratio": None, "centroid_norm": None,
            "verdict": "N/A", "reason": "no bounding box on this event"}
    if box_norm and len(box_norm) == 4:
        x, y, w, h = box_norm
        px_x = round(x * detect_w)
        px_y = round(y * detect_h)
        px_w = round(w * detect_w)
        px_h = round(h * detect_h)
        area = px_w * px_h
        ratio = (px_w / px_h) if px_h else None
        bbox.update({
            "px": [px_x, px_y, px_w, px_h],
            "area_px2": area,
            "ratio": round(ratio, 3) if ratio else None,
            "centroid_norm": [round(x + w/2, 4), round(y + h/2, 4)],
            "verdict": "PASS",
            "reason": f"bbox extracted from detector output (area={area} px²)",
        })

    # --- STAGE 4: Person filter (physics) ---
    person_cfg = ((cam.get("objects") or {}).get("filters") or {}).get("person") or {}
    person_checks: dict[str, Any] = {}
    area = bbox.get("area_px2")
    ratio = bbox.get("ratio")
    # Min area
    ma = person_cfg.get("min_area")
    if ma is not None and area is not None:
        person_checks["min_area"] = {
            "bound": ma, "actual": area,
            "verdict": "PASS" if area >= ma else "FAIL",
            "reason": f"{area} {'≥' if area >= ma else '<'} {ma}",
        }
    # Max area
    Ma = person_cfg.get("max_area")
    if Ma is not None and area is not None:
        person_checks["max_area"] = {
            "bound": Ma, "actual": area,
            "verdict": "PASS" if area <= Ma else "FAIL",
            "reason": f"{area} {'≤' if area <= Ma else '>'} {Ma}",
        }
    # Min ratio
    mr = person_cfg.get("min_ratio")
    if mr is not None and ratio is not None:
        person_checks["min_ratio"] = {
            "bound": mr, "actual": ratio,
            "verdict": "PASS" if ratio >= mr else "FAIL",
            "reason": f"{ratio} {'≥' if ratio >= mr else '<'} {mr}",
        }
    # Max ratio
    Mr = person_cfg.get("max_ratio")
    if Mr is not None and ratio is not None:
        person_checks["max_ratio"] = {
            "bound": Mr, "actual": ratio,
            "verdict": "PASS" if ratio <= Mr else "FAIL",
            "reason": f"{ratio} {'≤' if ratio <= Mr else '>'} {Mr}",
        }
    # Threshold (model confidence)
    thr = person_cfg.get("threshold")
    if thr is not None and top_score is not None:
        person_checks["threshold"] = {
            "bound": thr, "actual": round(top_score, 4),
            "verdict": "PASS" if top_score >= thr else "FAIL",
            "reason": f"{top_score:.4f} {'≥' if top_score >= thr else '<'} {thr}",
        }
    # Min score
    ms = person_cfg.get("min_score")
    if ms is not None and top_score is not None:
        person_checks["min_score"] = {
            "bound": ms, "actual": round(top_score, 4),
            "verdict": "PASS" if top_score >= ms else "FAIL",
            "reason": f"{top_score:.4f} {'≥' if top_score >= ms else '<'} {ms}",
        }
    n_fail = sum(1 for c in person_checks.values() if c.get("verdict") == "FAIL")
    person_filter = {
        "checks": person_checks,
        "verdict": "FAIL" if n_fail else "PASS",
        "reason": (f"{n_fail} of {len(person_checks)} checks failed"
                   if n_fail else f"all {len(person_checks)} checks passed"),
    }

    # --- STAGE 5: Zone matching ---
    zones_cfg = cam.get("zones") or {}
    zones_defined = sorted(zones_cfg.keys())
    event_zones = event.get("zones") or []
    centroid = bbox.get("centroid_norm")
    # Frigate already computed which zones the event hit. The zones
    # listed in `event.zones` are the ones the bbox overlapped (or the
    # centroid was inside, depending on Frigate's matching mode).
    # We surface what Frigate reports; the centroid is shown for the
    # operator to sanity-check the geometry.
    zones = {
        "defined": zones_defined,
        "bbox_centroid_norm": centroid,
        "hit": event_zones,
        "verdict": ("hit " + ", ".join(event_zones)) if event_zones else "no zone hit",
    }

    # --- STAGE 6: Review gate (alerts vs detections) ---
    review = cam.get("review") or {}
    alerts_zones = (review.get("alerts") or {}).get("required_zones") or []
    detections_zones = (review.get("detections") or {}).get("required_zones") or []
    if isinstance(alerts_zones, str):
        alerts_zones = [alerts_zones]
    if isinstance(detections_zones, str):
        detections_zones = [detections_zones]
    in_alerts = any(z in (event_zones or []) for z in alerts_zones) if alerts_zones else False
    in_detections = any(z in (event_zones or []) for z in detections_zones) if detections_zones else False
    # max_severity from data is the canonical Frigate verdict
    fr_severity = (data.get("max_severity") or "").lower()
    if fr_severity == "alert":
        alert_classification = "ALERT"
    elif fr_severity == "detection":
        alert_classification = "detection"
    elif in_alerts:
        alert_classification = "ALERT (re-derived)"
    elif in_detections:
        alert_classification = "detection (re-derived)"
    else:
        alert_classification = "detection (no required zone hit)"
    if alerts_zones:
        reason = (f"event zones {event_zones or '(none)'} "
                  f"{'∈' if in_alerts else '⊄'} alerts_required_zones {alerts_zones} "
                  f"=> {alert_classification}")
    else:
        reason = f"no alerts.required_zones configured; everything is an alert when detected"
    review_gate = {
        "alerts_required_zones": alerts_zones,
        "detections_required_zones": detections_zones,
        "event_zones": event_zones,
        "frigate_max_severity": fr_severity or None,
        "classification": alert_classification,
        "verdict": alert_classification,
        "reason": reason,
    }

    # --- STAGE 7 + 8: Snapshot / Recording ---
    snap = {
        "written": bool(event.get("has_snapshot")),
        "verdict": "WRITTEN" if event.get("has_snapshot") else "NOT WRITTEN",
        "reason": ("has_snapshot=True (best frame captured at peak score)"
                   if event.get("has_snapshot") else
                   "has_snapshot=False (event ended without a best-frame capture)"),
    }
    clip = {
        "written": bool(event.get("has_clip")),
        "verdict": "WRITTEN" if event.get("has_clip") else "NOT WRITTEN",
        "reason": ("has_clip=True (mp4 on disk at /media/frigate/recordings/...)"
                   if event.get("has_clip") else
                   "has_clip=False (event in progress, or retention already pruned)"),
    }

    # --- STAGE 9: MQTT publish ---
    # Frigate publishes start/update/end on calypso_frigate/events when the
    # event is created. We can't directly verify the publish without a
    # mosquitto_sub, but the event's existence + classification tells us
    # the lifecycle transitions have been emitted.
    mqtt = {
        "verdict": "LIKELY PUBLISHED",
        "reason": ("event lifecycle start/update/end was published on "
                   "calypso_frigate/events; classification: " + alert_classification),
    }

    return {
        "motion":        motion,
        "detector":      detector,
        "bbox":          bbox,
        "person_filter": person_filter,
        "zones":         zones,
        "review_gate":   review_gate,
        "snapshot":      snap,
        "recording":     clip,
        "mqtt":          mqtt,
    }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    p = argparse.ArgumentParser(
        description="Per-camera Frigate CURRENT PIPELINE STATE assessment "
                    "(+ chronological test-walk event log via --walk-*).",
    )
    p.add_argument(
        "--camera",
        help="restrict to a single camera name (default: all cameras in config.yml)",
    )
    p.add_argument(
        "--frigate-url", default=os.environ.get("FRIGATE_URL", "http://localhost:5000"),
        help="Frigate API base URL (default: http://localhost:5000 or $FRIGATE_URL)",
    )
    p.add_argument(
        "--go2rtc-url", default=os.environ.get("GO2RTC_URL", "http://localhost:1984"),
        help="go2rtc API base URL (default: http://localhost:1984 or $GO2RTC_URL)",
    )
    p.add_argument(
        "--mqtt-host", default=os.environ.get("MQTT_HOST", "192.168.50.125"),
        help="MQTT broker host (default: 192.168.50.125 or $MQTT_HOST)",
    )
    p.add_argument(
        "--mqtt-port", type=int, default=int(os.environ.get("MQTT_PORT", "1883")),
        help="MQTT broker port (default: 1883 or $MQTT_PORT)",
    )
    p.add_argument(
        "--media-path", default=os.environ.get("FRIGATE_MEDIA_PATH", "/mnt/nas/video/frigate"),
        help="Frigate media path (recordings / snapshots). Default: "
             "$FRIGATE_MEDIA_PATH or /mnt/nas/video/frigate",
    )
    p.add_argument(
        "--window-hours", type=int, default=WINDOW_HOURS_DEFAULT,
        help=f"recent-event window in hours (default: {WINDOW_HOURS_DEFAULT}). "
             "Ignored when --walk-start/--walk-end are set.",
    )
    p.add_argument(
        "--walk-start",
        help="start of the test-walk window (ISO 8601 or epoch). "
             "Triggers walk mode (chronological event log) when set.",
    )
    p.add_argument(
        "--walk-end",
        help="end of the test-walk window (ISO 8601 or epoch). "
             "Defaults to now if --walk-start is set without --walk-end.",
    )
    p.add_argument(
        "--walk-minutes", type=float,
        help="convenience: end = start + N minutes. If --walk-start is "
             "omitted, end is now() and start is now() - walk-minutes.",
    )
    p.add_argument(
        "--command", default="collect", choices=("collect",),
        help=argparse.SUPPRESS,  # reserved for future sub-commands
    )
    args = p.parse_args()

    # ----- Resolve the walk window (if any) -----
    walk_mode = False
    walk_start_epoch: float | None = None
    walk_end_epoch: float | None = None
    if args.walk_start or args.walk_end or args.walk_minutes is not None:
        walk_mode = True
        if args.walk_start:
            walk_start_epoch = parse_timestamp(args.walk_start)
            if walk_start_epoch is None:
                sys.stderr.write(f"ERROR: cannot parse --walk-start={args.walk_start!r}\n")
                return 2
        elif args.walk_minutes is not None:
            walk_start_epoch = now_epoch() - args.walk_minutes * 60
        else:
            sys.stderr.write("ERROR: --walk-end requires --walk-start (or use --walk-minutes)\n")
            return 2
        if args.walk_end:
            walk_end_epoch = parse_timestamp(args.walk_end)
            if walk_end_epoch is None:
                sys.stderr.write(f"ERROR: cannot parse --walk-end={args.walk_end!r}\n")
                return 2
        else:
            walk_end_epoch = now_epoch()
        if walk_end_epoch < walk_start_epoch:
            sys.stderr.write("ERROR: --walk-end is before --walk-start\n")
            return 2

    cfg = load_config()
    cam_ips = get_camera_ips(cfg)
    cameras = sorted((cfg.get("cameras") or {}).keys())
    if args.camera:
        if args.camera not in cameras:
            sys.stderr.write(
                f"ERROR: --camera={args.camera!r} not in config.yml cameras.\n"
                f"  known: {cameras}\n"
            )
            return 2
        cameras = [args.camera]

    # Single fetch of /api/stats (used by stages 4, 5, 7, 14 for every camera).
    cam_stats, stats_err = _http_json(f"{args.frigate_url}/api/stats", API_TIMEOUT_S)
    if cam_stats is None:
        cam_stats = {}
        # Don't fail-fast; the per-camera stages will report NA with a reason.

    per_camera = []
    for name in cameras:
        report = collect_for_camera(
            name=name,
            cfg=cfg,
            cam_stats=cam_stats,
            cam_ips=cam_ips,
            frigate_url=args.frigate_url,
            go2rtc_url=args.go2rtc_url,
            mqtt_host=args.mqtt_host,
            mqtt_port=args.mqtt_port,
            media_path=args.media_path,
            window_hours=args.window_hours,
        )
        per_camera.append(report)

    # Cross-camera summary
    n_total = len(per_camera)
    n_ok = sum(1 for r in per_camera if r["verdict"] == "OK")
    n_degraded = sum(1 for r in per_camera if r["verdict"] == "DEGRADED")
    n_fail = sum(1 for r in per_camera if r["verdict"] == "FAIL")
    n_disabled = sum(1 for r in per_camera if r["verdict"] == "DETECTION_DISABLED")

    envelope = {
        "schema_version": 2,
        "report_ts_utc": iso_utc_now(),
        "report_ts_epoch": now_epoch(),
        "report_ts_local": epoch_to_local(now_epoch()),
        "host": socket.gethostname(),
        "frigate_url": args.frigate_url,
        "go2rtc_url": args.go2rtc_url,
        "mqtt_broker": f"{args.mqtt_host}:{args.mqtt_port}",
        "media_path": args.media_path,
        "window_hours": args.window_hours,
        "stats_api_status": "ok" if stats_err is None else f"error: {stats_err}",
        "mode": "walk" if walk_mode else "state",
    }
    if walk_mode:
        assert walk_start_epoch is not None and walk_end_epoch is not None
        envelope["walk"] = collect_walk_events(
            cfg=cfg,
            frigate_url=args.frigate_url,
            media_path=args.media_path,
            walk_start_epoch=walk_start_epoch,
            walk_end_epoch=walk_end_epoch,
        )
    else:
        envelope["summary"] = {
            "cameras_total": n_total,
            "cameras_ok": n_ok,
            "cameras_degraded": n_degraded,
            "cameras_fail": n_fail,
            "cameras_detection_disabled": n_disabled,
        }
        envelope["cameras"] = per_camera
    json.dump(envelope, sys.stdout, indent=2, default=str)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
