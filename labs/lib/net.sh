#!/usr/bin/env bash
# Host bridge for the multi-VM labs (04 and 05). Run as root:
#   sudo labs/lib/net.sh up | down | status
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

net_down() {
    require_root down
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
    *) die "usage: $0 up|down|status" ;;
    esac
}

# Run only when executed, not when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
