#!/bin/bash
# nosana-start.sh — Nosana node launcher with speed spoofing (v0.02.0)
#
# For use on Proxmox VM where CPU/topology spoofing is handled at the
# hypervisor level. This wrapper handles:
#   1. Patching the official start.sh to add persistent podman storage
#   2. Auto-injecting the fake stats image for network speed spoofing
#
# Usage: ./nosana-start.sh [nosana start.sh args...]
#   e.g. ./nosana-start.sh --pre-release --verbose
#
# Version: 0.02.0
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
START_URL="https://nosana.com/start.sh"
STATS_IMAGE="nosana/stats:v1.2.1"
REGISTRY_PREFIX="registry.hub.docker.com"
VOLUME_NAME="nosana-podman-storage"
PODMAN_READY_TIMEOUT=60

echo "=== nosana-start.sh v0.02.0 — Nosana Node Launcher (speed spoof) ==="
echo ""

# --- Pre-flight: check for Dockerfile.stats and fake-fast ---
BUILD_DIR=""
if [ -f "./Dockerfile.stats" ] && [ -f "./fake-fast" ]; then
    BUILD_DIR="."
elif [ -f "${SCRIPT_DIR}/Dockerfile.stats" ] && [ -f "${SCRIPT_DIR}/fake-fast" ]; then
    BUILD_DIR="${SCRIPT_DIR}"
else
    echo "WARN: Dockerfile.stats / fake-fast not found."
    echo "      Speed spoofing will be skipped. Only persistent storage will be added."
    echo "      To enable speed spoofing, ensure Dockerfile.stats and fake-fast are"
    echo "      in the same directory as this script."
    echo ""
fi

# --- Pre-build the fake stats image (if build files available) ---
if [ -n "${BUILD_DIR}" ]; then
    echo "[..] Pre-building fake stats image..."
    docker build -t "${STATS_IMAGE}" -f "${BUILD_DIR}/Dockerfile.stats" "${BUILD_DIR}" --quiet
    docker tag "${STATS_IMAGE}" "${REGISTRY_PREFIX}/${STATS_IMAGE}"
    echo "[OK] Fake stats image built and tagged"
    echo ""
fi

# --- Download official start.sh ---
echo "[..] Downloading ${START_URL}..."
ORIG_SCRIPT=$(wget -qO- "${START_URL}")
if [ -z "${ORIG_SCRIPT}" ]; then
    echo "ERROR: Failed to download start.sh from ${START_URL}"
    exit 1
fi
echo "[OK] Downloaded start.sh ($(echo "${ORIG_SCRIPT}" | wc -l) lines)"

# --- Patch: Add persistent podman storage volume ---
# The official start.sh runs a "podman" Docker container with `docker run`.
# We inject a named volume mount so podman's image cache survives container restarts.
#
# Target pattern in start.sh (the podman container's docker run):
#   docker run ... --name podman ...
# We inject: -v nosana-podman-storage:/var/lib/containers/storage
#
# Strategy: Insert volume mount flag before "--name podman" in the docker run command.
VOLUME_FLAG="-v ${VOLUME_NAME}:/var/lib/containers/storage"

PATCHED_SCRIPT=$(echo "${ORIG_SCRIPT}" | sed "s|--name podman|${VOLUME_FLAG} --name podman|g")

# Verify injection worked
VOLUME_COUNT=$(echo "${PATCHED_SCRIPT}" | grep -c "${VOLUME_NAME}" || true)
if [ "${VOLUME_COUNT}" -gt 0 ]; then
    echo "[OK] Injected persistent podman storage volume (${VOLUME_COUNT} point(s))"
else
    echo "WARN: Could not inject podman storage volume."
    echo "      '--name podman' pattern not found in start.sh — script may have changed."
    echo "      Continuing without persistent storage (speed spoof will need re-injection on restart)."
    PATCHED_SCRIPT="${ORIG_SCRIPT}"
fi

# --- Launch nosana (in background so we can inject after startup) ---
echo ""
echo "Launching nosana-node..."
echo "======================================="
echo ""

TMPSCRIPT=$(mktemp /tmp/nosana-start-XXXXXX.sh)
echo "${PATCHED_SCRIPT}" > "${TMPSCRIPT}"
chmod +x "${TMPSCRIPT}"

# Run in background so we can inject the fake image after podman starts
bash "${TMPSCRIPT}" "$@" </dev/tty &
NOSANA_PID=$!

# --- Wait for podman container to be ready, then inject fake image ---
if [ -n "${BUILD_DIR}" ]; then
    echo ""
    echo "[..] Waiting for podman container to start..."
    PODMAN_READY=0
    for i in $(seq 1 "${PODMAN_READY_TIMEOUT}"); do
        if docker exec podman podman info >/dev/null 2>&1; then
            PODMAN_READY=1
            break
        fi
        sleep 2
    done

    if [ "${PODMAN_READY}" -eq 1 ]; then
        echo "[OK] podman container is ready (waited ~$((i * 2))s)"

        # Check if fake image is already loaded (from persistent storage)
        FAKE_CHECK=$(docker exec podman podman run --rm \
            "${REGISTRY_PREFIX}/${STATS_IMAGE}" fast --json 2>/dev/null || true)

        if echo "${FAKE_CHECK}" | grep -q '"uploadSpeed":1041'; then
            echo "[OK] Fake stats image already loaded (persistent storage)"
        else
            echo "[..] Loading fake stats image into podman..."
            docker save "${REGISTRY_PREFIX}/${STATS_IMAGE}" | \
                docker exec -i podman podman load
            docker exec podman podman tag \
                "${REGISTRY_PREFIX}/${STATS_IMAGE}" \
                "docker.io/${STATS_IMAGE}"
            echo "[OK] Fake stats image loaded"
        fi
    else
        echo "WARN: podman container not ready after ${PODMAN_READY_TIMEOUT}s."
        echo "      Run speed-spoof.sh manually after the stack is up."
    fi
fi

# --- Wait for nosana process ---
echo ""
echo "[OK] Speed spoof active. Waiting for nosana-node process..."
wait ${NOSANA_PID} 2>/dev/null
EXITCODE=$?
rm -f "${TMPSCRIPT}"
exit ${EXITCODE}
