#!/bin/sh
# ==============================================================================
# frigate-init.sh — one-shot container init for the Frigate image
#
# Replaces the legacy `command:` in docker-compose.calypso.yml (which used to
# end in `exec python3 -u -m frigate`, creating a duplicate Frigate process
# that fought the s6-supervised one for the MQTT client_id and crashed the
# container on shutdown).
#
# Wired via docker-compose:
#   - bind-mount: ./frigate-init.sh:/etc/s6-overlay/scripts/frigate-init.sh:ro
#   - env:        S6_STAGE2_HOOK=/etc/s6-overlay/scripts/frigate-init.sh
#
# Runs once, before s6-rc brings up the s6-supervised `frigate` service.
# ==============================================================================
set -eu

# 1) Make TRT 10.9.0 (Blackwell SM 120) runtime libs visible to the dynamic
#    linker. /trt-libs is bind-mounted from the host (see docker-compose).
if [ -d /trt-libs ]; then
    echo "[frigate-init] registering /trt-libs in ld.so.conf.d/tensorrt.conf"
    echo '/trt-libs' > /etc/ld.so.conf.d/tensorrt.conf
    ldconfig
else
    echo "[frigate-init] WARNING: /trt-libs not present, skipping ldconfig update"
fi

# 2) The Frigate s6 service invokes /usr/lib/ffmpeg/bin/ffmpeg (without the
#    versioned 7.0 segment). The base image ships it under
#    /usr/lib/ffmpeg/7.0/bin/, so create a stable symlink.
if [ -d /usr/lib/ffmpeg/7.0/bin ] && [ ! -e /usr/lib/ffmpeg/bin ]; then
    echo "[frigate-init] symlinking /usr/lib/ffmpeg/bin -> /usr/lib/ffmpeg/7.0/bin"
    ln -sfn /usr/lib/ffmpeg/7.0/bin /usr/lib/ffmpeg/bin
fi

echo "[frigate-init] init complete"
exit 0
