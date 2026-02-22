#!/bin/bash
# mixer.sh — Build libhwcompat.so and deploy to ~/.nosana/ (+ multi-GPU dirs)
# Version: 0.01.2
set -euo pipefail

IMAGE_NAME="mixercont"
LIB_NAME="libhwcompat.so"
NOSANA_DIR="$HOME/.nosana"
REPO_URL="https://github.com/MachoDrone/bread-maker-mod.git"
REPO_BRANCH="feat/nosana-deploy-v0.01.1"

echo "=== mixer.sh — Build & Deploy ==="
echo ""

# --- Step 1: Build the image ---
echo "[1/4] Building Docker image '${IMAGE_NAME}'..."

# Detect script directory (works when run locally, not when piped)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" 2>/dev/null && pwd)" || SCRIPT_DIR=""

BUILD_DIR=""
CLEANUP_BUILD=""

if [ -n "$SCRIPT_DIR" ] && [ -f "${SCRIPT_DIR}/Dockerfile" ]; then
    BUILD_DIR="${SCRIPT_DIR}"
    echo "       Building from local: ${BUILD_DIR}"
else
    # Piped execution — clone repo to temp dir
    BUILD_DIR=$(mktemp -d)
    CLEANUP_BUILD="${BUILD_DIR}"
    echo "       No local Dockerfile — cloning from GitHub..."
    git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${BUILD_DIR}" 2>&1 | sed 's/^/       /'
fi

docker build -t "${IMAGE_NAME}" "${BUILD_DIR}" --quiet
echo "       Image built successfully"

# Clean up temp clone if we made one
if [ -n "${CLEANUP_BUILD}" ]; then
    rm -rf "${CLEANUP_BUILD}"
fi
echo ""

# --- Step 2: Extract .so from image ---
echo "[2/4] Extracting ${LIB_NAME}..."
TMPCONTAINER=$(docker create "${IMAGE_NAME}")
docker cp "${TMPCONTAINER}:/app/${LIB_NAME}" "/tmp/${LIB_NAME}"
docker rm "${TMPCONTAINER}" >/dev/null
echo "       Extracted to /tmp/${LIB_NAME}"
echo ""

# --- Step 3: Deploy to ~/.nosana/ ---
echo "[3/4] Deploying to ${NOSANA_DIR}/..."
if [ ! -d "${NOSANA_DIR}" ]; then
    echo "ERROR: ${NOSANA_DIR} does not exist. Is nosana-node installed?"
    exit 1
fi
cp "/tmp/${LIB_NAME}" "${NOSANA_DIR}/${LIB_NAME}"
chmod 644 "${NOSANA_DIR}/${LIB_NAME}"
echo "       Copied to ${NOSANA_DIR}/${LIB_NAME}"

# --- Step 4: Multi-GPU auto-detect ---
GPU_COUNT=0
for gpu_dir in "$HOME"/.nosana-gpu*/; do
    [ -d "$gpu_dir" ] || continue
    cp "/tmp/${LIB_NAME}" "${gpu_dir}/${LIB_NAME}"
    chmod 644 "${gpu_dir}/${LIB_NAME}"
    echo "       Copied to ${gpu_dir}${LIB_NAME}"
    GPU_COUNT=$((GPU_COUNT + 1))
done
echo ""

# --- Step 5: Verify ---
echo "[4/4] Verification:"
ls -la "${NOSANA_DIR}/${LIB_NAME}"
for gpu_dir in "$HOME"/.nosana-gpu*/; do
    [ -d "$gpu_dir" ] || continue
    ls -la "${gpu_dir}${LIB_NAME}"
done
echo ""

# --- Summary ---
echo "=== Deploy Summary ==="
echo "  Library:    ${LIB_NAME}"
echo "  Primary:    ${NOSANA_DIR}/${LIB_NAME}"
if [ "$GPU_COUNT" -gt 0 ]; then
    echo "  Multi-GPU:  ${GPU_COUNT} additional director(ies)"
fi
echo ""
echo "Next: run ./nosana-start.sh to launch nosana-node with spoof active"
echo "  Or for custom docker commands, add these flags:"
echo "  -e LD_PRELOAD=/root/.nosana/${LIB_NAME} -e _MC_C=1 -e _MC_T=1 -e _MC_K=1"
