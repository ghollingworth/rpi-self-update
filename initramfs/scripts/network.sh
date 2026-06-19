#!/bin/sh
# network.sh — bring up networking in initramfs
#
# Tries Ethernet first. If Ethernet has no carrier (cable unplugged) and
# WIFI_SSID is set in the environment, falls back to WiFi.

# Try DHCP on a given interface and verify connectivity.
# Returns 0 on success, 1 on failure.
_dhcp_and_verify() {
    local iface="$1"

    local dhcp_hostname=""
    if [ -f /etc/hostname ]; then
        dhcp_hostname="-x hostname:$(cat /etc/hostname)"
    fi
    echo "Running DHCP on $iface..."
    udhcpc -i "$iface" -s /scripts/udhcpc.script -q -n -t 10 -T 3 $dhcp_hostname
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "DHCP failed on $iface (exit code $rc)"
        return 1
    fi

    echo ""
    echo "Network configuration:"
    ip addr show "$iface"
    echo ""
    echo "Default route:"
    ip route show
    echo ""
    echo "DNS:"
    cat /etc/resolv.conf 2>/dev/null || echo "(no resolv.conf)"
    echo ""

    # Sanity check: we must have a default route. Don't bother with a
    # connectivity probe — busybox wget --spider segfaults on some HTTP
    # responses, and flash.sh will surface any real network issue when
    # the actual download fails.
    if ip route show | grep -q '^default '; then
        echo "Default route present — network is up."
        return 0
    else
        echo "No default route after DHCP — cannot reach internet"
        return 1
    fi
}

# Try to bring up Ethernet. Returns 0 on success, 1 if no cable / no link,
# 2 if link was up but DHCP/connectivity failed (so don't also try WiFi —
# the gateway is misbehaving, not the link).
_try_ethernet() {
    echo "=== Trying Ethernet ==="

    local iface=""
    for candidate in eth0 end0; do
        if [ -d "/sys/class/net/$candidate" ]; then
            iface="$candidate"
            break
        fi
    done
    if [ -z "$iface" ]; then
        for dev in /sys/class/net/enp*; do
            if [ -d "$dev" ]; then
                iface="$(basename "$dev")"
                break
            fi
        done
    fi

    if [ -z "$iface" ]; then
        echo "No Ethernet interface found"
        return 1
    fi

    echo "Using interface: $iface"
    ip link set "$iface" up
    echo "Waiting for link..."
    sleep 3

    local carrier
    carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)
    if [ "$carrier" != "1" ]; then
        echo "No carrier on $iface (cable unplugged?)"
        return 1
    fi
    echo "Link is up on $iface"

    if _dhcp_and_verify "$iface"; then
        return 0
    fi
    return 2
}

# Dump diagnostics that help identify why WiFi failed to initialize.
_wifi_diag_dump() {
    echo "--- WiFi diagnostics ---"
    echo "Loaded modules (grep wifi/wireless):"
    grep -E '^(brcmfmac|brcmutil|cfg80211|mac80211|rfkill)' /proc/modules 2>/dev/null || echo "  (none)"
    echo ""
    echo "SDIO devices:"
    ls -la /sys/bus/sdio/devices/ 2>/dev/null || echo "  (no sdio bus)"
    for d in /sys/bus/sdio/devices/*/; do
        [ -d "$d" ] || continue
        echo "  $d"
        cat "$d/uevent" 2>/dev/null | sed 's/^/    /'
        [ -L "$d/driver" ] && echo "    (bound to $(readlink "$d/driver" | sed 's|.*/||'))"
    done
    echo ""
    echo "Network interfaces:"
    ls /sys/class/net/ 2>/dev/null
    echo ""
    echo "Firmware files (brcm):"
    ls /lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi* 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    [ -f /lib/firmware/regulatory.db ] && echo "  regulatory.db: present" || echo "  regulatory.db: MISSING"
    echo ""
    echo "Recent kernel log (WiFi-related):"
    dmesg 2>/dev/null | grep -iE 'brcmfmac|cfg80211|mac80211|wlan|cfg80211|firmware|sdio' | tail -30 | sed 's/^/  /'
    echo "--- end diagnostics ---"
}

# Try to bring up WiFi using WIFI_SSID / WIFI_PSK_HASH from env.
# Returns 0 on success, 1 on failure.
_try_wifi() {
    echo "=== Trying WiFi ==="

    if [ -z "${WIFI_SSID:-}" ]; then
        echo "No WIFI_SSID configured, skipping"
        return 1
    fi

    # Wait for a wireless interface to appear — the brcmfmac driver may
    # still be uploading firmware to the chip. Up to 20 seconds.
    echo "Waiting for wireless interface..."
    local iface=""
    local i=0
    while [ $i -lt 20 ]; do
        for candidate in wlan0 wlan1; do
            if [ -d "/sys/class/net/$candidate/wireless" ] || \
               [ -d "/sys/class/net/$candidate/phy80211" ]; then
                iface="$candidate"
                break
            fi
        done
        [ -n "$iface" ] && break
        sleep 1
        i=$((i + 1))
    done

    if [ -z "$iface" ]; then
        echo "No wireless interface found after 20 seconds"
        _wifi_diag_dump
        return 1
    fi
    echo "Wireless interface appeared after ${i}s"

    echo "Using interface: $iface (SSID: $WIFI_SSID)"

    # Clean up any state left by a previous attempt in this same boot —
    # a stale wpa_supplicant process or its control socket blocks us from
    # starting a new one.
    killall wpa_supplicant 2>/dev/null
    sleep 1
    rm -rf /var/run/wpa_supplicant 2>/dev/null
    rm -f /var/run/wpa_supplicant.pid 2>/dev/null

    ip link set "$iface" up

    # Write wpa_supplicant config. WIFI_PSK_HASH is the 64-hex hash from
    # wpa_passphrase — it goes in the psk field WITHOUT surrounding quotes
    # (quoted means plaintext). If it's missing, treat as open network.
    mkdir -p /var/run
    : > /tmp/wpa_supplicant.conf
    cat > /tmp/wpa_supplicant.conf <<WPA_CFG
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=0
update_config=0

network={
    ssid="$WIFI_SSID"
    scan_ssid=1
WPA_CFG
    if [ -n "${WIFI_PSK_HASH:-}" ]; then
        echo "    psk=$WIFI_PSK_HASH" >> /tmp/wpa_supplicant.conf
        echo "    key_mgmt=WPA-PSK" >> /tmp/wpa_supplicant.conf
    else
        echo "    key_mgmt=NONE" >> /tmp/wpa_supplicant.conf
    fi
    echo "}" >> /tmp/wpa_supplicant.conf

    echo "Starting wpa_supplicant..."
    /usr/sbin/wpa_supplicant -B -i "$iface" -c /tmp/wpa_supplicant.conf -D nl80211 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: wpa_supplicant failed to start"
        return 1
    fi

    # Wait for association — up to 30 seconds
    echo "Waiting for association..."
    local i=0
    while [ $i -lt 30 ]; do
        if iw dev "$iface" link 2>/dev/null | grep -q '^Connected to'; then
            echo "Associated:"
            iw dev "$iface" link | head -3
            break
        fi
        sleep 1
        i=$((i + 1))
    done
    if [ $i -ge 30 ]; then
        echo "ERROR: WiFi association timed out"
        return 1
    fi

    _dhcp_and_verify "$iface"
}

setup_network() {
    _try_ethernet
    local eth_rc=$?
    if [ $eth_rc -eq 0 ]; then
        return 0
    fi
    # eth_rc=2 means Ethernet link was up but connectivity failed —
    # WiFi on the same LAN will probably hit the same problem, but try anyway.
    _try_wifi
    return $?
}
