#!/bin/bash
# lib/mixer-stealth.sh — Anti-detection argument generation
# Generates QEMU args for SMBIOS, CPUID, flag suppression, MAC, disk identity
#
# Version: 0.03.0

# --- Generate QEMU CPU args ---
# Requires: PROFILE_* variables set by mixer_profile_load()
mixer_stealth_cpu_args() {
    local cpu_arg="-cpu host,kvm=off,hv-vendor-id=AuthAMD"
    cpu_arg+=",model_id='${PROFILE_MODEL_STRING}'"
    cpu_arg+=",family=${PROFILE_FAMILY}"
    cpu_arg+=",model=${PROFILE_MODEL}"
    cpu_arg+=",stepping=${PROFILE_STEPPING}"

    # Append flag suppressions
    if [ -n "${PROFILE_SUPPRESS_FLAGS}" ]; then
        cpu_arg+=",${PROFILE_SUPPRESS_FLAGS}"
    fi

    echo "${cpu_arg}"
}

# --- Generate SMP args ---
mixer_stealth_smp_args() {
    echo "-smp ${PROFILE_THREADS},sockets=1,cores=${PROFILE_CORES},threads=${PROFILE_TPC}"
}

# --- Generate SMBIOS type 0 (BIOS) ---
mixer_stealth_smbios_bios() {
    local bios_date
    bios_date=$(mixer_random_bios_date)
    echo "-smbios type=0,vendor=${PROFILE_BIOS_VENDOR},version=${PROFILE_BIOS_VERSION},date=${bios_date}"
}

# --- Generate SMBIOS type 1 (System) ---
mixer_stealth_smbios_system() {
    local serial
    serial=$(mixer_random_hex 16 | tr '[:lower:]' '[:upper:]')
    local uuid
    uuid=$(mixer_random_uuid)

    echo "-smbios type=1,manufacturer=${PROFILE_SYSTEM_MANUFACTURER},product=${PROFILE_SYSTEM_PRODUCT},serial=${serial},uuid=${uuid}"
}

# --- Generate SMBIOS type 2 (Baseboard) ---
mixer_stealth_smbios_baseboard() {
    local serial
    serial="${PROFILE_BOARD_SERIAL_PREFIX}$(mixer_random_hex 12 | tr '[:lower:]' '[:upper:]')"

    echo "-smbios type=2,manufacturer=${PROFILE_BOARD_VENDOR},product=${PROFILE_BOARD_MODEL},serial=${serial}"
}

# --- Generate all SMBIOS args combined ---
mixer_stealth_smbios_args() {
    local bios system baseboard
    bios=$(mixer_stealth_smbios_bios)
    system=$(mixer_stealth_smbios_system)
    baseboard=$(mixer_stealth_smbios_baseboard)
    echo "${bios} ${system} ${baseboard}"
}

# --- Generate disk identity args ---
# Returns SCSI device args for realistic disk model/serial
mixer_stealth_disk_serial() {
    mixer_random_serial
}

mixer_stealth_disk_vendor() {
    jq -r '.disk_identity.vendor' "${MIXER_CATALOG}"
}

mixer_stealth_disk_product() {
    jq -r '.disk_identity.product' "${MIXER_CATALOG}"
}

# --- Generate realistic MAC address ---
mixer_stealth_mac() {
    local oui="${PROFILE_MAC_OUI}"
    mixer_random_mac "${oui}"
}

# --- Generate GPU UUID ---
mixer_stealth_gpu_uuid() {
    mixer_random_gpu_uuid
}

# --- Generate per-VM speed values from speed class ---
mixer_stealth_speed_values() {
    local speed_class="${1:-datacenter}"

    local sc
    sc=$(jq ".speed_classes[\"${speed_class}\"]" "${MIXER_CATALOG}")

    if [ "${sc}" = "null" ] || [ -z "${sc}" ]; then
        log_error "Unknown speed class: ${speed_class}"
        return 1
    fi

    local dl_min dl_max ul_min ul_max lat_min lat_max
    dl_min=$(echo "${sc}" | jq -r '.download_min')
    dl_max=$(echo "${sc}" | jq -r '.download_max')
    ul_min=$(echo "${sc}" | jq -r '.upload_min')
    ul_max=$(echo "${sc}" | jq -r '.upload_max')
    lat_min=$(echo "${sc}" | jq -r '.latency_min')
    lat_max=$(echo "${sc}" | jq -r '.latency_max')

    local download upload latency
    download=$(mixer_random_range "${dl_min}" "${dl_max}")
    upload=$(mixer_random_range "${ul_min}" "${ul_max}")
    latency=$(mixer_random_range "${lat_min}" "${lat_max}")

    echo "${download} ${upload} ${latency}"
}

# --- Build complete QEMU args string for Proxmox ---
# Returns the full 'args:' line content for /etc/pve/qemu-server/<vmid>.conf
mixer_stealth_build_args() {
    local disk_serial="$1"

    local cpu_args smp_args smbios_args
    cpu_args=$(mixer_stealth_cpu_args)
    smp_args=$(mixer_stealth_smp_args)
    smbios_args=$(mixer_stealth_smbios_args)

    # Build the full args line
    # Note: disk serial/vendor/product are set via -device in args
    local args="${smp_args} ${cpu_args} ${smbios_args}"

    echo "${args}"
}
