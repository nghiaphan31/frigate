#!/bin/sh
# ==============================================================================
# splitter/entrypoint.sh — container entrypoint for the splitter service
# ==============================================================================
# 1. Wait for the NVIDIA device nodes to be visible. With the nvidia
#    runtime, the device nodes (and their udev rules) are mounted into
#    the container by the runtime, but on slow hosts this can lag 1-2 s
#    after the container's filesystem is up. If we don't wait, the
#    nvv4l2* plugins fail to initialise with "No such device" and the
#    pipeline errors out on the first DESCRIBE.
#
# 2. Sanity-check that the NVIDIA GStreamer plugins are present. If
#    they're missing, the service would happily start with stub elements
#    and the failure would only show up at first stream connect. We
#    fail loud and fast here instead.
#
# 3. Set GStreamer debug env (GST_DEBUG) so the operator can see what's
#    happening in `docker logs splitter`. Default is GST_DEBUG=2 (errors
#    + warnings). Set GST_DEBUG=3 or higher in the env for more verbosity.
#
# 4. exec the service. exec is critical: docker stop sends SIGTERM to
#    PID 1; if we don't exec, the entrypoint shell (not Python) is PID 1
#    and the signal never reaches the GLib main loop. Python's
#    GLib.unix_signal_add() in split_service.py:run() handles SIGTERM
#    and triggers a clean shutdown of the RTSP server.
# ==============================================================================
set -eu

NVIDIA_DEVS="/dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/nvidia-uvm-tools"
NVIDIA_WAIT_TIMEOUT="${NVIDIA_WAIT_TIMEOUT:-30}"   # seconds
i=0
while [ $i -lt "$NVIDIA_WAIT_TIMEOUT" ]; do
    if [ -e /dev/nvidia0 ] && [ -e /dev/nvidia-uvm ]; then
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ ! -e /dev/nvidia0 ] || [ ! -e /dev/nvidia-uvm ]; then
    echo "[entrypoint] FATAL: NVIDIA devices not visible after ${NVIDIA_WAIT_TIMEOUT}s" >&2
    echo "[entrypoint] expected: $NVIDIA_DEVS" >&2
    echo "[entrypoint] got: $(ls -1 /dev/nvidia* 2>/dev/null || echo '(none)')" >&2
    exit 1
fi
echo "[entrypoint] NVIDIA devices visible"

# Sanity check: the libgstnvcodec.so must be installed (either from a
# PPA package, the DeepStream base image, or our build-from-source path
# in the Dockerfile). The check is at the .so level rather than the
# dpkg level so it works for all 3 install paths.
NVCODEC_SO=$(find /usr/lib /usr/local/lib -name 'libgstnvcodec.so' 2>/dev/null | head -1)
if [ -z "$NVCODEC_SO" ]; then
    echo "[entrypoint] FATAL: libgstnvcodec.so not found" >&2
    echo "[entrypoint]   The NVIDIA GStreamer plugins are NOT installed in this image." >&2
    echo "[entrypoint]   See the Dockerfile comments for 3 install paths:" >&2
    echo "[entrypoint]     (A) build from source (the current default — should be present)" >&2
    echo "[entrypoint]     (B) DeepStream base image (requires nvcr.io login)" >&2
    echo "[entrypoint]     (C) ruffy8919 PPA (works if the PPA is reachable)" >&2
    exit 1
fi
echo "[entrypoint] libgstnvcodec.so found at $NVCODEC_SO"

# Verify the actual GStreamer elements are loadable. This is a deeper
# check than the .so existence: the plugin must be on the GST_PLUGIN_PATH
# and must not have missing symbol dependencies. We check both the
# old element names (nvv4l2*, used pre-1.20 and by our split_service.py
# pipeline) and the new ones (cudaconvert, which replaced nvvidconv in
# 1.20+). At least one of each pair must be present.
for elem in nvv4l2decoder nvv4l2h264enc cudaconvert; do
    if ! gst-inspect-1.0 "$elem" >/dev/null 2>&1; then
        echo "[entrypoint] FATAL: gst-inspect-1.0 $elem failed (plugin not loadable)" >&2
        echo "[entrypoint]   libgstnvcodec.so is installed at $NVCODEC_SO but the" >&2
        echo "[entrypoint]   element '$elem' is not registered. Common causes:" >&2
        echo "[entrypoint]     - The .so failed to load (check 'gst-inspect-1.0 nvcodec')" >&2
        echo "[entrypoint]     - A symbol dependency is missing (libnvidia-encode," >&2
        echo "[entrypoint]       libnvcuvid, libcudart) — should be in cudnn-devel base" >&2
        exit 1
    fi
done
echo "[entrypoint] NVIDIA GStreamer elements loadable: nvv4l2decoder, nvv4l2h264enc, cudaconvert"

# Default GST_DEBUG to 2 (ERROR+WARN). Operator can override in compose.
export GST_DEBUG="${GST_DEBUG:-2}"

# Cache the GST registry scan in a tmpfs (the default $HOME/.cache/gstreamer-1.0
# pollutes the image layer otherwise). The registry is rebuilt on each
# container start; caching it in /tmp is the recommended pattern.
export GST_REGISTRY_REUSE_PLUGIN_SCANS="1"

echo "[entrypoint] starting splitter service: $@"
exec "$@"
