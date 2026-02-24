#cloud-config
# mixer cloud-init template — VM {{VMID}}
# Installs: Docker, NVIDIA drivers, container toolkit, utilities

hostname: mixer-{{VMID}}
manage_etc_hosts: true

users:
  - name: {{USER}}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - {{SSH_PUBKEY}}

package_update: true
package_upgrade: true

packages:
  - qemu-guest-agent
  - jq
  - curl
  - wget
  - ca-certificates
  - gnupg
  - lsb-release
  - build-essential
  - linux-headers-generic
  - cron
  - ethtool
  - pciutils

runcmd:
  # --- Docker CE ---
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - usermod -aG docker {{USER}}

  # --- NVIDIA Driver ---
  - add-apt-repository -y ppa:graphics-drivers/ppa
  - apt-get update
  - apt-get install -y nvidia-driver-550

  # --- NVIDIA Container Toolkit ---
  - curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  - 'curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list'
  - apt-get update
  - apt-get install -y nvidia-container-toolkit
  - nvidia-ctk runtime configure --runtime=docker
  - systemctl restart docker

  # --- Disable qemu-guest-agent (stealth) ---
  - systemctl stop qemu-guest-agent
  - systemctl disable qemu-guest-agent
  - systemctl mask qemu-guest-agent

  # --- Signal completion ---
  - touch /var/lib/cloud/instance/mixer-ready

power_state:
  mode: reboot
  message: "mixer cloud-init complete — rebooting for NVIDIA driver"
  timeout: 30
  condition: true
