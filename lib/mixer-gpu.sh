#!/bin/bash
# lib/mixer-gpu.sh — GPU passthrough management (single GPU: RTX 4090)
# Tracks assignment state, handles PCI rescan between VMs
#
# Version: 0.03.0

# --- Assign GPU to a VM ---
mixer_gpu_assign() {
    local vmid="$1"

    if ! mixer_vmid_valid "${vmid}"; then
        log_error "Invalid VMID: ${vmid}"
        return 1
    fi

    if ! mixer_vmid_exists "${vmid}"; then
        log_error "VM ${vmid} does not exist"
        return 1
    fi

    local current_holder
    current_holder=$(mixer_gpu_current_holder)

    log_step "Assigning GPU to VM ${vmid}..."

    # If another VM has the GPU, release it first
    if [ -n "${current_holder}" ] && [ "${current_holder}" != "${vmid}" ]; then
        log_warn "GPU currently assigned to VM ${current_holder}"

        local holder_status
        holder_status=$(qm status "${current_holder}" 2>/dev/null | awk '{print $2}')

        if [ "${holder_status}" = "running" ]; then
            log_step "Stopping VM ${current_holder}..."
            qm stop "${current_holder}" --timeout 30
            sleep 2
        fi

        # Remove hostpci from old holder
        log_step "Removing GPU passthrough from VM ${current_holder}..."
        qm set "${current_holder}" --delete hostpci0 >/dev/null 2>&1 || true
        qm set "${current_holder}" --vga std >/dev/null 2>&1 || true

        # Update old holder state
        mixer_vm_state_set "${current_holder}" "has_gpu" "false"

        # PCI rescan to make device available again
        log_step "Rescanning PCI bus..."
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
        sleep 2

        log_info "GPU released from VM ${current_holder}"
    fi

    # Check if target VM is running — needs to be stopped for PCI passthrough change
    local target_status
    target_status=$(qm status "${vmid}" 2>/dev/null | awk '{print $2}')
    local was_running=false

    if [ "${target_status}" = "running" ]; then
        was_running=true
        log_step "Stopping VM ${vmid} for GPU assignment..."
        qm stop "${vmid}" --timeout 30
        sleep 2
    fi

    # Assign GPU via PCI passthrough
    log_step "Configuring PCI passthrough for VM ${vmid}..."
    qm set "${vmid}" --hostpci0 "${MIXER_GPU_PCI},pcie=1,x-vga=1" >/dev/null
    qm set "${vmid}" --vga none >/dev/null

    # Update state
    mixer_vm_state_set "${vmid}" "has_gpu" "true"
    mixer_gpu_state_save "{\"assigned_to\":${vmid},\"pci_addr\":\"${MIXER_GPU_PCI}\"}"

    log_info "GPU assigned to VM ${vmid}"

    # Restart if it was running
    if [ "${was_running}" = "true" ]; then
        log_step "Restarting VM ${vmid}..."
        qm start "${vmid}"
        log_info "VM ${vmid} restarted with GPU"
    fi
}

# --- Release GPU from current holder ---
mixer_gpu_release() {
    local current_holder
    current_holder=$(mixer_gpu_current_holder)

    if [ -z "${current_holder}" ]; then
        log_info "GPU is not assigned to any VM"
        return 0
    fi

    log_header "Releasing GPU from VM ${current_holder}"
    echo ""

    mixer_gpu_release_internal

    log_info "GPU released and available"
    echo ""
}

# Internal release (no header, used by destroy/assign)
mixer_gpu_release_internal() {
    local current_holder
    current_holder=$(mixer_gpu_current_holder)

    if [ -z "${current_holder}" ]; then
        return 0
    fi

    local status
    status=$(qm status "${current_holder}" 2>/dev/null | awk '{print $2}')

    if [ "${status}" = "running" ]; then
        log_step "Stopping VM ${current_holder}..."
        qm stop "${current_holder}" --timeout 30
        sleep 2
    fi

    # Remove hostpci from VM
    qm set "${current_holder}" --delete hostpci0 >/dev/null 2>&1 || true
    qm set "${current_holder}" --vga std >/dev/null 2>&1 || true

    # Update state
    mixer_vm_state_set "${current_holder}" "has_gpu" "false"
    mixer_gpu_state_save '{"assigned_to":null,"pci_addr":"'"${MIXER_GPU_PCI}"'"}'

    # PCI rescan
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 1
}

# --- GPU status ---
mixer_gpu_status() {
    local gpu_state
    gpu_state=$(mixer_gpu_state_load)

    local holder
    holder=$(echo "${gpu_state}" | jq -r '.assigned_to // empty')
    local pci
    pci=$(echo "${gpu_state}" | jq -r '.pci_addr')

    log_header "GPU Status"
    echo ""
    echo "  PCI Address: ${pci}"

    if [ -n "${holder}" ] && [ "${holder}" != "null" ]; then
        local name
        name=$(mixer_vm_state_get "${holder}" "name" "unknown")
        echo "  Assigned To: VM ${holder} (${name})"

        local vm_status
        vm_status=$(qm status "${holder}" 2>/dev/null | awk '{print $2}')
        echo "  VM Status:   ${vm_status:-unknown}"
    else
        echo "  Assigned To: (none — available)"
    fi
    echo ""
}
