#!/bin/bash
# mixer-start.sh — Standalone spoof + watchdog for Nosana VMs
# Run on VM: bash <(wget -qO- https://raw.githubusercontent.com/<repo>/feat/nosana-deploy-v0.01.1/mixer-start.sh)
#
# First run:  generates random speed values, builds fake stats image, injects into podman, installs watchdog
# Subsequent: reuses existing build files, checks if image needs re-injection
#
# Version: 0.03.2
set -eo pipefail

SPOOF_DIR="/opt/mixer-spoof"
STATS_IMAGE="nosana/stats:v1.2.1"
REGISTRY_PREFIX="registry.hub.docker.com"
WATCHDOG_CRON="/etc/cron.d/mixer-watchdog"
WATCHDOG_SCRIPT="${SPOOF_DIR}/mixer-watchdog.sh"
CONFIG_FILE="${SPOOF_DIR}/.mixer-config"
LOG_TAG="mixer-start"

# --- Logging ---
log_info()  { echo "[OK]    $(date '+%H:%M:%S') $*"; }
log_step()  { echo "[..]    $(date '+%H:%M:%S') $*"; }
log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }

# --- Require root ---
if [ "$(id -u)" -ne 0 ]; then
    log_error "Must run as root"
    exit 1
fi

# --- Require docker ---
if ! command -v docker >/dev/null 2>&1; then
    log_error "docker not found"
    exit 1
fi

mkdir -p "${SPOOF_DIR}"

# ============================================================
# Phase 1: Generate or reuse spoof files
# ============================================================

if [ -f "${SPOOF_DIR}/fake-fast" ] && [ -f "${SPOOF_DIR}/Dockerfile.stats" ]; then
    log_info "Existing build files found — reusing"
    # Load saved values for logging
    if [ -f "${CONFIG_FILE}" ]; then
        source "${CONFIG_FILE}"
        log_info "Speeds: dl=${DL} ul=${UL} lat=${LAT}"
    fi
else
    log_step "Generating random speed values..."
    DL=$((RANDOM % 96 + 1004))    # 1004-1099
    UL=$((RANDOM % 96 + 1004))    # 1004-1099
    LAT=$((RANDOM % 8 + 5))       # 5-12
    log_info "Generated: dl=${DL} ul=${UL} lat=${LAT}"

    # Save config so watchdog uses same values
    cat > "${CONFIG_FILE}" <<EOF
DL=${DL}
UL=${UL}
LAT=${LAT}
EOF

    # Write fake-fast script
    cat > "${SPOOF_DIR}/fake-fast" <<FAKESCRIPT
#!/bin/bash
echo '{"downloadSpeed":${DL},"uploadSpeed":${UL},"latency":${LAT}}'
FAKESCRIPT
    chmod +x "${SPOOF_DIR}/fake-fast"

    # Write Dockerfile.stats (speed-only, no GPU UUID wrapper — epyc-4464p profile)
    cat > "${SPOOF_DIR}/Dockerfile.stats" <<'DOCKERFILE'
FROM nosana/stats:v1.2.1

# Speed spoof: replace fast binary
COPY fake-fast /usr/local/bin/fast
RUN chmod +x /usr/local/bin/fast
DOCKERFILE

    log_info "Build files written to ${SPOOF_DIR}"
fi

# ============================================================
# Phase 2: Build fake stats image
# ============================================================

log_step "Building fake stats image..."
if docker build -t "${STATS_IMAGE}" -f "${SPOOF_DIR}/Dockerfile.stats" "${SPOOF_DIR}" --quiet >/dev/null 2>&1; then
    docker tag "${STATS_IMAGE}" "${REGISTRY_PREFIX}/${STATS_IMAGE}" 2>/dev/null || true
    log_info "Fake stats image built"
else
    log_error "Docker build failed"
    exit 1
fi

# ============================================================
# Phase 3: Inject into podman (if running)
# ============================================================

if docker inspect podman >/dev/null 2>&1; then
    log_step "Podman container detected — checking if image needs injection..."

    # Load expected values from config
    EXPECTED_DL=""
    if [ -f "${CONFIG_FILE}" ]; then
        source "${CONFIG_FILE}"
        EXPECTED_DL="${DL}"
    fi

    # Test if spoofed image is present AND matches our values
    NEEDS_INJECT="true"
    FAST_OUTPUT=$(docker exec podman podman run --rm --entrypoint /usr/local/bin/fast \
        "${REGISTRY_PREFIX}/${STATS_IMAGE}" --json 2>/dev/null || true)

    if echo "${FAST_OUTPUT}" | grep -q '"downloadSpeed"' 2>/dev/null; then
        # Image exists — check if values match
        if [ -n "${EXPECTED_DL}" ]; then
            ACTUAL_DL=$(echo "${FAST_OUTPUT}" | grep -o '"downloadSpeed":[0-9]*' | grep -o '[0-9]*$')
            if [ "${ACTUAL_DL}" = "${EXPECTED_DL}" ]; then
                NEEDS_INJECT="false"
                log_info "Spoofed image present with correct values — skipping injection"
            else
                log_step "Stale image detected (dl=${ACTUAL_DL}, expected=${EXPECTED_DL}) — re-injecting..."
            fi
        else
            NEEDS_INJECT="false"
            log_info "Spoofed image already present in podman — skipping injection"
        fi
    fi

    if [ "${NEEDS_INJECT}" = "true" ]; then
        log_step "Injecting fake stats image into podman..."
        if docker save "${REGISTRY_PREFIX}/${STATS_IMAGE}" | docker exec -i podman podman load >/dev/null 2>&1; then
            docker exec podman podman tag \
                "${REGISTRY_PREFIX}/${STATS_IMAGE}" \
                "docker.io/${STATS_IMAGE}" 2>/dev/null || true
            log_info "Fake stats image injected into podman"
        else
            log_error "Image injection failed"
        fi
    fi
else
    log_info "Podman container not running — image ready for when nosana starts"
fi

# ============================================================
# Phase 4: Install watchdog
# ============================================================

log_step "Installing watchdog..."

cat > "${WATCHDOG_SCRIPT}" <<'WATCHDOG'
#!/bin/bash
# mixer-watchdog.sh — Checks if spoofed stats image is present in podman, re-injects if missing
# Installed by mixer-start.sh. Runs via cron every 5 minutes.
# Silent on success, logs only on re-injection or error.

SPOOF_DIR="/opt/mixer-spoof"
STATS_IMAGE="nosana/stats:v1.2.1"
REGISTRY_PREFIX="registry.hub.docker.com"

# Exit silently if podman container isn't running
docker inspect podman >/dev/null 2>&1 || exit 0

# Check if spoofed image responds correctly (5s timeout)
FAST_OUTPUT=$(timeout 15 docker exec podman podman run --rm --entrypoint /usr/local/bin/fast \
    "${REGISTRY_PREFIX}/${STATS_IMAGE}" --json 2>/dev/null || true)

if echo "${FAST_OUTPUT}" | grep -q '"downloadSpeed"' 2>/dev/null; then
    # Image is present and working — exit silently
    exit 0
fi

# Image missing or broken — rebuild and re-inject
echo "$(date '+%Y-%m-%d %H:%M:%S') — Spoofed image missing, rebuilding..."

if [ ! -f "${SPOOF_DIR}/fake-fast" ] || [ ! -f "${SPOOF_DIR}/Dockerfile.stats" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') — ERROR: build files missing from ${SPOOF_DIR}"
    exit 1
fi

# Rebuild
if ! docker build -t "${STATS_IMAGE}" -f "${SPOOF_DIR}/Dockerfile.stats" "${SPOOF_DIR}" --quiet >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') — ERROR: docker build failed"
    exit 1
fi
docker tag "${STATS_IMAGE}" "${REGISTRY_PREFIX}/${STATS_IMAGE}" 2>/dev/null || true

# Re-inject
if docker save "${REGISTRY_PREFIX}/${STATS_IMAGE}" | docker exec -i podman podman load >/dev/null 2>&1; then
    docker exec podman podman tag \
        "${REGISTRY_PREFIX}/${STATS_IMAGE}" \
        "docker.io/${STATS_IMAGE}" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') — Rebuilt and injected spoofed stats image"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') — ERROR: injection into podman failed"
    exit 1
fi
WATCHDOG
chmod +x "${WATCHDOG_SCRIPT}"

# Install cron job
cat > "${WATCHDOG_CRON}" <<CRON
# mixer-watchdog — re-inject spoofed stats image if wiped
*/5 * * * * root ${WATCHDOG_SCRIPT} >> /var/log/mixer-watchdog.log 2>&1
CRON
chmod 644 "${WATCHDOG_CRON}"

log_info "Watchdog installed (${WATCHDOG_CRON})"

# ============================================================
# Done
# ============================================================

echo ""
log_info "=== mixer-start.sh complete ==="
echo "  Build files: ${SPOOF_DIR}/"
echo "  Watchdog:    ${WATCHDOG_CRON} (every 5 min)"
echo "  Log:         /var/log/mixer-watchdog.log"
echo ""
echo "  Start nosana separately:"
echo "    bash <(wget -qO- https://nosana.com/start.sh) --pre-release --verbose"
echo ""
