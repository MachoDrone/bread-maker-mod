#!/bin/bash
# launcher.sh — Sets LD_PRELOAD and runs the target command
# Version: 0.00.1

SPOOF_CPU="${SPOOF_CPU:-1}"
SPOOF_PCIE="${SPOOF_PCIE:-1}"
SPOOF_DDR="${SPOOF_DDR:-1}"
SPOOF_TOPOLOGY="${SPOOF_TOPOLOGY:-1}"
SPOOF_LOG="${SPOOF_LOG:-0}"

echo "=== Nosana Anti-Spoof PoC v0.00.1 ==="
echo "Spoof config:"
echo "  CPU:      ${SPOOF_CPU} (Threadripper 1900X)"
echo "  PCIe:     ${SPOOF_PCIE} (5.0 / 32 GT/s)"
echo "  DDR:      ${SPOOF_DDR} (DDR5-4800)"
echo "  Topology: ${SPOOF_TOPOLOGY} (8C/16T)"
echo "  Logging:  ${SPOOF_LOG}"
echo "======================================="

export LD_PRELOAD=/app/spoof_hw.so
export SPOOF_CPU SPOOF_PCIE SPOOF_DDR SPOOF_TOPOLOGY SPOOF_LOG

if [ $# -eq 0 ]; then
    echo "No command specified — dropping to interactive shell"
    exec /bin/bash
else
    exec "$@"
fi
