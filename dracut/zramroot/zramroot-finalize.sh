#!/bin/bash
# dracut pre-pivot hook for zramroot
# This runs after root is mounted, just before switching root
# Usage: Moves the physical root mountpoint into the new root filesystem

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

# Load configuration
CONFIG_FILE="/etc/zramroot.conf"
# Default trigger
TRIGGER="zramroot"

if [ -f "${CONFIG_FILE}" ]; then
    . "${CONFIG_FILE}"
    if [ -n "${TRIGGER_PARAMETER}" ]; then
        TRIGGER="${TRIGGER_PARAMETER}"
    fi
fi

if ! getarg "${TRIGGER}" >/dev/null; then
    return 0
fi

# NEWROOT is exported by dracut (normally /sysroot)
: "${NEWROOT:=/sysroot}"

# Check if physical root is already accessible at the destination
# This happens because the zram root is a copy of the physical root,
# and the mount at /mnt/physical_root persists through pivot_root
if mountpoint -q "$NEWROOT/mnt/physical_root" 2>/dev/null; then
    # Already mounted, nothing to do
    :
elif [ -d /mnt/physical_root ] && mountpoint -q /mnt/physical_root 2>/dev/null; then
    # Physical root is mounted in initramfs but not yet in new root
    # This shouldn't normally happen with our setup, but handle it just in case
    mkdir -p "$NEWROOT/mnt/physical_root"
    if mount --move /mnt/physical_root "$NEWROOT/mnt/physical_root" 2>/dev/null; then
        info "zramroot: Physical root moved to $NEWROOT/mnt/physical_root"
    elif mount --bind /mnt/physical_root "$NEWROOT/mnt/physical_root" 2>/dev/null; then
        info "zramroot: Physical root bind-mounted to $NEWROOT/mnt/physical_root"
    fi
fi

return 0
