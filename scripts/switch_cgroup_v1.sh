#!/bin/bash -e
# Switch cgroups from v2 to v1 on Ubuntu 22.04 Jammy.
# Works on AWS (BIOS/EFI) and GCP (BIOS) instances.
# Run with sudo. A reboot is required for the change to take effect.

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

# Detect current cgroup version
if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo "cgroups v1 is already active. Nothing to do."
  exit 0
fi

echo "### Switching to cgroups v1 ###"

# Remove v2 flags if present, then add the v1 override:
#   systemd.unified_cgroup_hierarchy=0  — tells systemd to use the legacy (v1) hierarchy
GRUB_FILE=/etc/default/grub

# Strip any previously added cgroup kernel params to avoid duplication
sed -i \
  -e 's/ systemd\.unified_cgroup_hierarchy=[01]//g' \
  -e 's/ cgroup_no_v1=all//g' \
  "$GRUB_FILE"

# Append v1 param to whichever cmdline variable is present.
# AWS Ubuntu uses GRUB_CMDLINE_LINUX; GCP Ubuntu uses GRUB_CMDLINE_LINUX_DEFAULT.
sed -i '/^GRUB_CMDLINE_LINUX\(_DEFAULT\)\?="/ s/"$/ systemd.unified_cgroup_hierarchy=0"/' "$GRUB_FILE"

echo "### Updated GRUB_CMDLINE_LINUX:"
grep '^GRUB_CMDLINE_LINUX' "$GRUB_FILE"

# Regenerate grub config.
# update-grub is the canonical Jammy wrapper — it writes to /boot/grub/grub.cfg
# which is the file actually read at boot (the EFI shimloader chainloads it).
# We also explicitly write to the EFI path as a fallback for setups where they diverge.
update-grub
grub-mkconfig -o /boot/efi/EFI/ubuntu/grub.cfg 2>/dev/null || true

echo "### Rebooting to apply cgroups v1 ..."
shutdown -r now

