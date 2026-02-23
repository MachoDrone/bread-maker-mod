#!/bin/bash
# speed-spoof.sh — Build & inject fake stats image into running nosana podman container
# Can be run manually at any time while the nosana stack is running.
# Requires: Docker, running "podman" container (from nosana stack)
#
# Version: 0.02.1
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
STATS_IMAGE="nosana/stats:v1.2.1"
REGISTRY_PREFIX="registry.hub.docker.com"

echo "=== Speed Spoof — Inject fake stats image ==="
echo ""

# --- Pre-flight: podman container must be running ---
if ! docker inspect podman >/dev/null 2>&1; then
    echo "ERROR: 'podman' container not found. Is the nosana stack running?"
    echo "       Start nosana first, then re-run this script."
    exit 1
fi
echo "[OK] podman container is running"

# --- Step 1: Build fake image ---
echo ""
echo "[1/4] Building fake stats image..."

# Find Dockerfile.stats: check current dir, then script dir
BUILD_DIR=""
if [ -f "./Dockerfile.stats" ]; then
    BUILD_DIR="."
elif [ -f "${SCRIPT_DIR}/Dockerfile.stats" ]; then
    BUILD_DIR="${SCRIPT_DIR}"
else
    echo "ERROR: Dockerfile.stats not found in current dir or script dir."
    exit 1
fi

docker build -t "${STATS_IMAGE}" -f "${BUILD_DIR}/Dockerfile.stats" "${BUILD_DIR}" --quiet
echo "       Built ${STATS_IMAGE}"

# --- Step 2: Tag with registry prefix ---
echo ""
echo "[2/4] Tagging with registry prefix..."
docker tag "${STATS_IMAGE}" "${REGISTRY_PREFIX}/${STATS_IMAGE}"
echo "       Tagged as ${REGISTRY_PREFIX}/${STATS_IMAGE}"

# --- Step 3: Load into podman container ---
echo ""
echo "[3/4] Loading into podman..."
docker save "${REGISTRY_PREFIX}/${STATS_IMAGE}" | \
    docker exec -i podman podman load
echo "       Loaded ${REGISTRY_PREFIX}/${STATS_IMAGE}"

# Also tag inside podman for docker.io prefix (belt + suspenders)
docker exec podman podman tag \
    "${REGISTRY_PREFIX}/${STATS_IMAGE}" \
    "docker.io/${STATS_IMAGE}"
echo "       Tagged docker.io/${STATS_IMAGE} inside podman"

# --- Step 4: Verify ---
echo ""
echo "[4/4] Verifying..."
VERIFY_OUTPUT=$(docker exec podman podman run --rm \
    "${REGISTRY_PREFIX}/${STATS_IMAGE}" fast --json 2>&1)
echo "       Output: ${VERIFY_OUTPUT}"

if echo "${VERIFY_OUTPUT}" | grep -q '"uploadSpeed":1041'; then
    echo ""
    echo "[OK] Speed spoof is active."
    echo "     Next specs check will report spoofed speeds."
    echo ""
    echo "     Note: If the podman container is recreated, re-run this script"
    echo "     or use nosana-start.sh which handles injection automatically."
else
    echo ""
    echo "[WARN] Verification failed — unexpected output."
    echo "       Check manually: docker exec podman podman run --rm ${REGISTRY_PREFIX}/${STATS_IMAGE} fast --json"
    exit 1
fi
