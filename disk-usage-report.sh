#!/bin/bash
# disk-usage-report.sh
# Usage: sudo ./disk-usage-report.sh [directory]
# Default directory is /

TARGET_DIR="${1:-/}"

echo "\nTop 20 largest directories in $TARGET_DIR:" 
sudo du -hxd1 "$TARGET_DIR" 2>/dev/null | sort -hr | head -20

echo "\nTo drill down, run this script with a subdirectory as an argument."
echo "Example: sudo ./disk-usage-report.sh /var"

# Show usage for nvme0n1p2 only
echo "Disk usage for /dev/nvme0n1p2:"
df -h | grep nvme0n1p2

# Find the mount point for nvme0n1p2
MOUNT_POINT=$(df | grep nvme0n1p2 | awk '{print $6}' | head -1)
if [ -z "$MOUNT_POINT" ]; then
	echo "Could not find mount point for /dev/nvme0n1p2."
	exit 1
fi

echo "\nTop 20 largest directories in $MOUNT_POINT:"
sudo du -hxd1 "$MOUNT_POINT" 2>/dev/null | sort -hr | head -20

echo "\nTo drill down, run this script with a subdirectory as an argument."
echo "Example: sudo ./disk-usage-report.sh $MOUNT_POINT/var"
