#!/usr/bin/env bash
# Host bridge for the multi-VM labs (04 and 05). Run as root:
#   sudo labs/lib/net.sh up | down | status | dhcp-start HOSTS_FILE | dhcp-stop
#
# Creates $LAB_BRIDGE with the gateway address, enables forwarding and masquerades the
# lab subnet to the outside so the VMs can pull artifacts. Uses nftables when present,
# otherwise iptables. It does not touch any other firewall rules; if your host has a
# default-DROP FORWARD policy (Docker does this), also allow the bridge, for example:
#   iptables -I FORWARD -i flcbr0 -j ACCEPT; iptables -I FORWARD -o flcbr0 -j ACCEPT
# shellcheck shell=bash
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NFT_TABLE=flatcar_lab_nat

require_root() {
    [ "$(id -u)" -eq 0 ] || die "run as root: sudo $0 $*"
}

bridge_exists() {
    ip link show "$LAB_BRIDGE" >/dev/null 2>&1
}

net_up() {
    require_root up
    need ip
    if bridge_exists; then
        log "bridge $LAB_BRIDGE already exists"
    else
        ip link add "$LAB_BRIDGE" type bridge
        ip addr add "${LAB_GATEWAY}/24" dev "$LAB_BRIDGE"
        ip link set "$LAB_BRIDGE" up
        log "created $LAB_BRIDGE ${LAB_GATEWAY}/24"
    fi
    sysctl -q -w net.ipv4.ip_forward=1
    if command -v nft >/dev/null 2>&1; then
        nft list table ip "$NFT_TABLE" >/dev/null 2>&1 || {
            nft add table ip "$NFT_TABLE"
            nft add chain ip "$NFT_TABLE" postrouting '{ type nat hook postrouting priority 100 ; }'
            nft add rule ip "$NFT_TABLE" postrouting ip saddr "$LAB_SUBNET" oifname != "$LAB_BRIDGE" masquerade
        }
    elif command -v iptables >/dev/null 2>&1; then
        iptables -t nat -C POSTROUTING -s "$LAB_SUBNET" ! -o "$LAB_BRIDGE" -j MASQUERADE 2>/dev/null ||
            iptables -t nat -A POSTROUTING -s "$LAB_SUBNET" ! -o "$LAB_BRIDGE" -j MASQUERADE
    else
        die "neither nft nor iptables found; cannot set up NAT"
    fi
    if [ -r /etc/qemu/bridge.conf ] && grep -qE "^allow +${LAB_BRIDGE}\$|^allow all\$" /etc/qemu/bridge.conf; then
        log "qemu-bridge-helper already allows $LAB_BRIDGE"
    else
        log "NOTE: allow the bridge for unprivileged QEMU: echo 'allow $LAB_BRIDGE' | sudo tee -a /etc/qemu/bridge.conf"
    fi
}

# dhcp_start HOSTS_FILE: serve fixed DHCP leases on the bridge, one "MAC,IP,name" line per VM
# in HOSTS_FILE. Flatcar's initrd configures NICs with DHCP before Ignition runs, so Ignition can
# download remote artifacts only if something answers DHCP on the lab network.
DHCP_PIDFILE=/run/flatcar-lab-dnsmasq.pid
dhcp_start() {
    require_root dhcp-start
    need dnsmasq
    local hosts=${1:?usage: net.sh dhcp-start HOSTS_FILE}
    [ -f "$hosts" ] || die "no such hosts file: $hosts"
    bridge_exists || die "bridge $LAB_BRIDGE does not exist; run 'net.sh up' first"
    dhcp_stop
    dnsmasq --conf-file=/dev/null --pid-file="$DHCP_PIDFILE" \
        --interface="$LAB_BRIDGE" --bind-interfaces --except-interface=lo --port=0 \
        --dhcp-range="${LAB_GATEWAY%.*}.0,static,255.255.255.0" \
        --dhcp-hostsfile="$hosts" --dhcp-leasefile=/run/flatcar-lab-dnsmasq.leases \
        --dhcp-option=option:router,"$LAB_GATEWAY" --dhcp-option=option:dns-server,"$LAB_DNS"
    log "DHCP on $LAB_BRIDGE serving $(grep -c . "$hosts") fixed lease(s) from $hosts"
}

dhcp_stop() {
    if [ -s "$DHCP_PIDFILE" ]; then
        kill "$(cat "$DHCP_PIDFILE")" 2>/dev/null || true
        rm -f "$DHCP_PIDFILE"
    fi
}

net_down() {
    require_root down
    dhcp_stop
    if command -v nft >/dev/null 2>&1; then
        nft delete table ip "$NFT_TABLE" 2>/dev/null || true
    elif command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D POSTROUTING -s "$LAB_SUBNET" ! -o "$LAB_BRIDGE" -j MASQUERADE 2>/dev/null || true
    fi
    if bridge_exists; then
        ip link set "$LAB_BRIDGE" down
        ip link del "$LAB_BRIDGE"
        log "removed $LAB_BRIDGE"
    fi
}

net_status() {
    if bridge_exists; then
        ip -br addr show "$LAB_BRIDGE"
    else
        echo "bridge $LAB_BRIDGE: absent"
        return 1
    fi
}

main() {
    case ${1:-} in
    up) net_up ;;
    down) net_down ;;
    status) net_status ;;
    dhcp-start) shift; dhcp_start "$@" ;;
    dhcp-stop) require_root dhcp-stop; dhcp_stop ;;
    *) die "usage: $0 up|down|status|dhcp-start HOSTS_FILE|dhcp-stop" ;;
    esac
}

# Run only when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
