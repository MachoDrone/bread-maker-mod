#!/bin/bash
# nosana-start.sh — Wrapper around official nosana start.sh
# Injects LD_PRELOAD + _MC_* env vars into the nosana-node docker run command
# Version: 0.01.3
set -eo pipefail

LIB_NAME="libhwcompat.so"
NOSANA_DIR="$HOME/.nosana"
START_URL="https://nosana.com/start.sh"

echo "=== nosana-start.sh — Nosana Node Launcher (spoofed) ==="
echo ""

# --- Pre-flight: library must exist ---
if [ ! -f "${NOSANA_DIR}/${LIB_NAME}" ]; then
    echo "ERROR: ${NOSANA_DIR}/${LIB_NAME} not found."
    echo "       Run ./mixer.sh first to build and deploy the library."
    exit 1
fi
echo "[OK] Library found: ${NOSANA_DIR}/${LIB_NAME}"

# --- Download official start.sh ---
echo "[..] Downloading ${START_URL}..."
ORIG_SCRIPT=$(wget -qO- "${START_URL}")
if [ -z "${ORIG_SCRIPT}" ]; then
    echo "ERROR: Failed to download start.sh from ${START_URL}"
    exit 1
fi
echo "[OK] Downloaded start.sh ($(echo "${ORIG_SCRIPT}" | wc -l) lines)"

# --- Inject env vars ---
# The official start.sh has:
#   docker run \
#     ${DOCKER_ARGS[@]} \
#     nosana/nosana-cli:latest ...
# We insert our DOCKER_ARGS append BEFORE the "docker run \" line
# so it's a standalone statement, not inside the multi-line command.
INJECT_LINE='    DOCKER_ARGS+=(-e LD_PRELOAD=/root/.nosana/libhwcompat.so -e _MC_C=1 -e _MC_T=1 -e _MC_K=1)'

PATCHED_SCRIPT=$(echo "${ORIG_SCRIPT}" | sed "/^[[:space:]]*docker run[[:space:]]*\\\\$/i\\
${INJECT_LINE}")

# Verify injection worked
INJECT_COUNT=$(echo "${PATCHED_SCRIPT}" | grep -c '_MC_C=1' || true)
if [ "${INJECT_COUNT}" -eq 0 ]; then
    echo "ERROR: Injection failed — could not find 'docker run \\' in start.sh"
    echo "       The official script may have changed format."
    exit 1
fi
echo "[OK] Injected env vars (${INJECT_COUNT} injection point(s))"

# --- Launch ---
echo ""
echo "Launching nosana-node with spoof active..."
echo "  LD_PRELOAD=/root/.nosana/${LIB_NAME}"
echo "  _MC_C=1  _MC_T=1  _MC_K=1"
echo "======================================="
echo ""

# Pass through any user args (--pre-release, --verbose, etc.)
echo "${PATCHED_SCRIPT}" | bash -s -- "$@"
