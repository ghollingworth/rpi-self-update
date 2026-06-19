#!/bin/sh
# preserve-ssh.sh — backup and restore /etc/ssh host keys across a self-update flash.
#
# Mirrors the preserve-home pattern: backs up the host key files from the old
# rootfs (read-only mount) to tmpfs, then restores them onto the new rootfs
# after the flash completes. Host keys are small (<10 KB total), so we just
# tar them straight to RAM without size checks.
#
# Why only host keys (not authorized_keys, not sshd_config)?
#   - authorized_keys live under /home and are handled by cloud-init's
#     ssh_authorized_keys on first boot (or by --preserve-home).
#   - sshd_config: keep whatever the new image ships with. Restoring an old
#     config could undo upstream security defaults.
#
# Returns:
#   0 — success or nothing to do
#   1 — non-fatal failure (continue without preservation)
#   2 — fatal failure (abort flash)
#
# State lives in /tmp/preserve-ssh.state.

PRESERVE_SSH_STATE="/tmp/preserve-ssh.state"

_ph_ssh_rootfs_part() {
    local dev="$1"
    case "$dev" in
        /dev/mmcblk*|/dev/nvme*) echo "${dev}p2" ;;
        /dev/sd*)                echo "${dev}2" ;;
        *)                       echo "${dev}2" ;;
    esac
}

# ============================================================
# preserve_ssh_backup TARGET_DEVICE
#   Called AFTER boot is unmounted, BEFORE flash. The OLD rootfs lives on
#   ${TARGET_DEVICE}p2 (or analogous) and is read-mountable until flash.
# ============================================================
preserve_ssh_backup() {
    local TARGET_DEVICE="$1"
    local ROOTFS
    ROOTFS=$(_ph_ssh_rootfs_part "$TARGET_DEVICE")

    echo ""
    echo "=== Preserve SSH: Backup ==="
    echo "Target device: $TARGET_DEVICE"
    echo "Rootfs partition: $ROOTFS"

    mkdir -p /mnt/rootfs-ssh
    if ! mount -o ro "$ROOTFS" /mnt/rootfs-ssh 2>&1; then
        echo "WARNING: Could not mount $ROOTFS for SSH backup"
        echo "PRESERVE_SSH_METHOD=none" > "$PRESERVE_SSH_STATE"
        return 1
    fi

    if [ ! -d /mnt/rootfs-ssh/etc/ssh ]; then
        echo "No /etc/ssh directory on old rootfs — nothing to preserve"
        umount /mnt/rootfs-ssh
        rmdir /mnt/rootfs-ssh 2>/dev/null
        echo "PRESERVE_SSH_METHOD=none" > "$PRESERVE_SSH_STATE"
        return 0
    fi

    # Only host keys. Build the file list from what's actually present —
    # busybox tar (used in the initramfs) doesn't support GNU's
    # --ignore-failed-read, so we filter before invoking it instead.
    rm -f /tmp/ssh-backup.tar.gz
    local FILES=""
    for k in ssh_host_rsa_key     ssh_host_rsa_key.pub \
             ssh_host_ecdsa_key   ssh_host_ecdsa_key.pub \
             ssh_host_ed25519_key ssh_host_ed25519_key.pub; do
        if [ -f "/mnt/rootfs-ssh/etc/ssh/$k" ]; then
            FILES="$FILES ssh/$k"
        fi
    done
    if [ -z "$FILES" ]; then
        echo "No host key files found in /etc/ssh — nothing to preserve"
        umount /mnt/rootfs-ssh
        rmdir /mnt/rootfs-ssh 2>/dev/null
        echo "PRESERVE_SSH_METHOD=none" > "$PRESERVE_SSH_STATE"
        return 0
    fi
    if ! tar czf /tmp/ssh-backup.tar.gz -C /mnt/rootfs-ssh/etc $FILES 2>&1; then
        echo "WARNING: tar of SSH host keys failed"
        umount /mnt/rootfs-ssh
        rmdir /mnt/rootfs-ssh 2>/dev/null
        echo "PRESERVE_SSH_METHOD=none" > "$PRESERVE_SSH_STATE"
        return 1
    fi

    local SIZE_KB
    SIZE_KB=$(du -sk /tmp/ssh-backup.tar.gz | cut -f1)
    echo "SSH host-key backup: ${SIZE_KB} KB"

    umount /mnt/rootfs-ssh
    rmdir /mnt/rootfs-ssh 2>/dev/null
    echo "PRESERVE_SSH_METHOD=tar" > "$PRESERVE_SSH_STATE"
    echo "SSH backup complete"
    return 0
}

# ============================================================
# preserve_ssh_restore TARGET_DEVICE
#   Called AFTER flash. The NEW rootfs is on the same partition path.
#   If preserve_home_restore ran first, the rootfs partition has already
#   been resized and the filesystem checked; we just mount and extract.
# ============================================================
preserve_ssh_restore() {
    local TARGET_DEVICE="$1"

    [ -f "$PRESERVE_SSH_STATE" ] || return 0
    . "$PRESERVE_SSH_STATE"
    [ "${PRESERVE_SSH_METHOD:-none}" = "none" ] && return 0
    [ -f /tmp/ssh-backup.tar.gz ] || return 0

    echo ""
    echo "=== Preserve SSH: Restore ==="

    local ROOTFS
    ROOTFS=$(_ph_ssh_rootfs_part "$TARGET_DEVICE")

    # Refresh device nodes in case preserve_home didn't run.
    mdev -s
    sleep 1

    # Best-effort fsck — preserve_home may have already done this.
    /usr/sbin/e2fsck -fy "$ROOTFS" >/dev/null 2>&1 || true

    mkdir -p /mnt/newroot-ssh
    if ! mount "$ROOTFS" /mnt/newroot-ssh 2>&1; then
        echo "WARNING: Could not mount new rootfs for SSH restore"
        return 1
    fi

    # /etc/ssh always exists in a fresh Pi OS image; the tar overlays files in it.
    if ! tar xzf /tmp/ssh-backup.tar.gz -C /mnt/newroot-ssh/etc/ 2>&1; then
        echo "WARNING: SSH tar extract failed"
        umount /mnt/newroot-ssh
        rmdir /mnt/newroot-ssh 2>/dev/null
        return 1
    fi

    # Tighten permissions defensively (matches Debian defaults).
    chmod 600 /mnt/newroot-ssh/etc/ssh/ssh_host_*_key 2>/dev/null || true
    chmod 644 /mnt/newroot-ssh/etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

    sync
    umount /mnt/newroot-ssh
    rmdir /mnt/newroot-ssh 2>/dev/null
    echo "SSH restore complete (host keys preserved)"
    return 0
}
