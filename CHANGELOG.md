# Changelog

## 0.00.2 — 2026-02-21

### Bugfixes
- Fixed SIGSEGV in piped commands (sed, awk) caused by NULL real_* function pointers before constructor init — added lazy `ensure_real_syms()` to all hooks
- Fixed detect.sh Check 2: added cpuinfo processor count vs sysfs directory count comparison
- Fixed detect.sh Check 4: normalized PCIe speed comparison (sysfs "16.0 GT/s" vs lspci "16GT/s")
- Fixed detect.sh Check 5: combo logic now correctly detects spoofed model name
- Fixed C comment containing `*/` that broke compilation (cpu directory glob path)
- Fixed `grep "^model\b"` to `grep "^model[[:space:]]"` for portability

## 0.00.1 — 2026-02-21

### Initial Release
- LD_PRELOAD shared library (`spoof_hw.so`) hooking open/read/close + stdio variants
- CPU spoof: Threadripper 1900X identity via fake `/proc/cpuinfo` (8C/16T, Zen 1 flags)
- PCIe spoof: 32.0 GT/s (PCIe 5.0) via sysfs link speed interception
- DDR5 spoof: SMBIOS Type 17 DMI table generation with DDR5 type marker
- Topology spoof: cpu online/present = 0-15, L3 cache = 4096K per CCX
- Direct CPUID reader (`detect_cpuid`) — immune to LD_PRELOAD
- Anti-spoof detection suite (`detect.sh`) with 10 checks
- Multi-stage Dockerfile (build with gcc, runtime with minimal deps)
- docker-compose.yml with `spoof` and `detect` services
- Per-feature env var toggles (SPOOF_CPU, SPOOF_PCIE, SPOOF_DDR, SPOOF_TOPOLOGY)
