#!/bin/sh
# preserve-home.sh — backup and restore /home across a self-update flash
#
# Backs up /home to a compressed tar in tmpfs (RAM). On restore, expands the
# new rootfs partition to fill the disk and extracts the tar.
#
# Returns:
#   0 — success (or nothing to do)
#   1 — non-fatal failure (skip preservation, flash can continue)
#   2 — fatal failure (abort flash, restore boot config)
#
# State is communicated via /tmp/preserve-home.state (key=value, lives in tmpfs).

PRESERVE_STATE="/tmp/preserve-home.state"

# Derive rootfs partition name from a whole-disk device
_ph_rootfs_part() {
    local dev="$1"
    case "$dev" in
        /dev/mmcblk*|/dev/nvme*) echo "${dev}p2" ;;
        /dev/sd*)                echo "${dev}2" ;;
        *)                       echo "${dev}2" ;;
    esac
}

# ============================================================
# preserve_home_backup TARGET_DEVICE
#   Called AFTER boot is unmounted, BEFORE flash.
# ============================================================
preserve_home_backup() {
    local TARGET_DEVICE="$1"
    local ROOTFS
    ROOTFS=$(_ph_rootfs_part "$TARGET_DEVICE")

    echo ""
    echo "=== Preserve Home: Backup ==="
    echo "Target device: $TARGET_DEVICE"
    echo "Rootfs partition: $ROOTFS"

    # Mount rootfs read-only
    mkdir -p /mnt/rootfs
    if ! mount -o ro "$ROOTFS" /mnt/rootfs 2>&1; then
        echo "ERROR: Could not mount $ROOTFS"
        return 2
    fi

    # Check if /home has content
    if [ ! -d /mnt/rootfs/home ] || [ -z "$(ls /mnt/rootfs/home/ 2>/dev/null)" ]; then
        echo "No home directory content found — nothing to preserve"
        umount /mnt/rootfs
        echo "PRESERVE_METHOD=none" > "$PRESERVE_STATE"
        return 0
    fi

    # Measure home size and available tmpfs space
    local HOME_SIZE_KB
    HOME_SIZE_KB=$(du -sk /mnt/rootfs/home/ | cut -f1)
    local TMPFS_AVAIL_KB
    TMPFS_AVAIL_KB=$(df -k /tmp | tail -1 | awk '{print $4}')

    echo "Home size: ${HOME_SIZE_KB} KB (uncompressed)"
    echo "Tmpfs available: ${TMPFS_AVAIL_KB} KB"

    # Check if home is likely to fit. We need headroom for the tar overhead,
    # the flash log, cloud-init files, and other tmpfs users. Require that
    # uncompressed home is less than 90% of tmpfs — compression will help
    # but incompressible data (media files) may not compress much.
    local TMPFS_LIMIT_KB=$(( TMPFS_AVAIL_KB * 9 / 10 ))
    if [ "$HOME_SIZE_KB" -gt "$TMPFS_LIMIT_KB" ]; then
        echo ""
        echo "ERROR: Home directory (${HOME_SIZE_KB} KB) is too large for available"
        echo "tmpfs space (${TMPFS_AVAIL_KB} KB). Cannot safely preserve home."
        echo ""
        echo "Aborting self-update. Clean up your home directory and try again."
        umount /mnt/rootfs
        return 2
    fi

    echo "Compressing home to tmpfs..."
    if ! tar czf /tmp/home-backup.tar.gz -C /mnt/rootfs ./home; then
        echo ""
        echo "ERROR: tar backup failed (tmpfs likely full)"
        echo "Aborting self-update."
        rm -f /tmp/home-backup.tar.gz
        umount /mnt/rootfs 2>/dev/null
        return 2
    fi

    local TAR_SIZE_KB
    TAR_SIZE_KB=$(du -sk /tmp/home-backup.tar.gz | cut -f1)
    local TMPFS_REMAINING_KB
    TMPFS_REMAINING_KB=$(df -k /tmp | tail -1 | awk '{print $4}')
    echo "Tar archive: ${TAR_SIZE_KB} KB (tmpfs remaining: ${TMPFS_REMAINING_KB} KB)"

    umount /mnt/rootfs
    echo "PRESERVE_METHOD=tar" > "$PRESERVE_STATE"
    echo "Home backup complete"
    return 0
}

# ============================================================
# preserve_home_restore TARGET_DEVICE
#   Called AFTER flash, BEFORE mounting new boot partition.
# ============================================================
preserve_home_restore() {
    local TARGET_DEVICE="$1"

    # Read state
    if [ ! -f "$PRESERVE_STATE" ]; then
        return 0
    fi
    . "$PRESERVE_STATE"

    if [ "${PRESERVE_METHOD:-none}" = "none" ]; then
        return 0
    fi

    echo ""
    echo "=== Preserve Home: Restore ==="

    local ROOTFS
    ROOTFS=$(_ph_rootfs_part "$TARGET_DEVICE")

    # Pick up new partition table
    mdev -s
    sleep 1

    # Expand p2 to fill disk
    echo "Expanding rootfs partition to fill disk..."
    echo ", +" | sfdisk -N 2 "$TARGET_DEVICE" --no-reread 2>&1 || true
    mdev -s
    sleep 1

    # Filesystem check and expand
    echo "Running e2fsck..."
    /usr/sbin/e2fsck -fy "$ROOTFS" || true

    echo "Expanding rootfs filesystem..."
    /usr/sbin/resize2fs "$ROOTFS" || true

    # Mount and extract
    mkdir -p /mnt/newroot
    if ! mount "$ROOTFS" /mnt/newroot; then
        echo "WARNING: Could not mount new rootfs for home restore"
        return 1
    fi

    echo "Extracting home backup..."
    if ! tar xzf /tmp/home-backup.tar.gz -C /mnt/newroot/; then
        echo "WARNING: tar extract failed"
        umount /mnt/newroot
        return 1
    fi

    sync
    umount /mnt/newroot
    echo "Home restore complete"
    return 0
}
