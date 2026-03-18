#!/bin/bash -e
# Print the currently active cgroup version.

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  echo "cgroups v2 is active"
else
  echo "cgroups v1 is active"
fi

# Show kernel cmdline params for reference
echo ""
echo "### Kernel cmdline (cgroup-related params):"
tr ' ' '\n' < /proc/cmdline | grep -i cgroup || echo "(none)"

# Show mounted cgroup filesystems
echo ""
echo "### Mounted cgroup filesystems:"
mount | grep cgroup

