#!/bin/bash
# launcher.sh — Sets LD_PRELOAD and runs the target command
# Version: 0.01.0

_MC_C="${_MC_C:-1}"
_MC_P="${_MC_P:-1}"
_MC_T="${_MC_T:-1}"
_MC_K="${_MC_K:-1}"
_MC_L="${_MC_L:-0}"

echo "=== Nosana Anti-Spoof PoC v0.01.0 ==="
echo "Spoof config:"
echo "  CPU:      ${_MC_C} (Ryzen 7 5800X)"
echo "  PCIe:     ${_MC_P} (4.0 / 16 GT/s)"
echo "  Topology: ${_MC_T} (8C/16T)"
echo "  Cloak:    ${_MC_K}"
echo "  Logging:  ${_MC_L}"
echo "======================================="

export LD_PRELOAD=/app/libhwcompat.so
export _MC_C _MC_P _MC_T _MC_K _MC_L

if [ $# -eq 0 ]; then
    echo "No command specified — dropping to interactive shell"
    exec /bin/bash
else
    exec "$@"
fi
