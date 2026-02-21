# TODO — Back-burner Items

## Future Spoof Targets
- [ ] Memory bandwidth spoof (fake `/proc/meminfo` or custom benchmark interception)
- [ ] SSD PCIe 5.0 spoof (NVMe device link speed)
- [ ] GPU model name spoof (nvidia-smi output interception — would need NVML hook)
- [ ] GPU UUID spoof (NVML `nvmlDeviceGetUUID` hook)
- [ ] NUMA topology spoof (multi-socket appearance)

## Detection Enhancements
- [ ] SPD EEPROM read via i2c-tools (`i2cdump`) for DDR type ground truth
- [ ] `getdents64` hook to hide extra cpu directories in `/sys/devices/system/cpu/`
- [ ] Performance counter cross-check (IPC characteristics differ between Zen 1 and Zen 3)
- [ ] `/proc/self/maps` self-cloaking (hide spoof_hw.so from maps — advanced evasion)
- [ ] MSR register reads for additional CPU identification

## Infrastructure
- [ ] CI pipeline for automated build + detection test
- [ ] Parameterized spoof profiles (JSON config instead of env vars)
- [ ] Multiple CPU personality presets (not just Threadripper 1900X)
