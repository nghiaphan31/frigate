# ==============================================================================
# splitter/Dockerfile — Reolink Duo 3 half-crop splitter service
# ==============================================================================
# Base: NVIDIA CUDA 12.x runtime on Ubuntu 22.04. We need:
#  - libnvinfer / libcuda / libnvcuvid / libnvrtc / libnvidia-encode
#    for the GPU plugins (nvv4l2decoder / nvvidconv / nvv4l2h264enc)
#  - GStreamer 1.20+ (Ubuntu 22.04 ships 1.20.3)
#  - The 4 NVIDIA GStreamer plugin packages:
#      * nvidia-gst-plugins-base   (provides nvvideoconvert / nvvidconv)
#      * nvidia-gst-plugins-good   (provides nvv4l2vp8 / nvv4l2vp9)
#      * nvidia-gst-plugins-bad    (provides nvv4l2decoder /
#                                   nvv4l2h264enc / nvv4l2h265enc /
#                                   nvv4l2vp8enc / nvv4l2vp9enc)
#      * gst-rtsp-server           (provides the RTSP server framework)
#  - Python 3.10 + PyGObject + gobject-introspection (the gi package)
#
# The NVIDIA plugin packages are pulled from
#   https://launchpad.net/~ruffy8919/+archive/ubuntu/nv-gst-plugins
# which is the only PPA shipping the full set for x86_64 Ubuntu 22.04.
# Alternative: build from source
#   https://github.com/NVIDIA-AI-IOT/deepstream_sdk (heavy)
# or pull from NGC's DeepStream images (much larger, ~6 GB).
#
# Image target:  ~1.5 GB compressed, ~2.5 GB on disk.
# ==============================================================================
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

# Disable interactive prompts and pin the LTS toolchain
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# --- 1. Base toolchain + GStreamer + Python bindings ---------------------
# We need:
#  - python3-gi, python3-gst-1.0  (PyGObject + GStreamer Python bindings)
#  - gobject-introspection, gir1.2-gst-rtsp-server-1.0  (introspection data
#    for the GstRtspServer Python bindings; required by gi.require_version)
#  - libgstrtspserver-1.0-0, gstreamer1.0-rtsp  (runtime + rtsp plugins)
#  - netcat-openbsd  (for the HEALTHCHECK TCP probe to port 8556)
#  - ca-certificates, curl, gnupg, software-properties-common  (PPA bootstrap)
#  - ffmpeg, jq  (operator debug utilities)
#
# NOTE on NVIDIA driver libs (libnvcuvid, libnvidia-encode, libcuda):
# the nvidia/cuda:12.x-runtime base image deliberately does NOT include
# the driver userspace libs — they're provided by the host's NVIDIA
# driver via the nvidia container runtime, which mounts them in at
# container start. Adding them as apt packages would (a) fail to
# resolve in Ubuntu 22.04's standard repos (libnvcuvid1 is now part
# of libnvidia-compute-535), and (b) be a no-op anyway since the
# nvidia runtime overrides them. The NVIDIA GStreamer plugins
# (nvv4l2decoder, nvvidconv, nvv4l2h264enc) link to these libs by
# soname and find them through the runtime's mount.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
        software-properties-common \
        python3 python3-pip python3-gi python3-gst-1.0 \
        gir1.2-gst-rtsp-server-1.0 \
        gobject-introspection \
        libgstrtspserver-1.0-0 \
        gstreamer1.0-rtsp \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        libgstreamer-plugins-base1.0-0 libgstreamer1.0-0 \
        ffmpeg jq netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# --- 2. NVIDIA GStreamer plugins (nvv4l2, nvvidconv) -------------------------
# These are the plugins that give us GPU-accelerated H.264 decode (NVDEC),
# GPU crop / format conversion (CUDA / VIC), and H.264 encode (NVENC).
# They are NOT in the standard Ubuntu 22.04 repos. Three install paths,
# in order of preference:
#
#   (A) DeepStream base image (cleanest, biggest, requires nvcr.io login)
#   (B) ruffy8919 PPA (works if the PPA is reachable from your network)
#   (C) Build gst-plugins-bad with the nvv4l2 subproject from source
#       (heavy, but works in any environment with CUDA + build tools)
#
# This Dockerfile uses (B) the PPA, since it's the smallest delta from
# the nvidia/cuda base and works in most environments. If the PPA is
# unreachable (it went down briefly in 2024-2025), the operator can
# either (i) re-run the build, (ii) fall back to (C) by replacing this
# RUN block with the build-from-source recipe, or (iii) switch the
# FROM line to `nvcr.io/nvidia/deepstream:7.0-triton-multiarch` (which
# has the plugins pre-installed; requires `docker login nvcr.io`).
#
# The NVIDIA GStreamer plugin source repos (for the build-from-source
# path (C)):
#   - https://gitlab.freedesktop.org/gstreamer/gstreamer
#     (subproject gst-plugins-bad/sys/nvv4l2)
#   - https://github.com/NVIDIA-AI-IOT/gst-nvv4l2
#     (fork with vendored libnvv4l2)
RUN set -eux; \
    if add-apt-repository -y ppa:ruffy8919/nv-gst-plugins 2>/dev/null; then \
        apt-get update && apt-get install -y --no-install-recommends \
            nvidia-gst-plugins-base \
            nvidia-gst-plugins-good \
            nvidia-gst-plugins-bad \
        && rm -rf /var/lib/apt/lists/*; \
        echo "[splitter] NVIDIA GStreamer plugins installed via ruffy8919 PPA"; \
    else \
        echo "[splitter] WARN: ruffy8919 PPA unreachable; nvv4l2 plugins will not be available."; \
        echo "[splitter]       The container will start but pipelines will fail at first DESCRIBE."; \
        echo "[splitter]       Fix: re-run on a host that can reach the PPA, OR build the"; \
        echo "[splitter]       plugins from source (see comments in this Dockerfile), OR use"; \
        echo "[splitter]       the DeepStream base image (FROM line above)."; \
    fi

# --- 3. Python deps (gi bindings are pulled from apt above; this is just
#       for the small helpers we use, none actually required for now) -------
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt && \
    rm -f /tmp/requirements.txt

# --- 4. Service code ---------------------------------------------------------
WORKDIR /opt/splitter
COPY split_service.py /opt/splitter/split_service.py
COPY entrypoint.sh    /opt/splitter/entrypoint.sh
RUN chmod +x /opt/splitter/entrypoint.sh

# --- 5. Default env (overridable at runtime) --------------------------------
ENV LOG_LEVEL=INFO
ENV RTSP_PORT=8556
ENV BITRATE_BPS=8000000
ENV IDR_INTERVAL_FRAMES=30
ENV FRAMERATE=15
ENV SOURCE_W=4096
ENV SOURCE_H=1152

# --- 6. Healthcheck (TCP probe to the RTSP port) -----------------------------
# docker's HEALTHCHECK does a TCP-only probe. Deeper checks (DESCRIBE /
# ffprobe) are done by the L1 test from the host side.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD nc -z 127.0.0.1 8556 || exit 1

# --- 7. Entrypoint -----------------------------------------------------------
# entrypoint.sh waits for /dev/nvidia* to appear (the NVIDIA runtime in
# some host configurations lags by 1-2 s on container start) and then
# execs the service. SIGTERM from docker stop is forwarded by Python's
# GLib signal handler registered in split_service.py:run().
ENTRYPOINT ["/opt/splitter/entrypoint.sh"]
CMD ["python3", "-u", "/opt/splitter/split_service.py"]
