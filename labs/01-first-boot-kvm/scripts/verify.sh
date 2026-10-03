#!/usr/bin/env bash
# Lab 01 verification: assert the properties the lab teaches, over ssh.
# shellcheck shell=bash
# Commands are single-quoted on purpose: they must be expanded by the shell on the VM, not here.
# shellcheck disable=SC2016
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"

name=lab01
fail=0

# check DESCRIPTION COMMAND...: run COMMAND in the VM; pass when it exits 0.
check() {
    local desc=$1
    shift
    if vm_ssh "$name" "$@" >/dev/null 2>&1; then
        log "PASS  $desc"
    else
        log "FAIL  $desc"
        fail=1
    fi
}

vm_is_running "$name" || die "VM $name is not running (make lab01-up)"

check "OS is Flatcar $FLATCAR_VERSION" \
    ". /etc/os-release && [ \"\$ID\" = flatcar ] && [ \"\$VERSION_ID\" = $FLATCAR_VERSION ]"
check "hostname was set by Ignition" '[ "$(hostname)" = lab01 ]'
check "Ignition wrote /etc/lab/provisioned-by-ignition" 'grep -q "written by Ignition" /etc/lab/provisioned-by-ignition'
check "/usr is mounted read-only" 'findmnt -no OPTIONS /usr | tr , "\n" | grep -qx ro'
check "writing to /usr fails with a read-only filesystem error" \
    '! sudo touch /usr/lab-write-test 2>/tmp/err && grep -qi "read-only" /tmp/err'
check "/usr sits on a dm-verity device" 'sudo dmsetup table usr | grep -q verity'
check "partition layout has USR-A, USR-B, OEM and ROOT" \
    'lsblk -no PARTLABEL | sort | tr "\n" " " | grep -q "OEM.*ROOT.*USR-A.*USR-B"'
check "a USR slot is marked successful (GPT attribute)" \
    'sudo cgpt show "$(rootdev -d)" | grep -A3 "USR-" | grep -q "successful=1"'
check "ROOT is writable ext4 and resized past its image size" \
    '[ "$(findmnt -no FSTYPE /)" = ext4 ] && [ "$(findmnt -bno SIZE / 2>/dev/null || df -B1 --output=size / | tail -1)" -gt 8000000000 ]'
check "first-boot flag was removed after Ignition" '! ls /boot/flatcar/first_boot'
check "lab-hello.service ran and recorded the version" \
    "grep -q 'version=$FLATCAR_VERSION' /var/lib/lab/hello"
check "locksmithd is masked" '[ "$(systemctl is-enabled locksmithd.service 2>&1)" = masked ]'
check "updates are frozen (SERVER=disabled)" 'grep -qx SERVER=disabled /etc/flatcar/update.conf'
check "no package manager on the host" '! command -v apt && ! command -v dnf && ! command -v yum && ! command -v rpm-ostree'

if [ "$fail" -eq 0 ]; then
    log "lab 01: all checks passed"
else
    log "lab 01: some checks FAILED"
fi
exit "$fail"
