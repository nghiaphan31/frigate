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

# 0) Fail-fast storage pool verification (defense-in-depth).
#    Ensures /media/frigate is mounted from the host Btrfs RAID6 storage pool
#    and prevents 24/7 NVR recording streams from flooding the host NVMe rootfs.
MEDIA_DIR="/media/frigate"
echo "[frigate-init] verifying storage pool mount at ${MEDIA_DIR}..."

if [ ! -d "${MEDIA_DIR}" ]; then
    echo "[frigate-init] FATAL: Storage directory ${MEDIA_DIR} does not exist!" >&2
    exit 1
fi

ROOT_DEV=$(stat -c %d /)
MEDIA_DEV=$(stat -c %d "${MEDIA_DIR}")

if [ "${ROOT_DEV}" -eq "${MEDIA_DEV}" ]; then
    echo "[frigate-init] FATAL: ${MEDIA_DIR} is on container rootfs (device ${MEDIA_DEV}), not mounted from host storage!" >&2
    exit 1
fi

if [ ! -f "${MEDIA_DIR}/.storage_pool_ready" ]; then
    echo "[frigate-init] FATAL: Canary marker ${MEDIA_DIR}/.storage_pool_ready missing! Host Btrfs RAID6 pool is not mounted or path is on host NVMe rootfs." >&2
    exit 1
fi

echo "[frigate-init] storage pool verified successfully (mount device: ${MEDIA_DEV}, canary verified)"

# 0b) Verify shared memory (/dev/shm) allocation.
#     Frigate decodes 8 concurrent 4K camera streams in raw YUV420.
#     A default Docker shm size (64MB) causes immediate OOM crashes.
MIN_SHM_MB=2048
SHM_TOTAL_MB=$(df -m /dev/shm 2>/dev/null | awk 'NR>1 {print $2}' || echo 0)
if [ "${SHM_TOTAL_MB}" -lt "${MIN_SHM_MB}" ]; then
    echo "[frigate-init] FATAL: /dev/shm is too small (${SHM_TOTAL_MB}MB < ${MIN_SHM_MB}MB)! Ensure shm_size is set in docker-compose." >&2
    exit 1
fi
echo "[frigate-init] shared memory verified (${SHM_TOTAL_MB}MB >= ${MIN_SHM_MB}MB)"

# 0c) Verify write capability on /media/frigate
WRITE_TEST="${MEDIA_DIR}/.write_test_$$"
if ! touch "${WRITE_TEST}" 2>/dev/null; then
    echo "[frigate-init] FATAL: Storage directory ${MEDIA_DIR} is not writable by current user!" >&2
    exit 1
fi
rm -f "${WRITE_TEST}"
echo "[frigate-init] storage write permissions verified on ${MEDIA_DIR}"

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
