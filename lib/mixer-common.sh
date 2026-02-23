#!/bin/bash
# lib/mixer-common.sh — Shared utilities for mixer CLI
# Logging, colors, config loading, state file helpers, random generators
#
# Version: 0.03.0

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Paths ---
MIXER_VERSION="0.03.0"
MIXER_BASE="/opt/mixer"
MIXER_ETC="/etc/mixer"
MIXER_STATE_DIR="${MIXER_ETC}/vms"
MIXER_SSH_DIR="${MIXER_ETC}/ssh"
MIXER_SSH_KEY="${MIXER_SSH_DIR}/mixer_key"
MIXER_CONFIG="${MIXER_ETC}/config.json"
MIXER_GPU_STATE="${MIXER_ETC}/gpu.json"
MIXER_CATALOG="${MIXER_BASE}/profiles/catalog.json"
MIXER_TEMPLATE_DIR="${MIXER_BASE}/templates"
MIXER_CLOUD_INIT_TPL="${MIXER_TEMPLATE_DIR}/cloud-init-user.yaml.tpl"

# --- VM ID Range ---
MIXER_VMID_MIN=200
MIXER_VMID_MAX=299
MIXER_TEMPLATE_VMID=9000

# --- Cloud Image ---
MIXER_CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
MIXER_CLOUD_IMAGE_PATH="/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img"

# --- Defaults ---
MIXER_DEFAULT_RAM=49152
MIXER_DEFAULT_DISK=500
MIXER_DEFAULT_BRIDGE="vmbr0"
MIXER_DEFAULT_SPEED_CLASS="datacenter"
MIXER_DEFAULT_USER="nosana"

# --- GPU PCI Address ---
MIXER_GPU_PCI="0000:01:00"

# --- Logging ---
log_info()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "${BLUE}[..]${NC} $*"; }
log_header()  { echo -e "\n${BOLD}=== $* ===${NC}"; }
log_detail()  { echo -e "    ${DIM}$*${NC}"; }
log_dry()     { echo -e "${CYAN}[DRY]${NC} $*"; }

# --- State Directory Init ---
mixer_ensure_dirs() {
    mkdir -p "${MIXER_STATE_DIR}" "${MIXER_SSH_DIR}"

    # Initialize gpu.json if missing
    if [ ! -f "${MIXER_GPU_STATE}" ]; then
        echo '{"assigned_to":null,"pci_addr":"0000:01:00"}' > "${MIXER_GPU_STATE}"
    fi

    # Initialize config.json if missing
    if [ ! -f "${MIXER_CONFIG}" ]; then
        cat > "${MIXER_CONFIG}" <<'CONF'
{
  "template_vmid": 9000,
  "vmid_min": 200,
  "vmid_max": 299,
  "default_bridge": "vmbr0",
  "default_ram": 49152,
  "default_disk": 500,
  "gpu_pci": "0000:01:00",
  "ssh_user": "nosana"
}
CONF
    fi
}

# --- Config Loading ---
mixer_config_get() {
    local key="$1"
    local default="${2:-}"
    if [ -f "${MIXER_CONFIG}" ]; then
        local val
        val=$(jq -r ".${key} // empty" "${MIXER_CONFIG}" 2>/dev/null)
        echo "${val:-${default}}"
    else
        echo "${default}"
    fi
}

# --- VM State Files ---
mixer_vm_state_path() {
    local vmid="$1"
    echo "${MIXER_STATE_DIR}/${vmid}.json"
}

mixer_vm_state_save() {
    local vmid="$1"
    local json="$2"
    echo "${json}" | jq '.' > "$(mixer_vm_state_path "${vmid}")"
}

mixer_vm_state_load() {
    local vmid="$1"
    local path
    path=$(mixer_vm_state_path "${vmid}")
    if [ -f "${path}" ]; then
        cat "${path}"
    else
        return 1
    fi
}

mixer_vm_state_get() {
    local vmid="$1"
    local key="$2"
    local default="${3:-}"
    local val
    val=$(mixer_vm_state_load "${vmid}" 2>/dev/null | jq -r ".${key} // empty" 2>/dev/null)
    echo "${val:-${default}}"
}

mixer_vm_state_set() {
    local vmid="$1"
    local key="$2"
    local value="$3"
    local path
    path=$(mixer_vm_state_path "${vmid}")
    if [ -f "${path}" ]; then
        local tmp
        tmp=$(jq --arg k "${key}" --arg v "${value}" '.[$k] = $v' "${path}")
        echo "${tmp}" > "${path}"
    fi
}

mixer_vm_state_delete() {
    local vmid="$1"
    rm -f "$(mixer_vm_state_path "${vmid}")"
}

# --- GPU State ---
mixer_gpu_state_load() {
    if [ -f "${MIXER_GPU_STATE}" ]; then
        cat "${MIXER_GPU_STATE}"
    else
        echo '{"assigned_to":null,"pci_addr":"0000:01:00"}'
    fi
}

mixer_gpu_state_save() {
    local json="$1"
    echo "${json}" | jq '.' > "${MIXER_GPU_STATE}"
}

mixer_gpu_current_holder() {
    mixer_gpu_state_load | jq -r '.assigned_to // empty'
}

# --- Random Generators ---
mixer_random_hex() {
    local len="${1:-8}"
    head -c "$((len / 2 + 1))" /dev/urandom | xxd -p | head -c "${len}"
}

mixer_random_serial() {
    # WD-style serial: WD-WMC + 10 random hex chars
    echo "WD-WMC$(mixer_random_hex 10 | tr '[:lower:]' '[:upper:]')"
}

mixer_random_uuid() {
    # Standard UUID v4 format
    local h
    h=$(mixer_random_hex 32)
    echo "${h:0:8}-${h:8:4}-4${h:13:3}-$(printf '%x' $(( (0x${h:16:2} & 0x3f) | 0x80 )))${h:18:2}-${h:20:12}"
}

mixer_random_gpu_uuid() {
    echo "GPU-$(mixer_random_uuid)"
}

mixer_random_mac() {
    # Takes an OUI prefix (e.g. "00:1F:C6") and generates 3 random octets
    local oui="$1"
    printf '%s:%02X:%02X:%02X' "${oui}" \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256))
}

mixer_random_range() {
    local min="$1"
    local max="$2"
    echo $(( min + RANDOM % (max - min + 1) ))
}

mixer_random_bios_date() {
    # Generates a plausible BIOS date (MM/DD/YYYY) from 2019-2023
    local year=$((2019 + RANDOM % 5))
    local month=$(printf '%02d' $((1 + RANDOM % 12)))
    local day=$(printf '%02d' $((1 + RANDOM % 28)))
    echo "${month}/${day}/${year}"
}

# --- SSH Helpers ---
mixer_ssh() {
    local ip="$1"
    shift
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        -i "${MIXER_SSH_KEY}" \
        "${MIXER_DEFAULT_USER}@${ip}" "$@"
}

mixer_scp() {
    local src="$1"
    local ip="$2"
    local dst="$3"
    scp -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        -o LogLevel=ERROR \
        -i "${MIXER_SSH_KEY}" \
        "${src}" "${MIXER_DEFAULT_USER}@${ip}:${dst}"
}

# --- Validation ---
mixer_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "mixer must be run as root"
        exit 1
    fi
}

mixer_require_qm() {
    if ! command -v qm >/dev/null 2>&1; then
        log_error "qm not found — mixer must run on a Proxmox VE host"
        exit 1
    fi
}

mixer_require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq not found — install with: apt install -y jq"
        exit 1
    fi
}

mixer_vmid_valid() {
    local vmid="$1"
    if [[ ! "${vmid}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if [ "${vmid}" -lt "${MIXER_VMID_MIN}" ] || [ "${vmid}" -gt "${MIXER_VMID_MAX}" ]; then
        return 1
    fi
    return 0
}

mixer_vmid_exists() {
    local vmid="$1"
    qm status "${vmid}" >/dev/null 2>&1
}

# --- IP Parsing ---
mixer_ip_from_cidr() {
    echo "$1" | cut -d'/' -f1
}
