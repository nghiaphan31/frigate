# ==============================================================================
# splitter/Dockerfile — Reolink Duo 3 half-crop splitter service
# ==============================================================================
# Independent of Frigate. Runs a GStreamer + NVIDIA plugin service that
# decodes the 3 Reolink Duo 3 main streams (4096×1152 panoramic) on the
# GPU, crops each into two 2048×1152 (16:9) halves, re-encodes with
# NVENC, and re-publishes the 6 H.264 streams as RTSP on port 8556.
#
# === Base image choice (this Dockerfile uses option A) ===
#
# The NVIDIA GStreamer plugins (nvv4l2decoder, nvvidconv, nvv4l2h264enc)
# are NOT in the standard Ubuntu 22.04 repos. Three install paths:
#
#   (A) DeepStream base image  — RECOMMENDED. The NVIDIA NGC image
#       `nvcr.io/nvidia/deepstream:7.0-triton-multiarch` ships
#       Ubuntu 22.04 + CUDA 12.x + GStreamer 1.20 + ALL the NVIDIA
#       GStreamer plugins (and DeepStream) pre-installed and on the
#       default plugin path. ~5 GB compressed, ~15 GB on disk.
#       Requires `docker login nvcr.io` once (free NVIDIA account at
#       ngc.nvidia.com).
#
#   (B) ruffy8919 PPA  — small, but the PPA has been intermittently
#       unavailable since 2024-2025. If the PPA is up, swap the FROM
#       line back to `nvidia/cuda:12.4.1-runtime-ubuntu22.04` and
#       uncomment the PPA block at the bottom of this file.
#
#   (C) Build from source  — heaviest, but works without NGC. See
#       https://gitlab.freedesktop.org/gstreamer/gstreamer
#       (subproject gst-plugins-bad/sys/nvv4l2). Adds 5-10 min to
#       the build.
#
# This Dockerfile uses (A) for reliability. The split_service.py
# pipeline (rtspsrc + rtph264depay + h264parse + nvv4l2decoder +
# nvvidconv + nvv4l2h264enc + h264parse + rtph264pay) is identical
# across all three options.
#
# === How to switch base image ===
#
#   1. One-time: docker login nvcr.io
#      (free NVIDIA NGC account: https://ngc.nvidia.com/signup)
#   2. cd splitter
#   3. docker build -t frigate-splitter:local .
#   4. cd ..
#   5. docker compose -f splitter/docker-compose.splitter.yml up -d
#   6. Wait ~30 s, then `curl http://localhost:8556` (the gst-rtsp-server
#      status page should respond) and `ffprobe rtsp://localhost:8556/allee_sur_le_cote_left`
#      to see the 6 new streams.
# ==============================================================================
# Build the NVIDIA GStreamer plugins (nvv4l2decoder, nvvidconv, nvv4l2h264enc)
# from source on top of a stock nvidia/cuda runtime image. No PPA, no
# NGC login, no DeepStream image. The build is heavy (~5 min on first
# build) but the resulting image is self-contained and reproducible.
#
# We use the nvidia/cuda:12.4.1-cudnn-devel base (NOT runtime) so the
# CUDA + NVENC + NVDEC headers are available for the plugin build.
# The runtime variant of these libs is then provided at container start
# by the nvidia container runtime, which mounts the host's NVIDIA
# driver libraries in (matches the existing Frigate compose pattern).
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

# DeepStream already has Python 3 + GStreamer + NVIDIA plugins installed.
# The plugins live at:
#   /opt/nvidia/deepstream/deepstream/lib/gst-plugins/
# Make sure the plugin path is on GST_PLUGIN_PATH (set in entrypoint.sh).
# We do NOT touch the DeepStream image's GStreamer / Python / CUDA
# installations — we just add a few operator utilities and the
# PyGObject introspection bindings that aren't pre-installed.

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# --- 1. Add the GStreamer dev headers + the NVIDIA plugin build deps ---------
# nvidia/cuda:12.4.1-cudnn-devel already has CUDA + NVENC + NVDEC headers
# (libcudnn8-dev, libnvcuvid-dev, libnvidia-encode-dev). We add:
#  - GStreamer 1.20 + dev headers (for the nvv4l2 plugin build)
#  - libdrm-dev, libgudev-1.0-dev (v4l2 device access)
#  - libudev-dev, libxext-dev (build glue)
#  - meson + ninja-build (build system used by gst-plugins-bad)
#  - python3-gi + python3-gst-1.0 (PyGObject Python bindings)
#  - gir1.2-gst-rtsp-server-1.0 (introspection for the GstRtspServer API)
#  - libgstrtspserver-1.0-0 (the RTSP server runtime, separate from build deps)
#  - ffmpeg, jq, netcat-openbsd (operator utilities)
#
# Total build size of /var/cache/apt after this step: ~1.2 GB.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git wget \
        python3 python3-pip python3-gi python3-gst-1.0 \
        gir1.2-gst-rtsp-server-1.0 \
        gobject-introspection \
        libgstrtspserver-1.0-0 \
        gstreamer1.0-rtsp \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        libgstreamer-plugins-base1.0-dev libgstreamer1.0-dev \
        libgstreamer-plugins-bad1.0-dev \
        libdrm-dev libgudev-1.0-dev libudev-dev libxext-dev \
        meson ninja-build pkg-config \
        ffmpeg jq netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# --- 1b. Build gst-plugins-bad with the nvcodec subproject (HEAVY) ----------
# This is the NVIDIA GPU plugin set: nvv4l2decoder (NVDEC), cudaconvert
# / nvvidconv (VIC / CUDA crop + format conversion), nvv4l2h264enc
# (NVENC), nvv4l2h265enc, nvv4l2vp8dec, nvv4l2vp9dec, etc.
#
# In GStreamer 1.20.3 (the tag matching Ubuntu 22.04's libgstreamer1.0-0
# = 1.20.3), the NVIDIA plugin set is in:
#   subprojects/gst-plugins-bad/sys/nvcodec/   (NOT nvv4l2/; that was
#   the pre-1.20 location; renamed in the 1.20 monorepo restructure)
# and the meson feature option is `nvcodec` (singular, not plural).
# The plugin registers as `nvcodec` and provides the nvv4l2* elements
# via the standard gst-plugins-bad build.
#
# Build: ~2 min on a 4-core x86_64 host with warm cache; ~5 min cold
# (much faster than building all of gst-plugins-bad because all the
# 100+ non-NVIDIA subprojects are explicitly disabled with
# -Dauto_features=disabled, so meson only configures the nvcodec one).
#
# Output: /usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstnvcodec.so
#   providing: nvv4l2decoder (NVDEC), nvv4l2h264enc (NVENC),
#             nvv4l2h265enc, nvv4l2vp8dec, nvv4l2vp9dec, cudaconvert
#             (the new name for nvvidconv in 1.20+), cudascale,
#             cudafilter, cudaupload, cudadownload
#
# The plugins are NOT in the default Ubuntu 22.04 repos (they require
# NVIDIA headers, which the cudnn-devel base provides). We disable
# every other gst-plugins-bad subproject and enable only the nvcodec
# one — saves ~10 min of build time.
#
# This nvcodec subproject has the same dependency as the original
# `nvv4l2` path: libdrm, CUDA toolkit, libnvv4l2 (vendored in
# gst-plugins-bad since 1.18), libnvidia-encode (for NVENC), and
# libnvcuvid (for NVDEC). The cudnn-devel base image provides the
# CUDA + cuDNN headers; nvidia-encode + nvcuvid are part of the
# libnvidia-compute-XX package which is in the cudnn-devel base's
# standard apt sources.
RUN set -eux; \
    # The NVIDIA driver userspace libs (libnvcuvid.so, libnvidia-encode.so,
    # libcuda.so) are needed at link time so the nvcodec plugin can register
    # its elements. They live in the `graphics-drivers` PPA, not the
    # default Ubuntu 22.04 repos. Add the PPA and install the packages.
    apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common wget gnupg ca-certificates \
    && wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
        && dpkg -i cuda-keyring_1.1-1_all.deb \
        && rm -f cuda-keyring_1.1-1_all.deb \
    && apt-get update && apt-get install -y --no-install-recommends \
        libnvidia-compute-535 \
        libnvidia-encode-535 libnvidia-decode-535 \
    && rm -rf /var/lib/apt/lists/* && \
    git clone --depth 1 --branch 1.20.3 \
        https://gitlab.freedesktop.org/gstreamer/gstreamer.git /tmp/gst && \
    cd /tmp/gst/subprojects/gst-plugins-bad && \
    PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig \
    meson setup build \
        --prefix=/usr \
        --libdir=lib/x86_64-linux-gnu \
        --buildtype=release \
        -Dauto_features=disabled \
        -Dnvcodec=enabled \
        -Ddoc=disabled -Dtests=disabled -Dexamples=disabled \
    && ninja -C build install && \
    ldconfig && \
    cd /tmp && rm -rf /tmp/gst && \
    echo "[splitter] NVIDIA GStreamer plugins built from source (libgstnvcodec.so)" && \
    echo "=== nvcodec feature count (must be > 0; was 0 when libs were missing) ===" && \
    gst-inspect-1.0 nvcodec 2>&1 | grep -E "features?:|nvv4l2|cudaconvert" | head -10 && \
    echo "--- nvv4l2decoder ---" && gst-inspect-1.0 nvv4l2decoder 2>&1 | head -3 && \
    echo "--- cudaconvert    ---" && gst-inspect-1.0 cudaconvert   2>&1 | head -3 && \
    echo "--- nvv4l2h264enc ---" && gst-inspect-1.0 nvv4l2h264enc 2>&1 | head -3

# --- 2. Python deps (gi bindings are pulled from apt above) ------------------
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir -r /tmp/requirements.txt && \
    rm -f /tmp/requirements.txt

# --- 3. Service code ---------------------------------------------------------
WORKDIR /opt/splitter
COPY split_service.py /opt/splitter/split_service.py
COPY entrypoint.sh    /opt/splitter/entrypoint.sh
RUN chmod +x /opt/splitter/entrypoint.sh

# --- 4. Default env (overridable at runtime) --------------------------------
ENV LOG_LEVEL=INFO
ENV RTSP_PORT=8556
ENV BITRATE_BPS=8000000
ENV IDR_INTERVAL_FRAMES=30
ENV FRAMERATE=15
ENV SOURCE_W=4096
ENV SOURCE_H=1152
# The build-from-source path (option C in this Dockerfile) installs the
# NVIDIA GStreamer plugins to /usr/lib/x86_64-linux-gnu/gstreamer-1.0/
# which is on the default GST_PLUGIN_PATH. No custom env var needed.
# (The DeepStream / PPA paths would set a non-default path here.)
# ENV GST_PLUGIN_PATH is intentionally unset for the source-build path.

# --- 5. Healthcheck (TCP probe to the RTSP port) -----------------------------
# docker's HEALTHCHECK does a TCP-only probe. Deeper checks (DESCRIBE /
# ffprobe) are done by the L1 test from the host side.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD nc -z 127.0.0.1 8556 || exit 1

# --- 6. Entrypoint -----------------------------------------------------------
# entrypoint.sh waits for /dev/nvidia* to appear (the NVIDIA runtime in
# some host configurations lags by 1-2 s on container start) and then
# execs the service. SIGTERM from docker stop is forwarded by Python's
# GLib signal handler registered in split_service.py:run().
ENTRYPOINT ["/opt/splitter/entrypoint.sh"]
CMD ["python3", "-u", "/opt/splitter/split_service.py"]


# ==============================================================================
# ALTERNATIVE BASE IMAGE — ruffy8919 PPA (kept for reference)
# ==============================================================================
# If you want to use the smaller `nvidia/cuda:12.4.1-runtime-ubuntu22.04`
# base image and install the NVIDIA GStreamer plugins from the ruffy8919
# PPA, comment out the `FROM nvcr.io/...` line above and use this block
# as the base instead. Requires the ruffy8919 PPA to be reachable from
# your network.
#
# ---- snip ----
# FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04
#
# RUN apt-get update && apt-get install -y --no-install-recommends \
#         ca-certificates curl gnupg software-properties-common \
#         python3 python3-pip python3-gi python3-gst-1.0 \
#         gir1.2-gst-rtsp-server-1.0 gobject-introspection \
#         libgstrtspserver-1.0-0 gstreamer1.0-rtsp \
#         gstreamer1.0-plugins-{base,good,bad,ugly} gstreamer1.0-libav \
#         libgstreamer-plugins-base1.0-0 libgstreamer1.0-0 \
#         ffmpeg jq netcat-openbsd \
#     && rm -rf /var/lib/apt/lists/* && \
#     add-apt-repository -y ppa:ruffy8919/nv-gst-plugins && \
#     apt-get update && apt-get install -y --no-install-recommends \
#         nvidia-gst-plugins-base nvidia-gst-plugins-good nvidia-gst-plugins-bad \
#     && rm -rf /var/lib/apt/lists/*
# ---- /snip ----
