# Changelog

## 0.01.1 — 2026-02-22

### Nosana Node Deployment: Wrapper + Deploy Scripts

**New: `mixer.sh` — Build & deploy script**
- Builds libhwcompat.so from Dockerfile and extracts to `~/.nosana/`
- Auto-detects multi-GPU setups: copies to all `~/.nosana-gpu*/` directories
- Verifies deployment with file listing and summary

**New: `nosana-start.sh` — Nosana node wrapper**
- Downloads official `https://nosana.com/start.sh` at runtime
- Injects `LD_PRELOAD` and `_MC_*` env vars into `DOCKER_ARGS` via sed
- Passes through all user arguments (`--pre-release`, `--verbose`, etc.)
- Pre-flight check ensures library is deployed before launching

**glibc compatibility fix**
- Dockerfile build stage changed from `ubuntu:24.04` (glibc 2.39) to `debian:12` (glibc 2.36)
- Ensures libhwcompat.so loads correctly inside nosana-node container (Debian 12 bookworm)
- Runtime stage unchanged (`ubuntu:24.04` for standalone test container)

## 0.01.0 — 2026-02-21

### Evasion Hardening: CPUID-Consistent Identity + Self-Cloaking

**Identity switch: Threadripper 1900X -> Ryzen 7 5800X**
- CPUID family/model/stepping (25/33/2) now matches real 5900X hardware
- Zen 3 flags and bugs copied verbatim from host `/proc/cpuinfo`
- CPUID level updated 13 -> 16, bogomips 7186.36 -> 7386.54
- L3 cache: 4096K -> 32768K (1 CCD, consistent with 5800X)
- PCIe: 32.0 GT/s (PCIe 5.0) -> 16.0 GT/s (PCIe 4.0, consistent with Zen 3)
- Removed DDR5 spoof (real DDR4 matches 5800X — no spoof needed)

**Self-cloaking**
- Constructor strips `LD_PRELOAD` and all `_MC_*` config vars from environment
- `/proc/self/maps` hook filters out lines containing `libhwcompat.so`
- `/proc/self/environ` hook strips `_MC_*` and `LD_PRELOAD=` entries
- `opendir`/`readdir`/`closedir` hooks hide cpu16-cpu23 directories

**Build/deploy changes**
- Library renamed: `spoof_hw.so` -> `libhwcompat.so`
- Env vars renamed: `SPOOF_CPU` -> `_MC_C`, `SPOOF_PCIE` -> `_MC_P`, etc.
- Removed `SPOOF_DDR` / `_MC_D` (DDR spoof no longer needed)
- Added `_MC_K` (cloak toggle, default on)
- Removed DMI table generation (~120 lines of C)

**Detection suite updates**
- Check 5: Updated combo logic for Zen 3 Ryzen 5000 series
- Check 6: Added 5800X L3 cache expectations
- Check 8b: Broadened suspicious library search (hwcompat, libfake, inject, etc.)
- Check 9: Now searches for `_MC_` and `LD_PRELOAD` patterns
- Check 11 (NEW): CPUID brand string vs cpuinfo model name cross-check

**Expected results**: 1 FAIL (CPUID brand string — hard wall) / 14+ PASS

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
