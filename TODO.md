# TODO — Back-burner Items

## Completed in v0.03.2
- [x] Standalone `mixer-start.sh` — wget+bash runnable on VM, no SSH from host needed
- [x] Watchdog cron (every 5 min) — auto re-injects spoofed stats image if wiped
- [x] Persistent build files at `/opt/mixer-spoof/` (survives reboots)
- [x] Stale image detection — compares speed values, not just image presence
- [x] Provision pipeline path aligned `/tmp/mixer-build/` → `/opt/mixer-spoof/`
- [x] `cron` added to cloud-init packages
- [x] Fixed `MIXER_VERSION` stuck at 0.03.0

## Completed in v0.03.0
- [x] Mixer CLI tool — full VM lifecycle automation
- [x] CPU profile catalog (5 AMD profiles with SMBIOS, flag suppressions)
- [x] Anti-detection Tier 1: SMBIOS, CPUID, CPU flags, disk identity, NIC, qemu-guest-agent
- [x] Cloud-init template with Docker, NVIDIA drivers, container toolkit
- [x] GPU passthrough management (single GPU, auto-release between VMs)
- [x] Post-boot provisioning pipeline (SSH wait, SCP, build, inject, verify)
- [x] Per-VM unique values: MAC, disk serial, GPU UUID, speed class randomization
- [x] Parameterized spoof profiles (JSON catalog instead of manual config)

## Completed in v0.02.0
- [x] Network speed spoofing via fake stats image injection
- [x] Registry prefix mismatch fix (registry.hub.docker.com vs docker.io)
- [x] Persistent podman storage volume for image cache durability
- [x] Automated fake image injection in nosana-start.sh wrapper

## Completed in v0.01.0
- [x] `getdents64` / readdir hook to hide extra cpu directories in `/sys/devices/system/cpu/`
- [x] `/proc/self/maps` self-cloaking (hide library from maps)
- [x] Multiple CPU personality presets (switched from Threadripper 1900X to Ryzen 7 5800X)
- [x] LD_PRELOAD env var cloaking

## Hard Walls (Cannot fix via LD_PRELOAD — resolved by Proxmox VM)
- [x] CPUID brand string — now spoofed at hypervisor level via QEMU `-cpu model_id=`
- [x] MSR register reads — VM presents consistent topology

## Future Spoof Targets
- [ ] Memory bandwidth spoof (fake `/proc/meminfo` or custom benchmark interception)
- [ ] SSD PCIe 5.0 spoof (NVMe device link speed)
- [ ] GPU model name spoof (nvidia-smi output interception — would need NVML hook)
- [ ] NUMA topology spoof (multi-socket appearance)

## Mixer CLI Enhancements
- [ ] `mixer snapshot <vmid>` — snapshot/restore VM state
- [ ] `mixer clone <vmid>` — clone existing mixer VM with new identity
- [ ] `mixer update-image` — re-download cloud image when Ubuntu releases update
- [ ] Profile hot-reload — detect catalog.json changes without restart
- [ ] Multi-GPU support — track N GPUs, assign independently
- [ ] DHCP IP discovery — poll qemu-guest-agent or ARP table for auto-assigned IPs
- [ ] Intel CPU profiles — for Intel-based Proxmox hosts

## Operational
- [ ] Monitor nosana for stats image tag updates (e.g., v1.2.2) — would need Dockerfile.stats update
- [ ] Investigate digest-based image references (would bypass our cached fake)
- [ ] Vendor-reset kernel module for RTX 4090 reset bug on VM stop/start

## Detection Enhancements
- [ ] SPD EEPROM read via i2c-tools (`i2cdump`) for DDR type ground truth
- [ ] Performance counter cross-check (IPC characteristics differ between Zen 1 and Zen 3)

## Infrastructure
- [ ] CI pipeline for automated build + detection test
- [ ] Automated test harness comparing expected vs actual detect.sh results
