#!/bin/bash -e
# Run with sudo.

DEV=/dev/"$1"
TARGET="$2"
FSTYPE=ext4

# NVMe devices (e.g. nvme1n1) use 'p1' suffix for partitions, others (sdb, xvdf) use '1'
if echo "$1" | grep -q "nvme"; then
  PART="${DEV}p1"
else
  PART="${DEV}1"
fi

if mount | grep "$TARGET" >/dev/null; then
  echo "Found mounted workspace filesystem $TARGET"
else
  echo "workspace mount not found"

  if [ -d "$TARGET" ]; then
    echo "Found workspace folder"
  else
    mkdir -p "$TARGET"
    echo "Created workspace folder"
  fi
  chown "$3":"$3" "$TARGET" || true
  if [ "$3" == concourse ]; then
    chmod g+sw "$TARGET" || true
  fi

  if [ ! -b "$PART" ]; then
    echo "file system device not found"
    if [ ! -b "$DEV" ]; then
      echo "volume device $DEV not found or no block device"
      exit 1
    fi

    if ! fdisk -l "$DEV" 2>&1 | grep "$PART" >/dev/null; then
      echo "volume not prepared"
      echo -e "n\\np\\n\\n\\n\\nw\\nw\\n" | fdisk "$DEV"
    else
      echo "Found partition table"
      echo -e "p\\nw\\n" | fdisk "$DEV" # (re)create device file
    fi
    mkfs -t "$FSTYPE" "$PART" || { echo "cannot create filesystem">&2; exit 1; }
    echo "Created volume filesystem"
  elif ! blkid -s TYPE "$PART" | grep -q "$FSTYPE"; then
    echo "Partition exists but has no valid filesystem, formatting..."
    mkfs -t "$FSTYPE" "$PART" || { echo "cannot create filesystem">&2; exit 1; }
    echo "Created volume filesystem"
  else
    echo "Found file system device"
  fi

  if grep "$PART" </etc/fstab >/dev/null; then
    echo "Found workspace fstab entry"
  else
    echo "$PART         $TARGET   $FSTYPE   defaults  0 0" >> /etc/fstab
    echo "Created workspace fstab entry"
  fi
  mount "$TARGET" || { echo "cannot mount filesystem">&2; exit 1; }
  chown "$3":"$3" "$TARGET" || true
  echo "Mounted workspace"
fi
