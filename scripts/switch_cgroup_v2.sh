#!/bin/bash -e
# Switch cgroups from v1 to v2 on Ubuntu 22.04 Jammy.
# Works on AWS (BIOS/EFI) and GCP (BIOS) instances.
# Run with sudo. A reboot is required for the change to take effect.

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

# Detect current cgroup version
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo "cgroups v2 is already active. Nothing to do."
  exit 0
fi

echo "### Switching to cgroups v2 ###"

# Remove v1 override if present, then add v2 flags:
#   systemd.unified_cgroup_hierarchy=1  — tells systemd to use unified (v2) hierarchy
#   cgroup_no_v1=all                    — disables all v1 controllers so nothing falls back to v1
GRUB_FILE=/etc/default/grub

# Strip any previously added cgroup kernel params to avoid duplication
sed -i \
  -e 's/ systemd\.unified_cgroup_hierarchy=[01]//g' \
  -e 's/ cgroup_no_v1=all//g' \
  "$GRUB_FILE"

# Append v2 params to whichever cmdline variable is present.
# AWS Ubuntu uses GRUB_CMDLINE_LINUX; GCP Ubuntu uses GRUB_CMDLINE_LINUX_DEFAULT.
sed -i '/^GRUB_CMDLINE_LINUX\(_DEFAULT\)\?="/ s/"$/ systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"/' "$GRUB_FILE"

echo "### Updated GRUB_CMDLINE_LINUX:"
grep '^GRUB_CMDLINE_LINUX' "$GRUB_FILE"

# Regenerate grub config.
# update-grub is the canonical Jammy wrapper — it writes to /boot/grub/grub.cfg
# which is the file actually read at boot (the EFI shimloader chainloads it).
# We also explicitly write to the EFI path as a fallback for setups where they diverge.
update-grub
grub-mkconfig -o /boot/efi/EFI/ubuntu/grub.cfg 2>/dev/null || true

echo "### Rebooting to apply cgroups v2 ..."
shutdown -r now

