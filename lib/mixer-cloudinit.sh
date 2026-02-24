#!/bin/bash
# lib/mixer-cloudinit.sh — Cloud-init user-data generation and application
#
# Version: 0.03.0

# --- Generate cloud-init user-data from template ---
mixer_cloudinit_generate() {
    local vmid="$1"
    local ssh_pubkey="$2"

    local user="${MIXER_DEFAULT_USER}"
    local output="/tmp/mixer-cloudinit-${vmid}.yaml"

    if [ ! -f "${MIXER_CLOUD_INIT_TPL}" ]; then
        log_error "Cloud-init template not found: ${MIXER_CLOUD_INIT_TPL}"
        return 1
    fi

    # Read template and substitute variables
    sed -e "s|{{USER}}|${user}|g" \
        -e "s|{{SSH_PUBKEY}}|${ssh_pubkey}|g" \
        -e "s|{{VMID}}|${vmid}|g" \
        "${MIXER_CLOUD_INIT_TPL}" > "${output}"

    echo "${output}"
}

# --- Apply cloud-init config to VM via qm ---
mixer_cloudinit_apply() {
    local vmid="$1"
    local ip="${2:-dhcp}"
    local gateway="${3:-}"

    local ssh_pubkey
    ssh_pubkey=$(cat "${MIXER_SSH_KEY}.pub")

    # Set cloud-init user
    qm set "${vmid}" --ciuser "${MIXER_DEFAULT_USER}" >/dev/null

    # Set SSH key
    qm set "${vmid}" --sshkeys "${MIXER_SSH_KEY}.pub" >/dev/null

    # Set IP configuration
    if [ "${ip}" = "dhcp" ]; then
        qm set "${vmid}" --ipconfig0 "ip=dhcp" >/dev/null
    else
        if [ -z "${gateway}" ]; then
            log_error "Gateway required when using static IP"
            return 1
        fi
        qm set "${vmid}" --ipconfig0 "ip=${ip},gw=${gateway}" >/dev/null
    fi

    # Generate and set custom user-data (for package installs, drivers, etc.)
    local userdata
    userdata=$(mixer_cloudinit_generate "${vmid}" "${ssh_pubkey}")
    qm set "${vmid}" --cicustom "user=local:snippets/mixer-${vmid}-user.yaml" >/dev/null 2>&1 || true

    # Copy user-data to Proxmox snippets directory
    local snippets_dir="/var/lib/vz/snippets"
    mkdir -p "${snippets_dir}"
    cp "${userdata}" "${snippets_dir}/mixer-${vmid}-user.yaml"
    rm -f "${userdata}"

    log_info "Cloud-init configured for VM ${vmid}"
}
