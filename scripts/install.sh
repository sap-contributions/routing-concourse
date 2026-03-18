#!/bin/bash -e
# Run with sudo.

# Create users and groups
getent group docker >/dev/null || addgroup --system docker
id -u concourse >/dev/null 2>&1 || useradd concourse

# Mount persistent disk
DISK_DEVICE=$2
/concourse/scripts/mount.sh "${DISK_DEVICE}" /workspace concourse

# Configure docker storage
mkdir -p /workspace/docker
if [ ! -e /var/lib/docker ]; then
  ln -s /workspace/docker /var/lib/docker
fi

# Install software
apt-get -qq update
apt-get -qq install tree git ca-certificates curl gnupg

# Add docker repository
install -m 0755 -d /etc/apt/keyrings
[[ ! -f /etc/apt/keyrings/docker.gpg ]] && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install docker
VERSION_STRING=$1
apt-get -qq update
apt-get -qq install docker-ce="$VERSION_STRING" docker-ce-cli="$VERSION_STRING" containerd.io docker-buildx-plugin docker-compose-plugin

#create/enable swapping
# Check if the swap entry already exists in /etc/fstab
if ! grep -q "swap" /etc/fstab; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  swapon --show
  echo "/swapfile none swap sw 0 0" | tee -a /etc/fstab > /dev/null
  echo "Swap file created and enabled, and entry added to /etc/fstab."
else
   echo "Swap entry already exists in /etc/fstab. Skipping swap setup."
fi
