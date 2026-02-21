#!/bin/bash
# detect.sh — Anti-spoof detection suite (10+ checks)
# Version: 0.00.1
#
# Runs a series of hardware consistency checks to detect spoofing.
# Exit code = number of FAILs found.

PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }

echo "=== Anti-Spoof Detection Suite v0.00.1 ==="
echo ""

# ─── 1. CPUID vs /proc/cpuinfo: Family ───
echo "--- Check 1: CPUID vs cpuinfo (family/model/stepping) ---"
if [ -x /app/detect_cpuid ]; then
    CPUID_FAMILY=$(/app/detect_cpuid family 2>/dev/null)
    CPUID_MODEL=$(/app/detect_cpuid model 2>/dev/null)
    CPUID_STEPPING=$(/app/detect_cpuid stepping 2>/dev/null)

    CPUINFO_FAMILY=$(grep -m1 "^cpu family" /proc/cpuinfo 2>/dev/null | awk '{print $NF}')
    CPUINFO_MODEL=$(grep -m1 "^model[[:space:]]" /proc/cpuinfo 2>/dev/null | awk '{print $NF}')
    CPUINFO_STEPPING=$(grep -m1 "^stepping" /proc/cpuinfo 2>/dev/null | awk '{print $NF}')

    if [ "$CPUID_FAMILY" = "$CPUINFO_FAMILY" ]; then
        pass "CPU family matches: CPUID=$CPUID_FAMILY, cpuinfo=$CPUINFO_FAMILY"
    else
        fail "CPU family MISMATCH: CPUID=$CPUID_FAMILY, cpuinfo=$CPUINFO_FAMILY"
    fi

    if [ "$CPUID_MODEL" = "$CPUINFO_MODEL" ]; then
        pass "CPU model matches: CPUID=$CPUID_MODEL, cpuinfo=$CPUINFO_MODEL"
    else
        fail "CPU model MISMATCH: CPUID=$CPUID_MODEL, cpuinfo=$CPUINFO_MODEL"
    fi

    if [ "$CPUID_STEPPING" = "$CPUINFO_STEPPING" ]; then
        pass "CPU stepping matches: CPUID=$CPUID_STEPPING, cpuinfo=$CPUINFO_STEPPING"
    else
        fail "CPU stepping MISMATCH: CPUID=$CPUID_STEPPING, cpuinfo=$CPUINFO_STEPPING"
    fi
else
    warn "detect_cpuid binary not found — skipping CPUID checks"
fi

# ─── 2. Core count: cpuinfo siblings vs sysfs cpu dirs ───
echo ""
echo "--- Check 2: Core count consistency ---"
CPUINFO_SIBLINGS=$(grep -m1 "^siblings" /proc/cpuinfo 2>/dev/null | awk '{print $NF}')
# Count actual processor entries in cpuinfo
CPUINFO_PROCS=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null)
# Count sysfs cpu directories (kernel truth, immune to LD_PRELOAD)
SYSFS_CPUS=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)

if [ -n "$CPUINFO_SIBLINGS" ] && [ "$SYSFS_CPUS" -gt 0 ]; then
    if [ "$CPUINFO_SIBLINGS" = "$SYSFS_CPUS" ]; then
        pass "Core count matches: cpuinfo siblings=$CPUINFO_SIBLINGS, sysfs dirs=$SYSFS_CPUS"
    else
        fail "Core count MISMATCH: cpuinfo siblings=$CPUINFO_SIBLINGS, sysfs dirs=$SYSFS_CPUS"
    fi
else
    warn "Could not read core count from cpuinfo or sysfs"
fi

# Also compare cpuinfo processor count vs sysfs (catches LD_PRELOAD that fakes cpuinfo)
if [ -n "$CPUINFO_PROCS" ] && [ "$SYSFS_CPUS" -gt 0 ]; then
    if [ "$CPUINFO_PROCS" = "$SYSFS_CPUS" ]; then
        pass "Processor entries match: cpuinfo=$CPUINFO_PROCS, sysfs=$SYSFS_CPUS"
    else
        fail "Processor entries MISMATCH: cpuinfo=$CPUINFO_PROCS, sysfs=$SYSFS_CPUS"
    fi
fi

# ─── 3. Feature flags: CPUID VAES vs cpuinfo flags ───
echo ""
echo "--- Check 3: Feature flag consistency (VAES) ---"
if [ -x /app/detect_cpuid ]; then
    CPUID_VAES=$(/app/detect_cpuid has_vaes 2>/dev/null)
    CPUINFO_HAS_VAES=$(grep -m1 "^flags" /proc/cpuinfo 2>/dev/null | grep -wo "vaes" | head -1)

    if [ "$CPUID_VAES" = "1" ] && [ -n "$CPUINFO_HAS_VAES" ]; then
        pass "VAES flag consistent: CPUID=yes, cpuinfo=yes"
    elif [ "$CPUID_VAES" = "0" ] && [ -z "$CPUINFO_HAS_VAES" ]; then
        pass "VAES flag consistent: CPUID=no, cpuinfo=no"
    elif [ "$CPUID_VAES" = "1" ] && [ -z "$CPUINFO_HAS_VAES" ]; then
        fail "VAES MISMATCH: CPUID reports VAES=yes, but cpuinfo flags missing vaes"
    else
        fail "VAES MISMATCH: CPUID reports VAES=no, but cpuinfo flags contain vaes"
    fi
else
    warn "detect_cpuid binary not found — skipping VAES check"
fi

# ─── 4. PCIe config space vs sysfs ───
echo ""
echo "--- Check 4: PCIe link speed (config space vs sysfs) ---"
SYSFS_MAX_SPEED=$(cat /sys/bus/pci/devices/0000:05:00.0/max_link_speed 2>/dev/null)
LSPCI_SPEED=$(lspci -s 05:00.0 -vvv 2>/dev/null | grep "LnkCap:" | grep -oP '\d+\.?\d*GT/s')

if [ -n "$SYSFS_MAX_SPEED" ] && [ -n "$LSPCI_SPEED" ]; then
    # Extract numeric GT/s from each source (sysfs: "16.0 GT/s PCIe", lspci: "16GT/s")
    SYSFS_GTS=$(echo "$SYSFS_MAX_SPEED" | grep -oP '[\d.]+(?=\s*GT/s)')
    LSPCI_GTS=$(echo "$LSPCI_SPEED" | grep -oP '[\d.]+(?=GT/s)')
    # Normalize: strip trailing .0 for comparison (16.0 → 16, 16 → 16)
    SYSFS_GTS_NORM=$(echo "$SYSFS_GTS" | sed 's/\.0$//')
    LSPCI_GTS_NORM=$(echo "$LSPCI_GTS" | sed 's/\.0$//')
    if [ "$SYSFS_GTS_NORM" = "$LSPCI_GTS_NORM" ]; then
        pass "PCIe speed matches: sysfs=${SYSFS_GTS} GT/s, lspci=${LSPCI_GTS} GT/s"
    else
        fail "PCIe speed MISMATCH: sysfs=${SYSFS_GTS} GT/s, lspci=${LSPCI_GTS} GT/s"
    fi
elif [ -z "$LSPCI_SPEED" ]; then
    warn "Could not read lspci PCIe speed (no lspci or no device 05:00.0)"
else
    warn "Could not read sysfs max_link_speed"
fi

# ─── 5. Hardware combo impossibility check ───
echo ""
echo "--- Check 5: Hardware combination logic ---"
CPU_MODEL_NAME=$(grep -m1 "^model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //')

# Check if DDR5 is claimed via dmidecode
DDR_TYPE=$(dmidecode -t memory 2>/dev/null | grep -i "Type:" | grep -v "Type Detail" | head -1 | awk '{print $NF}')

if echo "$CPU_MODEL_NAME" | grep -qi "threadripper 1900X"; then
    if echo "$DDR_TYPE" | grep -qi "DDR5"; then
        fail "IMPOSSIBLE: Threadripper 1900X (TR4 socket) does not support DDR5"
    else
        pass "Memory type plausible for claimed CPU"
    fi

    if [ -n "$SYSFS_MAX_SPEED" ] && echo "$SYSFS_MAX_SPEED" | grep -q "32.0"; then
        fail "IMPOSSIBLE: Threadripper 1900X does not support PCIe 5.0 (32 GT/s)"
    else
        pass "PCIe speed plausible for claimed CPU"
    fi
else
    pass "CPU is not claiming to be Threadripper 1900X — skipping combo check"
fi

# ─── 6. Cache topology ───
echo ""
echo "--- Check 6: L3 cache size vs expected ---"
L3_SIZE=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null)
if [ -n "$L3_SIZE" ]; then
    if echo "$CPU_MODEL_NAME" | grep -qi "5900X"; then
        # Real 5900X: 32768K or 32M
        if echo "$L3_SIZE" | grep -qE "(32768|32M)"; then
            pass "L3 cache $L3_SIZE consistent with Ryzen 9 5900X"
        else
            fail "L3 cache $L3_SIZE unexpected for Ryzen 9 5900X (expected ~32MB)"
        fi
    elif echo "$CPU_MODEL_NAME" | grep -qi "1900X"; then
        # Threadripper 1900X: 16384K total, 4096K per CCX (what we report in sysfs)
        if echo "$L3_SIZE" | grep -qE "(4096|16384)"; then
            pass "L3 cache $L3_SIZE consistent with Threadripper 1900X"
        else
            fail "L3 cache $L3_SIZE unexpected for Threadripper 1900X (expected 4096K per CCX)"
        fi
    else
        pass "L3 cache $L3_SIZE (no model-specific expectation)"
    fi
else
    warn "Could not read L3 cache size"
fi

# ─── 7. Bogomips sanity ───
echo ""
echo "--- Check 7: Bogomips sanity ---"
BOGOMIPS=$(grep -m1 "^bogomips" /proc/cpuinfo 2>/dev/null | awk '{print $NF}')
if [ -n "$BOGOMIPS" ]; then
    # Bogomips should be roughly 2x base clock. 5900X base=3.7GHz → ~7400
    # Threadripper 1900X base=3.8GHz → ~7600
    # We fake 7186.36 — a static check can't be definitive, but wildly wrong values flag
    BOGO_INT=$(echo "$BOGOMIPS" | cut -d. -f1)
    if [ "$BOGO_INT" -gt 1000 ] && [ "$BOGO_INT" -lt 15000 ]; then
        pass "Bogomips=$BOGOMIPS in plausible range"
    else
        fail "Bogomips=$BOGOMIPS outside plausible range (1000-15000)"
    fi
else
    warn "Could not read bogomips"
fi

# ─── 8. LD_PRELOAD detection ───
echo ""
echo "--- Check 8: LD_PRELOAD detection ---"
if [ -n "$LD_PRELOAD" ]; then
    fail "LD_PRELOAD is set: $LD_PRELOAD"
else
    pass "LD_PRELOAD is not set"
fi

# Check /proc/self/maps for suspicious .so files
SPOOF_MAPS=$(grep -i "spoof" /proc/self/maps 2>/dev/null)
if [ -n "$SPOOF_MAPS" ]; then
    fail "Suspicious library in /proc/self/maps: $(echo "$SPOOF_MAPS" | head -1)"
else
    pass "No suspicious libraries in /proc/self/maps"
fi

# ─── 9. Environment scan ───
echo ""
echo "--- Check 9: Environment variable scan ---"
SPOOF_ENVS=$(strings /proc/self/environ 2>/dev/null | grep -i "spoof" | head -5)
if [ -n "$SPOOF_ENVS" ]; then
    fail "Spoof-related env vars found: $SPOOF_ENVS"
else
    pass "No spoof-related environment variables"
fi

# ─── 10. nvidia-smi PCIe cross-check ───
echo ""
echo "--- Check 10: nvidia-smi PCIe generation cross-check ---"
if command -v nvidia-smi &>/dev/null; then
    NVML_PCIE_GEN=$(nvidia-smi --query-gpu=pcie.link.gen.max --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    if [ -n "$NVML_PCIE_GEN" ] && [ -n "$SYSFS_MAX_SPEED" ]; then
        # Map gen to GT/s: gen3=8, gen4=16, gen5=32
        case "$NVML_PCIE_GEN" in
            3) EXPECTED_GTS="8.0" ;;
            4) EXPECTED_GTS="16.0" ;;
            5) EXPECTED_GTS="32.0" ;;
            *) EXPECTED_GTS="unknown" ;;
        esac
        SYSFS_GTS=$(echo "$SYSFS_MAX_SPEED" | grep -oP '[\d.]+(?= GT/s)')

        if [ "$SYSFS_GTS" = "$EXPECTED_GTS" ]; then
            pass "nvidia-smi PCIe gen $NVML_PCIE_GEN ($EXPECTED_GTS GT/s) matches sysfs ($SYSFS_GTS GT/s)"
        else
            fail "nvidia-smi PCIe gen $NVML_PCIE_GEN ($EXPECTED_GTS GT/s) vs sysfs ($SYSFS_GTS GT/s) MISMATCH"
        fi
    else
        warn "Could not compare nvidia-smi PCIe gen with sysfs"
    fi
else
    warn "nvidia-smi not available — skipping PCIe cross-check"
fi

# ─── Summary ───
echo ""
echo "==========================================="
echo "  RESULTS: $PASS PASS / $FAIL FAIL / $WARN WARN"
echo "==========================================="

exit $FAIL
