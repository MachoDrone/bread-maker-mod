#!/bin/bash
# lib/mixer-vm.sh — VM lifecycle management (create, destroy, list, status)
# Uses Proxmox qm CLI for VM operations
#
# Version: 0.03.0

# --- Find next available VMID in range ---
mixer_vm_next_id() {
    local vmid
    for vmid in $(seq "${MIXER_VMID_MIN}" "${MIXER_VMID_MAX}"); do
        if ! qm status "${vmid}" >/dev/null 2>&1; then
            echo "${vmid}"
            return 0
        fi
    done
    log_error "No available VMIDs in range ${MIXER_VMID_MIN}-${MIXER_VMID_MAX}"
    return 1
}

# --- One-time setup: download cloud image, create template ---
mixer_vm_init() {
    log_header "Mixer Init — One-Time Setup"
    echo ""

    # Step 1: Generate SSH keypair
    if [ ! -f "${MIXER_SSH_KEY}" ]; then
        log_step "Generating SSH keypair..."
        ssh-keygen -t ed25519 -f "${MIXER_SSH_KEY}" -N "" -C "mixer@$(hostname)" >/dev/null 2>&1
        chmod 600 "${MIXER_SSH_KEY}"
        chmod 644 "${MIXER_SSH_KEY}.pub"
        log_info "SSH keypair created: ${MIXER_SSH_KEY}"
    else
        log_info "SSH keypair already exists: ${MIXER_SSH_KEY}"
    fi

    # Step 2: Download cloud image
    if [ ! -f "${MIXER_CLOUD_IMAGE_PATH}" ]; then
        log_step "Downloading Ubuntu 24.04 cloud image..."
        wget -q --show-progress -O "${MIXER_CLOUD_IMAGE_PATH}" "${MIXER_CLOUD_IMAGE_URL}"
        log_info "Cloud image downloaded: ${MIXER_CLOUD_IMAGE_PATH}"
    else
        log_info "Cloud image already exists: ${MIXER_CLOUD_IMAGE_PATH}"
    fi

    # Step 3: Create snippets directory
    mkdir -p /var/lib/vz/snippets

    # Step 4: Create template VM
    if qm status "${MIXER_TEMPLATE_VMID}" >/dev/null 2>&1; then
        log_info "Template VM ${MIXER_TEMPLATE_VMID} already exists"
    else
        log_step "Creating template VM ${MIXER_TEMPLATE_VMID}..."

        # Create VM with basic settings
        qm create "${MIXER_TEMPLATE_VMID}" \
            --name "mixer-template" \
            --ostype l26 \
            --machine q35 \
            --bios ovmf \
            --cpu host \
            --cores 2 \
            --memory 2048 \
            --net0 "e1000e=00:00:00:00:00:00,bridge=${MIXER_DEFAULT_BRIDGE}" \
            --scsihw virtio-scsi-single \
            --agent enabled=0 \
            --numa 1

        # Import cloud image as disk
        qm set "${MIXER_TEMPLATE_VMID}" --scsi0 "local-lvm:0,import-from=${MIXER_CLOUD_IMAGE_PATH},discard=on,iothread=1,ssd=1"

        # Add EFI disk
        qm set "${MIXER_TEMPLATE_VMID}" --efidisk0 "local-lvm:0,efitype=4m,pre-enrolled-keys=0"

        # Add cloud-init drive
        qm set "${MIXER_TEMPLATE_VMID}" --ide2 "local-lvm:cloudinit"

        # Set boot order
        qm set "${MIXER_TEMPLATE_VMID}" --boot order=scsi0

        # Convert to template
        qm template "${MIXER_TEMPLATE_VMID}"

        log_info "Template VM ${MIXER_TEMPLATE_VMID} created"
    fi

    # Step 5: Initialize state
    mixer_ensure_dirs

    echo ""
    log_info "Mixer init complete"
    echo ""
    echo "  Template VM: ${MIXER_TEMPLATE_VMID}"
    echo "  SSH key:     ${MIXER_SSH_KEY}"
    echo "  Cloud image: ${MIXER_CLOUD_IMAGE_PATH}"
    echo "  State dir:   ${MIXER_STATE_DIR}"
    echo ""
    echo "  Next: mixer create <profile> [options]"
    echo ""
}

# --- Create a new VM from profile ---
mixer_vm_create() {
    local profile="$1"
    local vm_name="${2:-}"
    local vmid="${3:-}"
    local ram="${4:-${MIXER_DEFAULT_RAM}}"
    local disk="${5:-${MIXER_DEFAULT_DISK}}"
    local ip="${6:-dhcp}"
    local gateway="${7:-}"
    local bridge="${8:-${MIXER_DEFAULT_BRIDGE}}"
    local speed_class="${9:-${MIXER_DEFAULT_SPEED_CLASS}}"
    local assign_gpu="${10:-false}"
    local no_provision="${11:-false}"
    local dry_run="${12:-false}"

    # Validate profile
    if ! mixer_profile_exists "${profile}"; then
        log_error "Profile '${profile}' not found"
        return 1
    fi

    # Load profile
    mixer_profile_load "${profile}"

    # Auto-assign VMID if not specified
    if [ -z "${vmid}" ]; then
        vmid=$(mixer_vm_next_id) || return 1
    fi

    # Validate VMID
    if ! mixer_vmid_valid "${vmid}"; then
        log_error "VMID ${vmid} out of range (${MIXER_VMID_MIN}-${MIXER_VMID_MAX})"
        return 1
    fi

    if mixer_vmid_exists "${vmid}"; then
        log_error "VMID ${vmid} already exists"
        return 1
    fi

    # Validate template exists
    if ! qm status "${MIXER_TEMPLATE_VMID}" >/dev/null 2>&1; then
        log_error "Template VM ${MIXER_TEMPLATE_VMID} not found. Run 'mixer init' first."
        return 1
    fi

    # Auto-name if not specified
    if [ -z "${vm_name}" ]; then
        vm_name="mixer-${profile}-${vmid}"
    fi

    # Generate per-VM unique values
    local mac disk_serial gpu_uuid
    mac=$(mixer_stealth_mac)
    disk_serial=$(mixer_stealth_disk_serial)
    gpu_uuid=$(mixer_stealth_gpu_uuid)

    # Generate speed values
    local speed_vals download upload latency
    speed_vals=$(mixer_stealth_speed_values "${speed_class}")
    download=$(echo "${speed_vals}" | awk '{print $1}')
    upload=$(echo "${speed_vals}" | awk '{print $2}')
    latency=$(echo "${speed_vals}" | awk '{print $3}')

    # Build stealth args
    local qemu_args
    qemu_args=$(mixer_stealth_build_args "${disk_serial}")

    local disk_vendor disk_product
    disk_vendor=$(mixer_stealth_disk_vendor)
    disk_product=$(mixer_stealth_disk_product)

    # Get IP for state file
    local vm_ip
    if [ "${ip}" = "dhcp" ]; then
        vm_ip="dhcp"
    else
        vm_ip=$(mixer_ip_from_cidr "${ip}")
    fi

    log_header "Creating VM ${vmid}: ${vm_name}"
    echo ""
    echo -e "  ${BOLD}Profile:${NC}     ${profile} (${PROFILE_MODEL_STRING})"
    echo -e "  ${BOLD}Topology:${NC}    ${PROFILE_CORES}C/${PROFILE_THREADS}T"
    echo -e "  ${BOLD}RAM:${NC}         ${ram}MB"
    echo -e "  ${BOLD}Disk:${NC}        ${disk}GB (${disk_vendor} ${disk_product})"
    echo -e "  ${BOLD}Network:${NC}     ${mac} on ${bridge} (e1000e)"
    echo -e "  ${BOLD}IP:${NC}          ${ip}"
    echo -e "  ${BOLD}Speed:${NC}       ${download}/${upload} Mbps, ${latency}ms (${speed_class})"
    echo -e "  ${BOLD}GPU UUID:${NC}    ${gpu_uuid}"
    echo -e "  ${BOLD}Board:${NC}       ${PROFILE_BOARD_VENDOR} ${PROFILE_BOARD_MODEL}"
    echo ""

    if [ "${dry_run}" = "true" ]; then
        log_dry "Would clone template ${MIXER_TEMPLATE_VMID} → ${vmid}"
        log_dry "Would set args: ${qemu_args}"
        log_dry "Would set net0: e1000e=${mac},bridge=${bridge}"
        log_dry "Would resize disk to ${disk}G"
        return 0
    fi

    # Phase A: VM Creation
    log_step "Cloning template ${MIXER_TEMPLATE_VMID} → ${vmid}..."
    qm clone "${MIXER_TEMPLATE_VMID}" "${vmid}" --name "${vm_name}" --full true
    log_info "VM ${vmid} cloned"

    log_step "Configuring VM..."

    # Set QEMU args (stealth)
    qm set "${vmid}" --args "${qemu_args}" >/dev/null

    # Set NIC with realistic MAC
    qm set "${vmid}" --net0 "e1000e=${mac},bridge=${bridge}" >/dev/null

    # Set RAM
    qm set "${vmid}" --memory "${ram}" --balloon 0 >/dev/null

    # Set cores (Proxmox cores, not QEMU smp — smp is in args)
    qm set "${vmid}" --cores "${PROFILE_CORES}" --sockets 1 >/dev/null

    # Set NUMA
    qm set "${vmid}" --numa 1 >/dev/null

    # Set VGA (will be overridden to 'none' if GPU is assigned)
    qm set "${vmid}" --vga std >/dev/null

    # Resize disk
    log_step "Resizing disk to ${disk}G..."
    qm disk resize "${vmid}" scsi0 "${disk}G" >/dev/null 2>&1
    log_info "Disk resized"

    # Apply cloud-init
    log_step "Configuring cloud-init..."
    mixer_cloudinit_apply "${vmid}" "${ip}" "${gateway}"

    # Save VM state
    local state
    state=$(cat <<STATEJSON
{
  "vmid": ${vmid},
  "name": "${vm_name}",
  "profile": "${profile}",
  "model_string": "${PROFILE_MODEL_STRING}",
  "cores": ${PROFILE_CORES},
  "threads": ${PROFILE_THREADS},
  "ram_mb": ${ram},
  "disk_gb": ${disk},
  "ip": "${vm_ip}",
  "gateway": "${gateway}",
  "bridge": "${bridge}",
  "mac": "${mac}",
  "disk_serial": "${disk_serial}",
  "disk_vendor": "${disk_vendor}",
  "disk_product": "${disk_product}",
  "gpu_uuid": "${gpu_uuid}",
  "speed_class": "${speed_class}",
  "download_speed": ${download},
  "upload_speed": ${upload},
  "latency": ${latency},
  "board_vendor": "${PROFILE_BOARD_VENDOR}",
  "board_model": "${PROFILE_BOARD_MODEL}",
  "has_gpu": false,
  "created_at": "$(date -Iseconds)",
  "provisioned": false
}
STATEJSON
)
    mixer_vm_state_save "${vmid}" "${state}"

    # GPU assignment (optional)
    if [ "${assign_gpu}" = "true" ]; then
        mixer_gpu_assign "${vmid}"
    fi

    # Start VM
    log_step "Starting VM ${vmid}..."
    qm start "${vmid}"
    log_info "VM ${vmid} started"

    # Post-boot provisioning
    if [ "${no_provision}" = "false" ] && [ "${vm_ip}" != "dhcp" ]; then
        echo ""
        mixer_provision_vm "${vmid}"
    elif [ "${vm_ip}" = "dhcp" ]; then
        echo ""
        log_warn "DHCP — cannot auto-provision. Run 'mixer provision ${vmid}' after assigning a known IP."
    else
        echo ""
        log_info "Provisioning skipped (--no-provision)"
    fi

    echo ""
    log_info "VM ${vmid} created successfully"
    echo ""
}

# --- List all mixer-managed VMs ---
mixer_vm_list() {
    log_header "Mixer-Managed VMs"
    echo ""

    local state_files
    state_files=$(ls "${MIXER_STATE_DIR}"/*.json 2>/dev/null)

    if [ -z "${state_files}" ]; then
        echo "  No mixer VMs found."
        echo "  Create one: mixer create <profile>"
        echo ""
        return 0
    fi

    local gpu_holder
    gpu_holder=$(mixer_gpu_current_holder)

    printf "  ${BOLD}%-6s %-28s %-22s %-8s %-17s %-4s %s${NC}\n" \
        "VMID" "NAME" "PROFILE" "STATUS" "IP" "GPU" "CORES"
    printf "  %-6s %-28s %-22s %-8s %-17s %-4s %s\n" \
        "----" "----" "-------" "------" "--" "---" "-----"

    for sf in ${state_files}; do
        local vmid name profile vm_ip cores threads has_gpu status_line gpu_marker

        vmid=$(jq -r '.vmid' "${sf}")
        name=$(jq -r '.name' "${sf}")
        profile=$(jq -r '.profile' "${sf}")
        vm_ip=$(jq -r '.ip // "dhcp"' "${sf}")
        cores=$(jq -r '.cores' "${sf}")
        threads=$(jq -r '.threads' "${sf}")

        # Get live status from qm
        if qm status "${vmid}" >/dev/null 2>&1; then
            status_line=$(qm status "${vmid}" 2>/dev/null | awk '{print $2}')
        else
            status_line="gone"
        fi

        # GPU marker
        gpu_marker=""
        if [ "${gpu_holder}" = "${vmid}" ]; then
            gpu_marker="*"
        fi

        printf "  %-6s %-28s %-22s %-8s %-17s %-4s %sC/%sT\n" \
            "${vmid}" "${name}" "${profile}" "${status_line}" "${vm_ip}" "${gpu_marker}" "${cores}" "${threads}"
    done

    echo ""
    if [ -n "${gpu_holder}" ]; then
        echo "  * = GPU assigned"
    fi
    echo ""
}

# --- Detailed VM status ---
mixer_vm_status() {
    local vmid="$1"

    local state
    state=$(mixer_vm_state_load "${vmid}" 2>/dev/null)
    if [ -z "${state}" ]; then
        log_error "VM ${vmid} not found in mixer state"
        return 1
    fi

    local qm_status="unknown"
    if qm status "${vmid}" >/dev/null 2>&1; then
        qm_status=$(qm status "${vmid}" 2>/dev/null | awk '{print $2}')
    fi

    local gpu_holder
    gpu_holder=$(mixer_gpu_current_holder)

    log_header "VM ${vmid} Status"
    echo ""
    echo -e "  ${BOLD}General${NC}"
    echo "  Name:        $(echo "${state}" | jq -r '.name')"
    echo "  Status:      ${qm_status}"
    echo "  Profile:     $(echo "${state}" | jq -r '.profile')"
    echo "  Created:     $(echo "${state}" | jq -r '.created_at')"
    echo "  Provisioned: $(echo "${state}" | jq -r '.provisioned')"
    echo ""
    echo -e "  ${BOLD}Hardware Identity${NC}"
    echo "  CPU:         $(echo "${state}" | jq -r '.model_string')"
    echo "  Topology:    $(echo "${state}" | jq -r '.cores')C/$(echo "${state}" | jq -r '.threads')T"
    echo "  Board:       $(echo "${state}" | jq -r '.board_vendor') $(echo "${state}" | jq -r '.board_model')"
    echo "  RAM:         $(echo "${state}" | jq -r '.ram_mb')MB"
    echo "  Disk:        $(echo "${state}" | jq -r '.disk_gb')GB ($(echo "${state}" | jq -r '.disk_vendor') $(echo "${state}" | jq -r '.disk_product'))"
    echo "  Disk Serial: $(echo "${state}" | jq -r '.disk_serial')"
    echo ""
    echo -e "  ${BOLD}Network${NC}"
    echo "  IP:          $(echo "${state}" | jq -r '.ip')"
    echo "  MAC:         $(echo "${state}" | jq -r '.mac')"
    echo "  Bridge:      $(echo "${state}" | jq -r '.bridge')"
    echo "  Speed:       $(echo "${state}" | jq -r '.download_speed')/$(echo "${state}" | jq -r '.upload_speed') Mbps"
    echo "  Latency:     $(echo "${state}" | jq -r '.latency')ms"
    echo "  Class:       $(echo "${state}" | jq -r '.speed_class')"
    echo ""
    echo -e "  ${BOLD}GPU${NC}"
    echo "  UUID:        $(echo "${state}" | jq -r '.gpu_uuid')"
    if [ "${gpu_holder}" = "${vmid}" ]; then
        echo "  Assigned:    YES (${MIXER_GPU_PCI})"
    else
        echo "  Assigned:    no"
    fi
    echo ""
}

# --- Destroy a VM ---
mixer_vm_destroy() {
    local vmid="$1"

    if ! mixer_vmid_valid "${vmid}"; then
        log_error "Invalid VMID: ${vmid}"
        return 1
    fi

    local state
    state=$(mixer_vm_state_load "${vmid}" 2>/dev/null)
    if [ -z "${state}" ]; then
        log_error "VM ${vmid} not found in mixer state"
        return 1
    fi

    local name
    name=$(echo "${state}" | jq -r '.name')

    log_header "Destroying VM ${vmid} (${name})"
    echo ""

    # Release GPU if assigned
    local gpu_holder
    gpu_holder=$(mixer_gpu_current_holder)
    if [ "${gpu_holder}" = "${vmid}" ]; then
        log_step "Releasing GPU from VM ${vmid}..."
        mixer_gpu_release_internal
    fi

    # Stop VM if running
    if qm status "${vmid}" >/dev/null 2>&1; then
        local status
        status=$(qm status "${vmid}" 2>/dev/null | awk '{print $2}')
        if [ "${status}" = "running" ]; then
            log_step "Stopping VM ${vmid}..."
            qm stop "${vmid}" --timeout 30
            log_info "VM ${vmid} stopped"
        fi

        # Destroy VM
        log_step "Destroying VM ${vmid}..."
        qm destroy "${vmid}" --purge
        log_info "VM ${vmid} destroyed"
    else
        log_warn "VM ${vmid} not found in Proxmox (already removed?)"
    fi

    # Clean up state
    mixer_vm_state_delete "${vmid}"

    # Clean up cloud-init snippet
    rm -f "/var/lib/vz/snippets/mixer-${vmid}-user.yaml"

    log_info "VM ${vmid} fully cleaned up"
    echo ""
}
