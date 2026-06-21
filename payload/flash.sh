#!/bin/sh
# flash.sh — download image and write to target device

flash_image() {
    # Downgrade HTTPS to HTTP — busybox static TLS can't handshake with most servers.
    # Integrity is verified via SHA256 after writing.
    IMAGE_URL=$(echo "$IMAGE_URL" | sed 's|^https://|http://|')

    echo "=== Flashing image ==="
    echo "Image: $IMAGE_NAME"
    echo "URL:   $IMAGE_URL"
    echo "Target: $TARGET_DEVICE"
    echo ""

    # Check target device exists
    if [ ! -b "$TARGET_DEVICE" ]; then
        echo "ERROR: Target device $TARGET_DEVICE not found"
        return 1
    fi

    # Determine if image needs decompression
    local needs_xz=0
    case "$IMAGE_URL" in
        *.xz) needs_xz=1 ;;
    esac

    # Download, decompress, and write in a single pipeline
    echo "Downloading and writing image..."
    echo "This may take several minutes depending on image size and network speed."
    echo ""

    local start_time
    start_time=$(date +%s)

    # Run the pipeline with stderr going directly to console, not through the logpipe.
    # This avoids SIGPIPE issues if the tee logging process dies during the long download.
    if [ "$needs_xz" = "1" ]; then
        echo "Pipeline: wget | xzcat | dd -> $TARGET_DEVICE"
        wget -q -O- "$IMAGE_URL" 2>/dev/console | xzcat 2>/dev/console | dd of="$TARGET_DEVICE" bs=4M conv=fsync status=none 2>/dev/console
    else
        echo "Pipeline: wget | dd -> $TARGET_DEVICE"
        wget -q -O- "$IMAGE_URL" 2>/dev/console | dd of="$TARGET_DEVICE" bs=4M conv=fsync status=none 2>/dev/console
    fi

    local rc=$?
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))

    if [ $rc -ne 0 ]; then
        echo "ERROR: Download/write pipeline failed (exit code $rc)"
        return 1
    fi

    sync
    echo "Write complete (${elapsed}s)"
    echo ""

    # Verify if we have expected hash and size
    if [ -n "${IMAGE_SHA256:-}" ] && [ -n "${IMAGE_SIZE:-}" ] && [ "$IMAGE_SIZE" -gt 0 ] 2>/dev/null; then
        echo "Verifying written data..."
        echo "Reading back $IMAGE_SIZE bytes from $TARGET_DEVICE..."

        local blocks=$((IMAGE_SIZE / 4194304))
        local remainder=$((IMAGE_SIZE % 4194304))

        local actual_hash
        if [ "$remainder" -gt 0 ]; then
            # Read full blocks + remainder
            actual_hash=$(
                {
                    dd if="$TARGET_DEVICE" bs=4M count="$blocks" status=none
                    dd if="$TARGET_DEVICE" bs=1 skip=$((blocks * 4194304)) count="$remainder" status=none
                } | sha256sum | cut -d' ' -f1
            )
        else
            actual_hash=$(dd if="$TARGET_DEVICE" bs=4M count="$blocks" status=none | sha256sum | cut -d' ' -f1)
        fi

        if [ "$actual_hash" = "$IMAGE_SHA256" ]; then
            echo "VERIFIED: SHA256 matches"
            echo "  Expected: $IMAGE_SHA256"
            echo "  Actual:   $actual_hash"
        else
            echo "WARNING: SHA256 mismatch!"
            echo "  Expected: $IMAGE_SHA256"
            echo "  Actual:   $actual_hash"
            echo "The image may not have been written correctly."
            return 1
        fi
    else
        echo "No SHA256/size info available, skipping verification"
    fi

    echo ""
    echo "Flash complete: $IMAGE_NAME -> $TARGET_DEVICE"

    # Install cloud-init files on the target if available
    # (For self-update, init handles this after re-mounting the new boot partition)
    if [ "${SELF_UPDATE:-0}" != "1" ]; then
        install_cloudinit
    fi

    return 0
}

install_cloudinit() {
    CLOUDINIT_SRC="${PAYLOAD_DIR:-/payload}/selfupdate-cloudinit"
    if [ ! -d "$CLOUDINIT_SRC" ] || [ ! -f "$CLOUDINIT_SRC/user-data" ]; then
        echo "No cloud-init configuration found, skipping"
        return 0
    fi

    echo ""
    echo "=== Installing cloud-init configuration ==="

    # Re-read partition table after writing the image
    sync
    sleep 2
    mdev -s

    # Find the boot partition on the target (first FAT partition)
    TARGET_BOOT=""
    # Try common partition naming
    case "$TARGET_DEVICE" in
        /dev/sd*)
            TARGET_BOOT="${TARGET_DEVICE}1" ;;
        /dev/mmcblk*|/dev/nvme*)
            TARGET_BOOT="${TARGET_DEVICE}p1" ;;
    esac

    if [ -z "$TARGET_BOOT" ] || [ ! -b "$TARGET_BOOT" ]; then
        echo "WARNING: Could not find boot partition on target ($TARGET_BOOT)"
        echo "Cloud-init files not installed"
        return 0
    fi

    # Mount the target's boot partition
    mkdir -p /tmp/target_boot
    if ! mount -t vfat "$TARGET_BOOT" /tmp/target_boot 2>&1; then
        echo "WARNING: Could not mount $TARGET_BOOT"
        echo "Cloud-init files not installed"
        return 0
    fi

    echo "Mounted target boot partition: $TARGET_BOOT"

    # Copy cloud-init files
    cp "$CLOUDINIT_SRC/meta-data" /tmp/target_boot/meta-data
    cp "$CLOUDINIT_SRC/user-data" /tmp/target_boot/user-data
    cp "$CLOUDINIT_SRC/network-config" /tmp/target_boot/network-config
    echo "  Copied: meta-data, user-data, network-config"

    # Append NoCloud datasource to cmdline.txt if it exists
    if [ -f /tmp/target_boot/cmdline.txt ] && [ -f "$CLOUDINIT_SRC/cmdline-append" ]; then
        APPEND=$(cat "$CLOUDINIT_SRC/cmdline-append")
        # Only append if not already present
        if ! grep -q "ds=nocloud" /tmp/target_boot/cmdline.txt; then
            sed -i "s/$/ $APPEND/" /tmp/target_boot/cmdline.txt
            echo "  Modified: cmdline.txt (added ds=nocloud)"
        fi
    fi

    sync
    umount /tmp/target_boot
    echo "Cloud-init configuration installed on target"
}
