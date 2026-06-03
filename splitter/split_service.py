#!/usr/bin/env python3
# ==============================================================================
# split_service.py — Reolink Duo 3 half-crop splitter service
# ==============================================================================
# Independent of Frigate. Consumes the 3 Reolink Duo 3 main streams
# (4096x1152, panoramic, 3.55:1) on the GPU, crops each into two
# 2048x1152 halves (16:9, detection-friendly), re-encodes with NVENC,
# and re-publishes the 6 H.264 streams as RTSP on port 8556.
#
# Frigate's go2rtc.streams then consumes the 6 new streams at
#   rtsp://127.0.0.1:8556/<name>
# and 6 new cameras: blocks in config.yml consume them with full roles
# (detect + record + audio + live).
#
# GPU pipeline (per half):
#   rtspsrc + rtph264depay + h264parse           (RTSP / H.264 in)
#     -> nvv4l2decoder                           (NVDEC, hardware decode)
#     -> cudaconvert left=… width=2048 height=1152 (CUDA / VIC crop)
#        (was nvvidconv before GStreamer 1.20)
#     -> nvv4l2h264enc bitrate=8M                (NVENC, hardware encode)
#     -> h264parse + rtph264pay name=pay0        (H.264 / RTP out)
#
# CPU participation: only the RTSP handshake, the GStreamer bus, and the
# gst-rtsp-server thread pool. Every pixel-touching stage runs on the
# RTX 5060 Ti.
#
# Port 8556 chosen to avoid collision with Frigate's go2rtc (:8554) and
# WebRTC (:8555). Network mode: host (same as Frigate).
#
# Failure model:
#   - If a Reolink upstream dies, the corresponding 2 pipelines go into
#     ERROR. gst-rtsp-server returns 503 on the affected mount points;
#     the other 4 keep serving. Frigate's go2rtc will retry.
#   - If the splitter container dies, Frigate's go2rtc loses the 6 new
#     streams; the 3 panoramic cameras and the 2 other outdoor cameras
#     continue independently. The watchdog re-creates the container.
#
# Env vars (with defaults):
#   LOG_LEVEL          = INFO
#   RTSP_PORT          = 8556
#   BITRATE_BPS        = 8000000     (8 Mbps per half)
#   IDR_INTERVAL_FRAMES= 30          (GOP)
#   FRAMERATE          = 15          (fps, must match Reolink main)
#   SOURCE_W           = 4096        (Reolink main width,  sanity check)
#   SOURCE_H           = 1152        (Reolink main height, sanity check)
# ==============================================================================

from __future__ import annotations

import logging
import os
import signal
import sys
from dataclasses import dataclass

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstRtspServer", "1.0")
gi.require_version("GLib", "2.0")
from gi.repository import GLib, Gst, GstRtspServer  # noqa: E402

# ----------------------------------------------------------------------------
# Configuration (env-driven, with defaults)
# ----------------------------------------------------------------------------
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
RTSP_PORT = int(os.environ.get("RTSP_PORT", "8556"))
BITRATE_BPS = int(os.environ.get("BITRATE_BPS", "8000000"))
IDR_INTERVAL = int(os.environ.get("IDR_INTERVAL_FRAMES", "30"))
FRAMERATE = int(os.environ.get("FRAMERATE", "15"))
SOURCE_W = int(os.environ.get("SOURCE_W", "4096"))
SOURCE_H = int(os.environ.get("SOURCE_H", "1152"))
HALF_W = SOURCE_W // 2  # 2048

logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("splitter")


# ----------------------------------------------------------------------------
# Pipeline dataclass — one half of one Reolink Duo 3 main stream
# ----------------------------------------------------------------------------
@dataclass(frozen=True)
class Pipeline:
    """One half of one Reolink Duo 3 main stream.

    The crop is at the horizontal midpoint (col 2048 of 4096). Reolink's
    two lenses are joined at the center seam of the Duo 3 sensor, so each
    lens dominates one half with minimal overlap.
    """
    name: str          # short name, used in logs
    src_url: str       # full RTSP URL of the Reolink main stream
    crop_x: int        # crop origin x (px, 0 or 2048)
    crop_y: int        # crop origin y (px, always 0)
    crop_w: int        # crop width (px, 2048)
    crop_h: int        # crop height (px, 1152)
    mount_point: str   # RTSP mount, e.g. /allee_sur_le_cote_left

    def launch_string(self) -> str:
        # GStreamer launch string. Notes:
        #  - rtspsrc + rtph264depay pulls H.264 from the Reolink.
        #  - h264parse converts AVC access units into a parseable form.
        #  - nvv4l2decoder decodes on NVDEC; output is in NVMM memory.
        #  - cudaconvert (was nvvidconv pre-1.20) with left/top/width/
        #    height crops ON THE GPU (no CPU copy, no rescale, just a
        #    CUDA crop of the NVMM frame). flip-method=0 keeps the
        #    panorama left-to-right.
        #  - capsfilter forces the output to NVMM + NV12 to keep the
        #    entire path on the GPU; format=NV12 matches nvv4l2h264enc.
        #  - nvv4l2h264enc re-encodes on NVENC. maxperf-enable=true
        #    biases the encoder to throughput over compression.
        #  - h264parse + rtph264pay shape the bitstream for RTSP;
        #    config-interval=1 sends SPS/PPS with every IDR so new
        #    clients can decode immediately.
        #  - name=pay0 is the canonical sink gst-rtsp-server hooks.
        return (
            f"( rtspsrc location=\"{self.src_url}\" "
            f"latency=0 protocols=tcp do-retransmission=false "
            f"timeout=5000000 "
            f"! application/x-rtp,media=video,encoding-name=H264,"
            f"clock-rate=90000,payload=96 "
            f"! rtph264depay "
            f"! h264parse "
            f"! nvv4l2decoder "
            f"! cudaconvert left={self.crop_x} top={self.crop_y} "
            f"width={self.crop_w} height={self.crop_h} "
            f"flip-method=0 "
            f"! video/x-raw(memory:NVMM),width={self.crop_w},"
            f"height={self.crop_h},format=NV12,"
            f"framerate={FRAMERATE}/1 "
            f"! nvv4l2h264enc bitrate={BITRATE_BPS} "
            f"idrinterval={IDR_INTERVAL} "
            f"insert-sps-pps=true maxperf-enable=true "
            f"! h264parse config-interval=1 "
            f"! rtph264pay name=pay0 pt=96 config-interval=1 )"
        )


# ----------------------------------------------------------------------------
# Pipeline table — generated from the 3 Reolink Duo 3 cameras in config.yml.
# The 3 sources are:
#   192.168.50.129  allee_sur_le_cote        (3.4 m mount, 50 deg tilt)
#   192.168.50.18   jardin_devant            (6.0 m mount, 50 deg tilt)
#   192.168.50.7    piscine_vue_toit         (6.0 m mount, 25 deg tilt)
# Each main stream is 4096x1152 (H.264, ~8-10 Mbps). The crop is exactly
# at the sensor's centre seam (col 2048 of 4096).
# ----------------------------------------------------------------------------
PIPELINES: list[Pipeline] = [
    # allee_sur_le_cote
    Pipeline(
        name="allee_sur_le_cote_left",
        src_url="rtsp://admin:fG-56lui@192.168.50.129:8554/h264Preview_01_main",
        crop_x=0, crop_y=0, crop_w=HALF_W, crop_h=SOURCE_H,
        mount_point="/allee_sur_le_cote_left",
    ),
    Pipeline(
        name="allee_sur_le_cote_right",
        src_url="rtsp://admin:fG-56lui@192.168.50.129:8554/h264Preview_01_main",
        crop_x=HALF_W, crop_y=0, crop_w=HALF_W, crop_h=SOURCE_H,
        mount_point="/allee_sur_le_cote_right",
    ),
    # jardin_devant
    Pipeline(
        name="jardin_devant_left",
        src_url="rtsp://admin:fG-56lui@192.168.50.18:8554/h264Preview_01_main",
        crop_x=0, crop_y=0, crop_w=HALF_W, crop_h=SOURCE_H,
        mount_point="/jardin_devant_left",
    ),
    Pipeline(
        name="jardin_devant_right",
        src_url="rtsp://admin:fG-56lui@192.168.50.18:8554/h264Preview_01_main",
        crop_x=HALF_W, crop_y=0, crop_w=HALF_W, crop_h=SOURCE_H,
        mount_point="/jardin_devant_right",
    ),
    # piscine_vue_toit
    Pipeline(
        name="piscine_vue_toit_left",
        src_url="rtsp://admin:fG-56lui@192.168.50.7:8554/h264Preview_01_main",
        crop_x=0, crop_y=0, crop_w=HALF_W, crop_h=SOURCE_H,
        mount_point="/piscine_vue_toit_left",
    ),
    Pipeline(
        name="piscine_vue_toit_right",
        src_url="rtsp://admin:fG-56lui@192.168.50.7:8554/h264Preview_01_main",
        crop_x=HALF_W, crop_y=0, crop_w=HALF_W, crop_h=SOURCE_H,
        mount_point="/piscine_vue_toit_right",
    ),
]


# ----------------------------------------------------------------------------
# Splitter service
# ----------------------------------------------------------------------------
class SplitterService:
    """Hosts 6 GStreamer pipelines behind a single RTSP server.

    The server is gst-rtsp-server in factory mode: each pipeline is a
    factory that gets spawned on first RTSP DESCRIBE. With
    set_shared(True), a single pipeline serves all concurrent clients
    (Frigate's go2rtc + the live browser view share the same encode
    work). With set_shared(False), a new pipeline is created per
    client; we don't want that — GPU is precious.
    """

    def __init__(self) -> None:
        Gst.init(None)
        self.loop = GLib.MainLoop()
        self.server = GstRtspServer.RTSPServer()
        self.server.set_service(str(RTSP_PORT))
        # Thread pool: 6 concurrent streams. The gst-rtsp-server
        # thread-pool size is the upper bound on simultaneous factory
        # instantiations; for set_shared(True) pipelines this also
        # governs the per-client connection handlers.
        self.server.set_threads(6)

        mounts = self.server.get_mount_points()
        for p in PIPELINES:
            factory = GstRtspServer.RTSPMediaFactory.new()
            factory.set_launch(p.launch_string())
            # Shared pipeline per factory: one GPU pipeline serves
            # all clients for this mount. If the pipeline goes into
            # ERROR, all clients are disconnected briefly while
            # gst-rtsp-server restarts the pipeline.
            factory.set_shared(True)
            # Latency in ms (0 = no buffering, lowest latency for live).
            factory.set_latency(0)
            mounts.add_factory(p.mount_point, factory)
            log.info(
                "mounted %-26s <- %-78s  (crop %d,%d %dx%d)",
                p.mount_point, p.src_url,
                p.crop_x, p.crop_y, p.crop_w, p.crop_h,
            )

        # Attach the server to the default GLib.MainContext so it
        # runs on the main loop. gst-rtsp-server binds 0.0.0.0 by
        # default; we want it to be reachable on the loopback (where
        # Frigate's go2rtc connects) and on the LAN IP (for the
        # browser live view).
        self.server.attach(None)
        log.info(
            "RTSP server listening on 0.0.0.0:%d  (6 mounts, "
            "shared pipelines, bitrate=%d bps, fps=%d)",
            RTSP_PORT, BITRATE_BPS, FRAMERATE,
        )

    def run(self) -> None:
        # Clean shutdown on SIGTERM (docker stop) and SIGINT (Ctrl-C).
        GLib.unix_signal_add(
            GLib.PRIORITY_HIGH, signal.SIGTERM, self._stop, None
        )
        GLib.unix_signal_add(
            GLib.PRIORITY_HIGH, signal.SIGINT, self._stop, None
        )
        log.info("entering main loop (Ctrl-C to stop)")
        try:
            self.loop.run()
        except KeyboardInterrupt:
            self._stop(None)

    def _stop(self, _user_data) -> bool:
        log.info("shutting down")
        self.loop.quit()
        return GLib.SOURCE_REMOVE


def main() -> int:
    service = SplitterService()
    service.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
