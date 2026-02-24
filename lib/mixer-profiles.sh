#!/bin/bash
# lib/mixer-profiles.sh — Profile catalog loading and display
#
# Version: 0.03.1

# --- List all profiles ---
mixer_profiles_list() {
    log_header "Available CPU Profiles"
    echo ""
    printf "  ${BOLD}%-25s %-45s %s${NC}\n" "PROFILE" "CPU MODEL" "CORES"
    printf "  %-25s %-45s %s\n" "-------" "---------" "-----"

    local profiles
    profiles=$(jq -r '.profiles | keys[]' "${MIXER_CATALOG}")

    while IFS= read -r name; do
        local model cores threads
        model=$(jq -r ".profiles[\"${name}\"].model_string" "${MIXER_CATALOG}")
        cores=$(jq -r ".profiles[\"${name}\"].cores" "${MIXER_CATALOG}")
        threads=$(jq -r ".profiles[\"${name}\"].threads" "${MIXER_CATALOG}")
        printf "  %-25s %-45s %sC/%sT\n" "${name}" "${model}" "${cores}" "${threads}"
    done <<< "${profiles}"
    echo ""
}

# --- Show profile details ---
mixer_profiles_show() {
    local name="$1"

    if ! jq -e ".profiles[\"${name}\"]" "${MIXER_CATALOG}" >/dev/null 2>&1; then
        log_error "Profile '${name}' not found"
        echo "Available profiles:"
        jq -r '.profiles | keys[]' "${MIXER_CATALOG}" | sed 's/^/  /'
        return 1
    fi

    local p
    p=$(jq ".profiles[\"${name}\"]" "${MIXER_CATALOG}")

    log_header "Profile: ${name}"
    echo ""
    echo -e "  ${BOLD}CPU Identity${NC}"
    echo "  Model:    $(echo "${p}" | jq -r '.model_string')"
    echo "  Family:   $(echo "${p}" | jq -r '.family')"
    echo "  Model ID: $(echo "${p}" | jq -r '.model')"
    echo "  Stepping: $(echo "${p}" | jq -r '.stepping')"
    echo "  Arch:     $(echo "${p}" | jq -r '.arch')"
    echo ""
    echo -e "  ${BOLD}Topology${NC}"
    echo "  Cores:    $(echo "${p}" | jq -r '.cores')"
    echo "  Threads:  $(echo "${p}" | jq -r '.threads')"
    echo "  TPC:      $(echo "${p}" | jq -r '.threads_per_core')"
    echo ""
    echo -e "  ${BOLD}Motherboard (SMBIOS)${NC}"
    echo "  Vendor:   $(echo "${p}" | jq -r '.smbios.board_vendor')"
    echo "  Model:    $(echo "${p}" | jq -r '.smbios.board_model')"
    echo "  BIOS:     $(echo "${p}" | jq -r '.smbios.bios_vendor') $(echo "${p}" | jq -r '.smbios.bios_version')"
    echo ""
    echo -e "  ${BOLD}NIC${NC}"
    echo "  MAC OUI:  $(echo "${p}" | jq -r '.mac_oui')"
    echo "  Type:     $(echo "${p}" | jq -r '.nic_comment')"
    echo ""

    local spoof_gpu
    spoof_gpu=$(echo "${p}" | jq -r '.spoof_gpu_uuid // true')
    echo -e "  ${BOLD}GPU UUID Spoofing${NC}"
    echo "  Enabled:  ${spoof_gpu}"
    echo ""

    local suppress
    suppress=$(echo "${p}" | jq -r '.suppress_flags | join(", ")')
    if [ -n "${suppress}" ] && [ "${suppress}" != "" ]; then
        echo -e "  ${BOLD}Suppressed CPU Flags${NC}"
        echo "  ${suppress}"
        echo ""
    fi
}

# --- Load profile into environment variables ---
# Sets PROFILE_* variables for use by other modules
mixer_profile_load() {
    local name="$1"

    if ! jq -e ".profiles[\"${name}\"]" "${MIXER_CATALOG}" >/dev/null 2>&1; then
        log_error "Profile '${name}' not found"
        return 1
    fi

    local p
    p=$(jq ".profiles[\"${name}\"]" "${MIXER_CATALOG}")

    PROFILE_NAME="${name}"
    PROFILE_MODEL_STRING=$(echo "${p}" | jq -r '.model_string')
    PROFILE_FAMILY=$(echo "${p}" | jq -r '.family')
    PROFILE_MODEL=$(echo "${p}" | jq -r '.model')
    PROFILE_STEPPING=$(echo "${p}" | jq -r '.stepping')
    PROFILE_CORES=$(echo "${p}" | jq -r '.cores')
    PROFILE_THREADS=$(echo "${p}" | jq -r '.threads')
    PROFILE_TPC=$(echo "${p}" | jq -r '.threads_per_core')
    PROFILE_ARCH=$(echo "${p}" | jq -r '.arch')
    PROFILE_MAC_OUI=$(echo "${p}" | jq -r '.mac_oui')

    # SMBIOS
    PROFILE_BOARD_VENDOR=$(echo "${p}" | jq -r '.smbios.board_vendor')
    PROFILE_BOARD_MODEL=$(echo "${p}" | jq -r '.smbios.board_model')
    PROFILE_BOARD_SERIAL_PREFIX=$(echo "${p}" | jq -r '.smbios.board_serial_prefix')
    PROFILE_BIOS_VENDOR=$(echo "${p}" | jq -r '.smbios.bios_vendor')
    PROFILE_BIOS_VERSION=$(echo "${p}" | jq -r '.smbios.bios_version')
    PROFILE_SYSTEM_MANUFACTURER=$(echo "${p}" | jq -r '.smbios.system_manufacturer')
    PROFILE_SYSTEM_PRODUCT=$(echo "${p}" | jq -r '.smbios.system_product')

    # Suppress flags as comma-separated -flag list for QEMU
    PROFILE_SUPPRESS_FLAGS=$(echo "${p}" | jq -r '.suppress_flags | map("-" + .) | join(",")')

    # GPU UUID spoofing (default true for backward compat with profiles missing this field)
    PROFILE_SPOOF_GPU_UUID=$(echo "${p}" | jq -r '.spoof_gpu_uuid // true')

    export PROFILE_NAME PROFILE_MODEL_STRING PROFILE_FAMILY PROFILE_MODEL
    export PROFILE_STEPPING PROFILE_CORES PROFILE_THREADS PROFILE_TPC
    export PROFILE_ARCH PROFILE_MAC_OUI
    export PROFILE_BOARD_VENDOR PROFILE_BOARD_MODEL PROFILE_BOARD_SERIAL_PREFIX
    export PROFILE_BIOS_VENDOR PROFILE_BIOS_VERSION
    export PROFILE_SYSTEM_MANUFACTURER PROFILE_SYSTEM_PRODUCT
    export PROFILE_SUPPRESS_FLAGS PROFILE_SPOOF_GPU_UUID
}

# --- Validate profile exists ---
mixer_profile_exists() {
    local name="$1"
    jq -e ".profiles[\"${name}\"]" "${MIXER_CATALOG}" >/dev/null 2>&1
}
