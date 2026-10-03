#!/usr/bin/env bash
# Lab 02 verification for a given phase. Usage: verify.sh baseline|updated|rolled-back
# shellcheck disable=SC2016
# shellcheck shell=bash
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"

NAME=lab02
phase=${1:-baseline}
fail=0

check() {
    local desc=$1
    shift
    if vm_ssh "$NAME" "$@" >/dev/null 2>&1; then
        log "PASS  $desc"
    else
        log "FAIL  $desc"
        fail=1
    fi
}

vm_is_running "$NAME" || die "VM is not running (make lab02-up)"

version_is() { check "running Flatcar $1" ". /etc/os-release && [ \"\$VERSION_ID\" = $1 ]"; }

case $phase in
baseline)
    version_is "$FLATCAR_OLD_VERSION"
    check "locksmithd is masked (you control reboots)" '[ "$(systemctl is-enabled locksmithd.service 2>&1)" = masked ]'
    check "critical service is running" 'systemctl is-active --quiet lab-critical.service'
    check "healthy flag is present" 'test -e /run/first-boot-healthy'
    check "update-engine is running (started by the path unit)" 'systemctl is-active --quiet update-engine.service'
    check "update-engine will not start without the flag" 'systemctl cat update-engine.service | grep -q "ConditionPathExists=/run/first-boot-healthy"'
    ;;
updated)
    version_is "$FLATCAR_VERSION"
    check "the other USR slot is now the running one" \
        'p=$(rootdev -s /usr); [ -n "$p" ] && [ "$p" != "$(cat /var/lib/lab/first-usr 2>/dev/null)" ]'
    check "running slot is marked successful" \
        'sudo cgpt show "$(rootdev -d)" | grep -A3 "$(rootdev -s /usr | grep -o "[0-9]*$") *Label" | grep -q "successful=1"'
    ;;
rolled-back)
    version_is "$FLATCAR_OLD_VERSION"
    check "updates are frozen so the node stays put" 'grep -qx SERVER=disabled /etc/flatcar/update.conf'
    ;;
*)
    die "unknown phase: $phase (baseline|updated|rolled-back)"
    ;;
esac

if [ "$fail" -eq 0 ]; then
    log "lab 02 ($phase): all checks passed"
else
    log "lab 02 ($phase): checks FAILED"
fi
exit "$fail"
