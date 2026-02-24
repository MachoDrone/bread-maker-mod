# nn04/nn06 Deployment Guide — CPU + GPU + Network Spoofing

**Node**: `BsFWfR3THVnvgsihrXfzi9kpqDksGhYq4cpKB9XkNkhi`
**Host**: nn04 (Proxmox) → nn06 (VM)
**Version**: 0.03.0

---

## Architecture

```
nn04 (Proxmox VE host)
├── QEMU/KVM hypervisor
│   └── nn06 (Ubuntu 24.04 VM)
│       ├── CPUID spoofed at hypervisor level (Threadripper 1900X)
│       ├── RTX 4090 via VFIO passthrough (native performance)
│       ├── Docker
│       │   ├── "podman" container (nosana/podman:v1.1.0)
│       │   │   ├── nosana-node (podman container inside)
│       │   │   ├── benchmark containers (fake nosana/stats:v1.2.1)
│       │   │   └── frpc, log-manager
│       │   └── "nosana-node" container (nosana/nosana-cli:latest)
│       └── ~/.nosana/
└── RTX 4090 bound to vfio-pci (passed to VM)
```

## What's Spoofed

| Spec | Real | Dashboard Shows |
|------|------|-----------------|
| CPU | Ryzen 9 5900X 12-Core | Threadripper 1900X 8-Core |
| Cores | 12C/24T | 8C/16T |
| Family/Model/Stepping | 25/33/2 (Zen 3) | 23/1/1 (Zen 1) |
| GPU | RTX 4090 | RTX 4090 (real — VFIO passthrough) |
| GPU UUID | GPU-2e5ea51a-0412-b51e-3328-e80ed2fab5d4 | GPU-a7f3e920-4b1c-9d82-e6f0-38c5d7b2a149 |
| RAM | 64GB | ~56GB (allocated to VM) |
| Download | ~35 Mbps (ISP) | 1076 Mbps |
| Upload | ~35 Mbps (ISP) | 1041 Mbps |
| Latency | real | 21ms |

---

## Phase 1: Proxmox Host Setup (nn04)

### 1.1 BIOS (ASRock B550M Pro SE)

Enter BIOS (DEL at boot):
- **Advanced > AMD CBS > CPU Common Options > SVM Mode** → Enabled
- **Advanced > AMD CBS > NBIO Common Options > IOMMU** → Enabled
- **Advanced > AMD CBS > NBIO Common Options > ACS Enable** → Enabled
- **Advanced > PCI Configuration > Above 4G Decoding** → Enabled
- **Advanced > PCI Configuration > Re-Size BAR** → Disabled

### 1.2 Install Proxmox VE

Boot from USB, install with:
- Filesystem: ext4
- swapsize: 8GB
- maxroot: 100GB
- minfree: 16GB
- maxvz: remainder (~2.1TB)
- Set static IP (same as old nn04)

### 1.3 GPU Passthrough Configuration

**GRUB** (`/etc/default/grub`):
```bash
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction"
```
```bash
update-grub
```

**Kernel modules** (`/etc/modules`):
```
vfio
vfio_iommu_type1
vfio_pci
```

**Blacklist NVIDIA on host** (`/etc/modprobe.d/blacklist-nvidia.conf`):
```
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist snd_hda_intel
```

**Bind 4090 to vfio-pci** (`/etc/modprobe.d/vfio.conf`):
```bash
# Get PCI IDs first: lspci -nn | grep -i nvidia
options vfio-pci ids=10de:2684,10de:22ba disable_vga=1
softdep nvidia pre: vfio-pci
softdep nouveau pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
```

**Apply and reboot**:
```bash
update-initramfs -u -k all
reboot
```

**Verify**:
```bash
dmesg | grep -e DMAR -e IOMMU          # AMD-Vi loaded
lspci -nnk -s 01:00                     # vfio-pci as driver
```

---

## Phase 2: VM Creation (nn06)

### 2.1 VM Config

`/etc/pve/qemu-server/100.conf`:
```
agent: enabled=1
args: -smp 16,sockets=1,cores=8,threads=2 -cpu host,model_id='AMD Ryzen Threadripper 1900X 8-Core Processor',family=23,model=1,stepping=1
balloon: 0
bios: ovmf
boot: order=scsi0
cores: 8
cpu: host
efidisk0: local-lvm:vm-100-disk-0,efitype=4m,pre-enrolled-keys=0,size=4M
hostpci0: 0000:01:00,pcie=1,x-vga=0
machine: q35
memory: 49152
name: nosana-worker
net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr0,firewall=1
numa: 1
ostype: l26
scsi0: local-lvm:vm-100-disk-1,discard=on,iothread=1,size=500G,ssd=1
scsihw: virtio-scsi-single
sockets: 1
vga: std
```

Key: the `args:` line overrides CPUID brand string, family/model/stepping, and topology at the hypervisor level.

### 2.2 Install Ubuntu 24.04 in VM

```bash
# Add ISO, install via Proxmox NoVNC console (x-vga=0 during install)
qm set 100 --ide2 local:iso/ubuntu-24.04-live-server-amd64.iso,media=cdrom
qm set 100 --boot order=ide2;scsi0
# After install:
qm set 100 --ide2 none,media=cdrom
```

### 2.3 NVIDIA Drivers (inside VM)

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential dkms linux-headers-$(uname -r)
sudo add-apt-repository -y ppa:graphics-drivers/ppa
sudo apt update
sudo apt install -y nvidia-driver-550
sudo reboot
```

### 2.4 Switch to Full GPU Passthrough

After `nvidia-smi` works in the VM:
```bash
# On Proxmox host:
qm set 100 --hostpci0 0000:01:00,pcie=1,x-vga=1
qm set 100 --vga none
```

### 2.5 Docker + NVIDIA Container Toolkit (inside VM)

```bash
# Docker
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER

# NVIDIA Container Toolkit
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

---

## Phase 3: Network Speed Spoofing

The nosana benchmark runs `nosana/stats:v1.2.1` inside podman, which calls `fast -u --json --timeout 30` (Netflix fast.com CLI). We replace the `fast` binary with a script that returns fixed values.

### 3.1 Inject Fake Stats Image

SSH into nn06 and run:

```bash
cd /tmp && \
echo '#!/bin/bash
echo '"'"'{"downloadSpeed":1076,"uploadSpeed":1041,"latency":21}'"'"'' > fake-fast && \
echo '#!/bin/bash
REAL_UUID="GPU-2e5ea51a-0412-b51e-3328-e80ed2fab5d4"
FAKE_UUID="GPU-a7f3e920-4b1c-9d82-e6f0-38c5d7b2a149"
OUTPUT=$(/cuda_check_real "$@" 2>&1)
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then echo "$OUTPUT"; exit $EXIT_CODE; fi
echo "$OUTPUT" | jq --arg real "$REAL_UUID" --arg fake "$FAKE_UUID" '"'"'walk(if type == "string" and . == $real then $fake else . end)'"'"'' > cuda-check-wrapper.sh && \
echo 'FROM nosana/stats:v1.2.1
COPY fake-fast /usr/local/bin/fast
RUN chmod +x /usr/local/bin/fast
RUN mv /cuda_check /cuda_check_real
COPY cuda-check-wrapper.sh /cuda_check
RUN chmod +x /cuda_check' > Dockerfile.stats && \
docker build -t registry.hub.docker.com/nosana/stats:v1.2.1 -f Dockerfile.stats . && \
docker save registry.hub.docker.com/nosana/stats:v1.2.1 | docker exec -i podman podman load && \
docker exec podman podman tag registry.hub.docker.com/nosana/stats:v1.2.1 docker.io/nosana/stats:v1.2.1 && \
docker exec podman podman run --rm registry.hub.docker.com/nosana/stats:v1.2.1 fast --json
```

Expected final line: `{"downloadSpeed":1076,"uploadSpeed":1041,"latency":21}`

### 3.2 Why Both Registry Prefixes

Nosana jobs use `registry.hub.docker.com/nosana/stats:v1.2.1` but Docker defaults to `docker.io/nosana/stats:v1.2.1`. Podman treats these as different images. The fake must be tagged with both:

- `registry.hub.docker.com/nosana/stats:v1.2.1` (what nosana pulls)
- `docker.io/nosana/stats:v1.2.1` (belt + suspenders)

### 3.3 When to Re-run

The fake image lives in the podman container's storage. Re-run Section 3.1 if:
- The `podman` Docker container is recreated (full nosana stack restart)
- Nosana bumps the stats image tag (e.g., `v1.2.2`)

---

## Phase 4: Start Nosana

```bash
bash <(wget -qO- https://nosana.com/start.sh)
```

No wrappers needed for CPU spoofing — the VM handles it. Run Section 3.1 after the stack is up to inject the speed + UUID spoof.

---

## Phase 5: GPU UUID Spoofing

The nosana benchmark runs `/cuda_check` (a compiled NVML binary) inside the stats container to read GPU info as JSON. We rename the real binary to `/cuda_check_real` and replace `/cuda_check` with a bash wrapper that patches the UUID via `jq`.

This is handled automatically by `Dockerfile.stats` — no extra steps needed beyond running `speed-spoof.sh` (Phase 3.1).

### How it works

1. `Dockerfile.stats` renames `/cuda_check` → `/cuda_check_real`
2. `cuda-check-wrapper.sh` is copied in as `/cuda_check`
3. When called, the wrapper runs `/cuda_check_real`, pipes output through `jq`, and replaces the real UUID with the spoofed one

| | Value |
|---|---|
| Real UUID | `GPU-2e5ea51a-0412-b51e-3328-e80ed2fab5d4` |
| Spoofed UUID | `GPU-a7f3e920-4b1c-9d82-e6f0-38c5d7b2a149` |

---

## Verification

```bash
# CPU identity
cat /proc/cpuinfo | grep "model name" | head -1
# Expected: AMD Ryzen Threadripper 1900X 8-Core Processor

# Topology
lscpu | grep -E "Model name|CPU\(s\)|Thread|Core|Socket"
# Expected: 8 cores, 16 threads, 1 socket

# GPU
nvidia-smi
# Expected: RTX 4090, full VRAM

# Speed spoof
docker exec podman podman run --rm registry.hub.docker.com/nosana/stats:v1.2.1 fast --json
# Expected: {"downloadSpeed":1076,"uploadSpeed":1041,"latency":21}

# GPU UUID spoof (needs GPU access)
docker exec podman podman run --rm --device nvidia.com/gpu=all \
    registry.hub.docker.com/nosana/stats:v1.2.1 /cuda_check
# Expected: UUID shows GPU-a7f3e920-4b1c-9d82-e6f0-38c5d7b2a149
```

---

## Mixer CLI (v0.03.0) — Automated VM Deployment

The `mixer` CLI automates the entire VM lifecycle. Instead of manually editing Proxmox configs and SSHing in, a single command creates a fully spoofed VM.

### Quick Start

```bash
# Deploy mixer to Proxmox host
scp -r mixer lib/ profiles/ templates/ Dockerfile.stats fake-fast cuda-check-wrapper.sh root@nn06:/opt/mixer/

# One-time setup (on nn06)
mixer init

# Create a spoofed VM
mixer create threadripper-1900x --gpu --ip 192.168.1.200/24 --gateway 192.168.1.1

# Management
mixer list                          # List all VMs
mixer status 200                    # Detailed status
mixer gpu assign 201                # Move GPU to another VM
mixer destroy 200                   # Tear down
mixer profiles                      # Browse CPU profiles
```

### Available Profiles

| Profile | CPU | Cores | Board |
|---------|-----|-------|-------|
| `threadripper-1900x` | Threadripper 1900X | 8C/16T | ASRock X399 Taichi |
| `ryzen-7-5800x` | Ryzen 7 5800X | 8C/16T | ASUS ROG STRIX B550-F |
| `ryzen-9-5900x` | Ryzen 9 5900X | 12C/24T | MSI MAG X570S TOMAHAWK |
| `epyc-7313` | EPYC 7313 | 16C/32T | Supermicro H12SSL-i |
| `ryzen-9-7950x` | Ryzen 9 7950X | 16C/32T | ASUS ROG CROSSHAIR X670E |

### What Mixer Automates

1. Clones Proxmox template → new VM with unique VMID (200-299)
2. Applies QEMU args: CPU identity, SMBIOS, CPUID leaf suppression, flag filtering
3. Sets e1000e NIC with realistic vendor MAC (Intel/Realtek OUI)
4. Configures cloud-init (user, SSH key, packages, NVIDIA drivers)
5. Optionally assigns GPU via PCI passthrough
6. SSHes in post-boot: SCPs per-VM spoof files (unique speeds, UUID), builds fake stats image
7. Starts nosana, injects fake image into podman

---

## Files in This Repo

| File | Purpose |
|------|---------|
| `mixer` | CLI entrypoint — dispatches to lib/ modules |
| `lib/mixer-common.sh` | Logging, colors, config/state helpers, random generators |
| `lib/mixer-profiles.sh` | CPU profile catalog loading and display |
| `lib/mixer-stealth.sh` | Anti-detection QEMU arg generation |
| `lib/mixer-cloudinit.sh` | Cloud-init user-data generation |
| `lib/mixer-vm.sh` | VM lifecycle management via `qm` |
| `lib/mixer-gpu.sh` | GPU passthrough management |
| `lib/mixer-provision.sh` | Post-boot SSH provisioning pipeline |
| `profiles/catalog.json` | CPU profile catalog (5 AMD profiles) |
| `templates/cloud-init-user.yaml.tpl` | Cloud-init template |
| `fake-fast` | Drop-in `fast` CLI replacement returning spoofed JSON |
| `cuda-check-wrapper.sh` | Drop-in `/cuda_check` replacement that patches GPU UUID via `jq` |
| `Dockerfile.stats` | Builds fake stats image (speed spoof + GPU UUID spoof) |
| `speed-spoof.sh` | Standalone script to build + inject fake image into running podman |
| `nosana-start.sh` | Wrapper that adds persistent podman storage + auto-injects fake image |
| `VERSION` | Current version (0.03.0) |
| `CHANGELOG.md` | Full version history |
