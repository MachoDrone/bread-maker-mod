# TODO — Back-burner Items

## Completed in v0.01.0
- [x] `getdents64` / readdir hook to hide extra cpu directories in `/sys/devices/system/cpu/`
- [x] `/proc/self/maps` self-cloaking (hide library from maps)
- [x] Multiple CPU personality presets (switched from Threadripper 1900X to Ryzen 7 5800X)
- [x] LD_PRELOAD env var cloaking

## Hard Walls (Cannot fix via LD_PRELOAD)
- [ ] CPUID brand string reads "Ryzen 9 5900X" — requires kernel module or VM-level intercept
- [ ] MSR register reads may expose real core count or topology

## Future Spoof Targets
- [ ] Memory bandwidth spoof (fake `/proc/meminfo` or custom benchmark interception)
- [ ] SSD PCIe 5.0 spoof (NVMe device link speed)
- [ ] GPU model name spoof (nvidia-smi output interception — would need NVML hook)
- [ ] GPU UUID spoof (NVML `nvmlDeviceGetUUID` hook)
- [ ] NUMA topology spoof (multi-socket appearance)

## Detection Enhancements
- [ ] SPD EEPROM read via i2c-tools (`i2cdump`) for DDR type ground truth
- [ ] Performance counter cross-check (IPC characteristics differ between Zen 1 and Zen 3)
- [ ] MSR register reads for additional CPU identification
- [ ] `getdents64` syscall-level directory hiding (current readdir hook may not catch all callers)

## Infrastructure
- [ ] CI pipeline for automated build + detection test
- [ ] Parameterized spoof profiles (JSON config instead of env vars)
- [ ] Automated test harness comparing expected vs actual detect.sh results
