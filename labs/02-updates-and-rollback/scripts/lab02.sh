#!/usr/bin/env bash
# Lab 02 driver. One subcommand per phase of the lab; see the README for the narrative.
#   lab02.sh up | status | update | reboot | rollback | fail-update | down | destroy
# Needs outbound access to the Flatcar release hosts (image download and the update itself)
# unless you point FLATCAR_IMAGE_BASE_URL and the update server at your own mirror.
# Commands are single-quoted on purpose where they must be expanded by the VM's shell.
# shellcheck disable=SC2016
# shellcheck shell=bash
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"
. "$LAB_DIR/../lib/image.sh"

NAME=lab02
OLD=$FLATCAR_OLD_VERSION
NEW=$FLATCAR_VERSION
GATE=${GATE:-true}
STATUS_TIMEOUT=${STATUS_TIMEOUT:-1800}

inv_var() { grep -E "^  $1:" "$LAB_DIR/inventory.yaml" | head -1 | sed -E 's/^[^:]+:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }

sh_vm() { vm_ssh "$NAME" "$@"; }
os_version() { sh_vm '. /etc/os-release; echo $VERSION_ID' 2>/dev/null | tr -d '\r'; }
boot_id() { sh_vm 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '\r'; }

# slots: print priority/tries/successful for both USR slots and which one is running.
slots() {
    log "running /usr: $(sh_vm 'rootdev -s /usr' 2>/dev/null)"
    sh_vm 'sudo cgpt show "$(rootdev -d)" | grep -E "Label: \"USR|Attr:" | grep -A1 "USR-" | sed "s/^ *//"' 2>/dev/null || true
}

# wait_reboot OLD_BOOT_ID [TIMEOUT]: wait for ssh with a different boot id.
wait_reboot() {
    local old=$1 timeout=${2:-600} t=0 cur
    while :; do
        cur=$(boot_id || true)
        [ -n "$cur" ] && [ "$cur" != "$old" ] && return 0
        t=$((t + 5))
        [ "$t" -ge "$timeout" ] && die "no reboot observed within ${timeout}s"
        sleep 5
    done
}

# slot_successful: succeeds when the running USR slot has successful=1 in the GPT.
# Parses the documented `cgpt show` listing: "<start> <size> <num> Label: "USR-X"" followed
# by Type, UUID and Attr lines.
slot_successful() {
    sh_vm 'n=$(rootdev -s /usr | grep -o "[0-9]*$"); sudo cgpt show "$(rootdev -d)" | grep -A3 " $n  *Label" | grep -q "successful=1"' 2>/dev/null
}

wait_slot_successful() {
    local t=0 timeout=${1:-600}
    until slot_successful; do
        t=$((t + 5))
        if [ "$t" -ge "$timeout" ]; then
            log "slot not marked successful after ${timeout}s"
            return 1
        fi
        sleep 5
    done
}

update_status() { sh_vm 'sudo update_engine_client -status 2>&1' | tr -d '\r'; }

cmd_up() {
    need curl gpg qemu-img qemu-system-x86_64 ssh ssh-keygen
    [ -x "$TOOLS_BIN/nodegen" ] || die "run 'make tools' first (from the repository root)"
    local key state base port
    key=$(ensure_ssh_key)
    state=$(lab_state_dir)
    base=$(image_fetch "$OLD")
    "$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" \
        -template "$LAB_DIR/butane/node.bu.tmpl" -out "$state/render" -transpile \
        -var "ssh_pubkey=$(cat "$key.pub")" -var "gate=$GATE"
    vm_create "$NAME" "$base" 20G
    port=$(inv_var ssh_port)
    vm_start "$NAME" "$state/render/$NAME.ign" 2048 2 user 52:54:00:77:02:01 "$port"
    vm_wait_ssh "$NAME" 300
    log "booted Flatcar $(os_version) (expected $OLD), health gate: $GATE"
}

cmd_status() {
    vm_is_running "$NAME" || die "VM is not running (make lab02-up)"
    log "OS version:    $(os_version)"
    slots
    log "update_engine: $(update_status | grep -E 'CURRENT_OP|NEW_VERSION' | tr '\n' ' ')"
    log "healthy flag:  $(sh_vm 'test -e /run/first-boot-healthy && echo present || echo absent')"
    log "critical svc:  $(sh_vm 'systemctl is-active lab-critical.service' || true)"
    log "/etc mounted as: $(sh_vm 'findmnt -no FSTYPE,SOURCE /etc' 2>/dev/null || echo 'n/a')"
}

cmd_update() {
    vm_is_running "$NAME" || die "VM is not running (make lab02-up)"
    local ver
    ver=$(os_version)
    log "before: running $ver"
    slots
    sh_vm 'sudo systemctl start update-engine.service' >/dev/null 2>&1 || true
    sh_vm 'sudo update_engine_client -check_for_update' >/dev/null 2>&1 || true
    local t=0 st
    while :; do
        st=$(update_status || true)
        log "$(printf '%s' "$st" | grep -E 'CURRENT_OP|PROGRESS|NEW_VERSION' | tr '\n' ' ')"
        printf '%s' "$st" | grep -q UPDATE_STATUS_UPDATED_NEED_REBOOT && break
        printf '%s' "$st" | grep -q UPDATE_STATUS_REPORTING_ERROR_EVENT && die "update_engine reported an error: journalctl -u update-engine on the VM"
        t=$((t + 15))
        [ "$t" -ge "$STATUS_TIMEOUT" ] && die "update not staged within ${STATUS_TIMEOUT}s"
        sleep 15
    done
    log "update staged. The passive slot now has the higher priority and one try:"
    slots
    log "reboot flag for kured: $(sh_vm 'test -e /run/reboot-required && echo /run/reboot-required present || echo absent')"
}

cmd_reboot() {
    vm_is_running "$NAME" || die "VM is not running"
    local old
    old=$(boot_id)
    log "rebooting from $(os_version)"
    sh_vm 'sudo systemctl reboot' >/dev/null 2>&1 || true
    sleep 5
    wait_reboot "$old" 600
    log "now running $(os_version)"
    slots
    log "waiting for update_engine to mark the new slot successful (gated by the health check)"
    if wait_slot_successful 600; then
        log "slot marked successful"
    fi
    slots
    log "/etc is now: $(sh_vm 'findmnt -no FSTYPE,SOURCE /etc')"
}

cmd_rollback() {
    vm_is_running "$NAME" || die "VM is not running"
    local old passive
    old=$(boot_id)
    log "manual rollback from $(os_version)"
    # Freeze updates so the node does not immediately re-stage the version we are leaving.
    sh_vm 'grep -qx SERVER=disabled /etc/flatcar/update.conf || echo SERVER=disabled | sudo tee -a /etc/flatcar/update.conf >/dev/null'
    passive=$(sh_vm 'cgpt find -t flatcar-usr | grep -v "$(rootdev -s /usr)"' | tr -d '\r')
    log "passive slot: $passive"
    sh_vm "sudo cgpt prioritize $passive"
    slots
    sh_vm 'sudo systemctl reboot' >/dev/null 2>&1 || true
    sleep 5
    wait_reboot "$old" 600
    log "now running $(os_version)"
    slots
}

cmd_fail_update() {
    vm_is_running "$NAME" || die "VM is not running"
    [ "$GATE" = true ] || die "this scenario needs the health gate (GATE=true)"
    [ "$(os_version)" = "$OLD" ] || die "start from the old version $OLD (make lab02-destroy lab02-up)"
    cmd_update
    log "simulating a bad update: the critical service will refuse to start on the next boot"
    sh_vm 'sudo touch /etc/lab/critical-fail'
    local t=0 saw_new=0 v timeout
    timeout=$(($(inv_var gate_timeout) + 900))
    sh_vm 'sudo systemctl reboot' >/dev/null 2>&1 || true
    sleep 5
    while :; do
        v=$(os_version || true)
        if [ -n "$v" ]; then
            if [ "$v" = "$NEW" ]; then
                if [ "$saw_new" = 0 ]; then
                    log "booted the NEW version $v; the critical service is failing, so the gate stays closed"
                    saw_new=1
                fi
            elif [ "$v" = "$OLD" ] && [ "$saw_new" = 1 ]; then
                log "back on $v: GRUB fell back to the previous slot after the unhealthy boot"
                break
            fi
        fi
        t=$((t + 10))
        [ "$t" -ge "$timeout" ] && die "automatic rollback not observed within ${timeout}s"
        sleep 10
    done
    slots
    sh_vm 'sudo rm -f /etc/lab/critical-fail'
    log "evidence from the failed boot:"
    sh_vm 'journalctl -b -1 -u reboot-after-unhealthy-upgrade.service -o cat --no-pager 2>/dev/null | tail -3' || true
}

case ${1:-} in
up) cmd_up ;;
status) cmd_status ;;
update) cmd_update ;;
reboot) cmd_reboot ;;
rollback) cmd_rollback ;;
fail-update) cmd_fail_update ;;
down) vm_stop "$NAME" ;;
destroy)
    vm_destroy "$NAME"
    rm -rf "$LAB_DIR/.state"
    ;;
*) die "usage: $0 up|status|update|reboot|rollback|fail-update|down|destroy" ;;
esac
