#!/bin/bash -e

echo "### Switching to cgroups v2 ###"

# Strip any previously added cgroup kernel params to avoid duplication
GRUB_FILE=/etc/default/grub
sed -i \
  -e 's/ systemd\.unified_cgroup_hierarchy=[01]//g' \
  -e 's/ cgroup_no_v1=all//g' \
  "$GRUB_FILE"

# Append v2 params to whichever cmdline variable is present.
sed -i '/^GRUB_CMDLINE_LINUX\(_DEFAULT\)\?="/ s/"$/ systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"/' "$GRUB_FILE"

echo "### Updated GRUB_CMDLINE_LINUX(_DEFAULT):"
grep '^GRUB_CMDLINE_LINUX' "$GRUB_FILE"



# Regenerate grub config.
# update-grub is the canonical Jammy wrapper — it writes to /boot/grub/grub.cfg
update-grub

read -r -p "### Reboot now to apply cgroups v2? [y/N] " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
  echo "### Rebooting ..."
  shutdown -r now
else
  echo "### Reboot skipped. Run 'sudo shutdown -r now' manually when ready."
fi
