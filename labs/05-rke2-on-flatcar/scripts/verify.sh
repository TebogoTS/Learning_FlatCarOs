#!/usr/bin/env bash
# Lab 05 assertions, by phase.
#   verify.sh cluster        3 nodes Ready at the start versions, RKE2 under /opt/rke2, Flatcar's own containerd absent
#   verify.sh rke2-upgraded  all nodes at RKE2_VERSION_UPGRADE, plans complete
#   verify.sh os-updated     every node booted a newer Flatcar than the starting one
# Commands in single quotes are meant to be expanded by the VM's shell.
# shellcheck disable=SC2016,SC2317  # SC2317: helpers are called indirectly through check/wait_for
# shellcheck shell=bash
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"

SERVER=rke2-server
NODES=(rke2-server rke2-agent-0 rke2-agent-1)
fail=0
ok() { log "PASS $*"; }
bad() { log "FAIL $*"; fail=1; }
check() {
    local d=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
kc() { vm_ssh "$SERVER" sudo /opt/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml "$@"; }
wait_for() { # seconds description command...
    local t=$1 d=$2 i
    shift 2
    for ((i = 0; i < t; i += 5)); do
        if "$@" >/dev/null 2>&1; then ok "$d"; return; fi
        sleep 5
    done
    bad "$d (timed out after ${t}s)"
}
ready_count() { [ "$(kc get nodes --no-headers 2>/dev/null | grep -c ' Ready')" = 3 ]; }
node_versions_all() { # VERSION: every node reports it as kubeletVersion
    [ "$(kc get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null | grep -cxF "$1")" = 3 ]
}

none_cordoned() {
    [ -z "$(kc get nodes -o jsonpath='{.items[?(@.spec.unschedulable==true)].metadata.name}' 2>/dev/null)" ]
}

phase_cluster() {
    # shellcheck source=../../../versions.env
    . "$LAB_DIR/../../versions.env"
    wait_for 900 "three nodes Ready" ready_count
    for n in "${NODES[@]}"; do
        check "$n: RKE2 binary lives under /opt/rke2" vm_ssh "$n" 'test -x /opt/rke2/bin/rke2'
        check "$n: rke2 unit is in /etc/systemd/system (moved by the installer)" vm_ssh "$n" 'ls /etc/systemd/system/rke2-*.service'
        check "$n: Flatcar docker/containerd extensions are masked" vm_ssh "$n" '[ "$(readlink /etc/extensions/containerd-flatcar.raw)" = /dev/null ] && [ "$(readlink /etc/extensions/docker-flatcar.raw)" = /dev/null ]'
        check "$n: no host containerd running (RKE2 has its own)" vm_ssh "$n" '! systemctl is-active --quiet containerd'
    done
    wait_for 60 "all nodes at $RKE2_VERSION_START" node_versions_all "$RKE2_VERSION_START"
    check "server: control-plane label present" kc get nodes -l node-role.kubernetes.io/control-plane=true --no-headers
}

phase_rke2_upgraded() {
    # shellcheck source=../../../versions.env
    . "$LAB_DIR/../../versions.env"
    wait_for 1800 "all nodes at $RKE2_VERSION_UPGRADE" node_versions_all "$RKE2_VERSION_UPGRADE"
    wait_for 120 "three nodes Ready after the upgrade" ready_count
    for n in "${NODES[@]}"; do
        check "$n: binary on disk reports $RKE2_VERSION_UPGRADE" vm_ssh "$n" "/opt/rke2/bin/rke2 --version | grep -q '${RKE2_VERSION_UPGRADE}'"
    done
}

phase_os_updated() {
    # shellcheck source=../../../versions.env
    . "$LAB_DIR/../../versions.env"
    local n v
    for n in "${NODES[@]}"; do
        v=$(vm_ssh "$n" '. /etc/os-release; echo $VERSION_ID' 2>/dev/null | tr -d '\r')
        if [ -n "$v" ] && [ "$v" != "$FLATCAR_OLD_VERSION" ]; then ok "$n runs Flatcar $v (started at $FLATCAR_OLD_VERSION)"; else bad "$n still on ${v:-unknown}"; fi
        check "$n: RKE2 came back after the reboot" vm_ssh "$n" 'systemctl is-active --quiet rke2-server || systemctl is-active --quiet rke2-agent'
    done
    wait_for 300 "three nodes Ready after the OS updates" ready_count
    check "no node left cordoned" none_cordoned
}

case ${1:-} in
cluster) phase_cluster ;;
rke2-upgraded) phase_rke2_upgraded ;;
os-updated) phase_os_updated ;;
*) die "usage: $0 cluster|rke2-upgraded|os-updated" ;;
esac
exit $fail
