#!/usr/bin/env bash
# Offline self-test for the lab helper scripts: no VM, network or KVM needed.
# Verifies overlay creation and that the QEMU command line carries the arguments the
# design depends on (Ignition via fw_cfg, overlay disk, MAC, network mode, port forwards).
# shellcheck shell=bash
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/qemu.sh"

LAB_DIR=$(mktemp -d)
export LAB_DIR
trap 'rm -rf "$LAB_DIR"' EXIT

fail=0
expect_contains() {
    local what=$1 haystack=$2 needle=$3
    if [[ $haystack != *"$needle"* ]]; then
        log "FAIL: $what: missing '$needle'"
        fail=1
    else
        log "ok:   $what"
    fi
}

need qemu-img
base=$LAB_DIR/base.qcow2
qemu-img create -q -f qcow2 "$base" 64M
ign=$LAB_DIR/test.ign
echo '{"ignition":{"version":"3.4.0"}}' >"$ign"

vm_create t1 "$base" 1G
backing=$(qemu-img info --output=json "$(vm_dir t1)/disk.qcow2" | grep -o '"backing-filename": "[^"]*"' || true)
expect_contains "overlay has the base as backing file" "$backing" "base.qcow2"

user_cmd=$(VM_DRY_RUN=1 vm_start t1 "$ign" 2048 2 user 52:54:00:77:00:01 2222 8080:80 2>/dev/null)
expect_contains "user mode: fw_cfg Ignition" "$user_cmd" "name=opt/org.flatcar-linux/config,file=$ign"
expect_contains "user mode: ssh port forward" "$user_cmd" "hostfwd=tcp:127.0.0.1:2222-:22"
expect_contains "user mode: extra port forward" "$user_cmd" "hostfwd=tcp:127.0.0.1:8080-:80"
expect_contains "user mode: overlay disk" "$user_cmd" "disk.qcow2,format=qcow2"
expect_contains "user mode: MAC" "$user_cmd" "mac=52:54:00:77:00:01"
expect_contains "user mode: memory" "$user_cmd" "-m 2048"
expect_contains "user mode: recorded ssh address" "$(cat "$(vm_dir t1)/addr")" "127.0.0.1 2222"

bridge_cmd=$(VM_DRY_RUN=1 vm_start t1 "$ign" 4096 4 bridge 52:54:00:77:00:10 10.77.0.10 2>/dev/null)
expect_contains "bridge mode: bridge netdev" "$bridge_cmd" "bridge,id=net0,br=${LAB_BRIDGE}"
expect_contains "bridge mode: recorded address" "$(cat "$(vm_dir t1)/addr")" "10.77.0.10 22"

if (VM_DRY_RUN=1 vm_start t1 "$ign" 1024 1 bogus 52:54:00:77:00:02 1 >/dev/null 2>&1); then
    log "FAIL: unknown network mode was accepted"
    fail=1
else
    log "ok:   unknown network mode rejected"
fi

# vm_create must not clobber an existing overlay.
echo marker >"$(vm_dir t1)/marker"
vm_create t1 "$base" 1G 2>/dev/null
[ -e "$(vm_dir t1)/marker" ] || { log "FAIL: vm_create destroyed state"; fail=1; }

exit "$fail"
