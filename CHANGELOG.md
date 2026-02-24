# Changelog

## 0.03.2 — 2026-02-24

### Standalone Spoof Script + Watchdog

**New: `mixer-start.sh` — Standalone spoof + watchdog for VMs**
- Self-contained script runnable via `bash <(wget -qO- ...)` directly on VMs
- Generates random speed values within datacenter range (dl: 1004–1099, ul: 1004–1099, latency: 5–12)
- Builds fake stats image, injects into podman, installs watchdog cron
- First run generates values; subsequent runs reuse existing build files
- Saves config to `/opt/mixer-spoof/.mixer-config` for persistence

**New: Watchdog cron (`mixer-watchdog.sh`)**
- Runs every 5 minutes via `/etc/cron.d/mixer-watchdog`
- Checks if spoofed stats image is present in podman
- Re-builds and re-injects if image was wiped (blue team recovery)
- Silent on success, logs only on re-injection or error (`/var/log/mixer-watchdog.log`)

**Updated: `mixer-provision.sh` — Path alignment + watchdog integration**
- Build path changed from `/tmp/mixer-build/` to `/opt/mixer-spoof/` (aligns with standalone script)
- New `mixer_provision_setup_watchdog()` function — installs watchdog cron via SSH provisioning pipeline
- Watchdog setup added as Phase 7 in provisioning pipeline

**Fixed: `MIXER_VERSION` in `mixer-common.sh`**
- Was still `0.03.0` after v0.03.1 release — now correctly set to `0.03.2`

## 0.03.1 — 2026-02-24

### EPYC 4464P Profile + Conditional GPU UUID Spoofing

**New: `epyc-4464p` CPU profile**
- AMD EPYC 4464P 12C/24T (Zen 4) — entry-level EPYC 4004 server identity
- ASRock Rack B650D4U motherboard (real AM5 server board for EPYC 4004 series)
- Intel I225-LM 2.5G NIC MAC OUI (`A8:A1:59`)
- No CPU flag suppression (Zen 4 is superset of host Zen 3)
- `spoof_gpu_uuid: false` — new field, passes through real GPU UUID

**New: Conditional GPU UUID spoofing (`spoof_gpu_uuid`)**
- New `spoof_gpu_uuid` field in profile catalog (defaults to `true` for backward compat)
- When `false`: Dockerfile skips cuda_check wrapper, SCP skips wrapper file
- Threaded through `mixer_profile_load()` → VM state JSON → provision pipeline
- Existing profiles unaffected (implicit `true` default)

**Updated: `datacenter` speed class**
- Tightened range: 1004–1099 Mbps download/upload (was 800–1200/750–1100)
- Latency: 5–12ms (was 5–25ms)

## 0.03.0 — 2026-02-23

### Mixer CLI — Automated Proxmox VM Spoofing Tool

**New: `mixer` CLI entrypoint** — Full lifecycle management for spoofed VMs
- `mixer init` — One-time setup: downloads Ubuntu 24.04 cloud image, creates Proxmox template VM (9000), generates SSH keypair
- `mixer create <profile> [options]` — Creates, configures, and provisions a spoofed VM with a single command
- `mixer list` — Lists all mixer-managed VMs with status, profile, IP, GPU assignment
- `mixer status <vmid>` — Detailed VM status showing hardware identity, network, GPU
- `mixer destroy <vmid>` — Full teardown: stops VM, releases GPU, cleans state
- `mixer provision <vmid>` — Re-runs post-boot provisioning pipeline
- `mixer profiles` / `mixer profiles show <name>` — Browse CPU profile catalog
- `mixer gpu assign/release/status` — Single-GPU passthrough management with auto-release

**New: CPU Profile Catalog (`profiles/catalog.json`)**
- 5 pre-built AMD profiles: Threadripper 1900X, Ryzen 7 5800X, Ryzen 9 5900X, EPYC 7313, Ryzen 9 7950X
- Each profile includes matching SMBIOS identity (motherboard vendor/model)
- CPU flag suppressions per architecture (Zen 1 suppresses AVX-512, etc.)
- Realistic MAC OUIs per profile (Intel, Realtek, Supermicro)
- 3 speed classes (datacenter/business/residential) with randomized values per VM

**New: Anti-Detection (Tier 1) — Automatic per-VM**
- SMBIOS/DMI: Realistic BIOS vendor (AMI), motherboard identity matching CPU profile
- CPUID: `kvm=off`, `hv-vendor-id=AuthAMD` — defeats `systemd-detect-virt`
- CPU flags: Per-profile suppression (e.g., Zen 1 can't have AVX-512)
- Disk identity: WDC WDS500G2B0A with randomized serial (not "QEMU HARDDISK")
- NIC: e1000e emulation with realistic vendor MAC (not virtio + 52:54:00)
- qemu-guest-agent: Disabled + masked after cloud-init completes

**New: Library Modules (`lib/`)**
- `mixer-common.sh` — Logging, colors, config/state helpers, random generators, SSH wrappers
- `mixer-profiles.sh` — Profile catalog loading, listing, detail display
- `mixer-stealth.sh` — QEMU args generation (CPU, SMBIOS, SMP, disk, MAC, GPU UUID)
- `mixer-cloudinit.sh` — Cloud-init user-data generation from template
- `mixer-vm.sh` — VM lifecycle (init, create, list, status, destroy) via Proxmox `qm`
- `mixer-gpu.sh` — GPU passthrough management with state tracking
- `mixer-provision.sh` — SSH provisioning pipeline (wait, SCP, build, inject, verify)

**New: Cloud-Init Template (`templates/cloud-init-user.yaml.tpl`)**
- Auto-installs: Docker CE, NVIDIA driver 550, container toolkit, utilities
- Creates `nosana` user with SSH key + passwordless sudo
- Disables qemu-guest-agent after provisioning (stealth)
- Reboots for NVIDIA driver initialization

## 0.02.1 — 2026-02-23

### GPU UUID Spoofing

**New: `cuda-check-wrapper.sh` — Drop-in `/cuda_check` replacement**
- Runs real `/cuda_check_real` binary and pipes output through `jq`
- Replaces real GPU UUID (`GPU-2e5ea51a-...`) with spoofed UUID (`GPU-a7f3e920-...`)
- Passes through all arguments and preserves exit codes

**Updated: `Dockerfile.stats` — Now includes GPU UUID spoof**
- Renames `/cuda_check` to `/cuda_check_real` in the stats image
- Copies `cuda-check-wrapper.sh` as `/cuda_check`
- No additional build steps — `speed-spoof.sh` handles both speed and UUID spoofing

**Updated: `DEPLOYMENT.md`**
- Added GPU UUID row to "What's Spoofed" table
- Added "Phase 5: GPU UUID Spoofing" section
- Updated Phase 3.1 one-liner to include UUID spoof files
- Updated verification section with UUID check command
- Updated "Files in This Repo" table

## 0.02.0 — 2026-02-22

### Network Speed Spoofing (Proxmox VM deployment)

**Architecture shift: LD_PRELOAD → Proxmox VM**
- CPU/topology spoofing now handled at hypervisor level (QEMU CPUID override)
- LD_PRELOAD library (`libhwcompat.so`) no longer needed for CPU identity
- This release adds network speed spoofing to complement the VM-level CPU spoof

**New: `fake-fast` — Drop-in replacement for Netflix fast-cli**
- Returns fixed JSON: `{"downloadSpeed":1076,"uploadSpeed":1041,"latency":21}`
- Accepts any flags silently (matches real `fast -u --json --timeout 30` usage)

**New: `Dockerfile.stats` — Fake stats image builder**
- Builds from `nosana/stats:v1.2.1` base, replaces `/usr/local/bin/fast`
- Used by both `speed-spoof.sh` and `nosana-start.sh`

**New: `speed-spoof.sh` — Standalone injection script**
- Builds fake stats image and loads it into running podman container
- Tags with both `registry.hub.docker.com/` and `docker.io/` prefixes
- Fixes registry prefix mismatch (nosana uses `registry.hub.docker.com/`, Docker defaults to `docker.io/`)
- Can be run manually at any time while the nosana stack is running

**Rewritten: `nosana-start.sh` v0.02.0**
- Removed LD_PRELOAD injection (no longer needed in VM approach)
- Patches official start.sh to add persistent podman storage volume (`nosana-podman-storage`)
- Auto-injects fake stats image after podman container starts
- Skips injection if fake image already present (persistent storage)
- Graceful fallback: warns but continues if build files or podman not available

**Root cause fix: Registry prefix mismatch**
- Nosana jobs reference `registry.hub.docker.com/nosana/stats:v1.2.1`
- Docker defaults to `docker.io/nosana/stats:v1.2.1`
- Podman treats these as different images — fake image must be tagged with both prefixes

## 0.01.4 — 2026-02-22

### Fix: nosana-start.sh TTY passthrough

- Replaced `echo | bash -s` with temp file + `</dev/tty` for patched script execution
- Piping consumed stdin, making docker's `-t` flag fail ("not a TTY")
- Temp file approach keeps stdin connected to the terminal

## 0.01.3 — 2026-02-22

### Fix: piped execution for both scripts

**mixer.sh**
- Removed `set -u` (nounset) — `BASH_SOURCE[0]` is unset when piped via `wget | bash`
- Dockerfile detection: checks `./Dockerfile`, then script dir, then clones from GitHub
- Uses `${BASH_SOURCE[0]:-}` safe expansion to avoid unbound variable errors

**nosana-start.sh**
- Fixed sed injection target: `docker run \` instead of `${DOCKER_ARGS[@]}`
- Old target was inside a multi-line `docker run` continuation — broke shell parsing
- New target inserts standalone `DOCKER_ARGS+=()` statement before the `docker run` block

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
