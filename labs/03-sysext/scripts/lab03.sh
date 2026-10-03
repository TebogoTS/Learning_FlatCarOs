#!/usr/bin/env bash
# Lab 03 driver: up | verify | upgrade-manual | upgrade-sysupdate | down | destroy
# Needs outbound access to the Flatcar release hosts for the base image only; the extension
# comes from the local HTTP server (scripts/serve.sh).
# Commands are single-quoted where the VM's shell must expand them.
# shellcheck disable=SC2016
# shellcheck shell=bash
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"
. "$LAB_DIR/../lib/image.sh"

NAME=lab03
PORT=${SERVE_PORT:-8089}
fail=0

sh_vm() { vm_ssh "$NAME" "$@"; }
check() {
    local desc=$1
    shift
    if sh_vm "$@" >/dev/null 2>&1; then log "PASS  $desc"; else
        log "FAIL  $desc"
        fail=1
    fi
}
expected_hash() { sha256_of "$LAB_DIR/out/flatcar-hello-$1.raw"; }

cmd_up() {
    need curl gpg qemu-img qemu-system-x86_64 ssh ssh-keygen python3
    [ -x "$TOOLS_BIN/nodegen" ] || die "run 'make tools' first (from the repository root)"
    [ -f "$LAB_DIR/out/flatcar-hello-v1.raw" ] || die "run 'make lab03-build' first"
    "$LAB_DIR/scripts/serve.sh" start
    local key state base
    key=$(ensure_ssh_key)
    state=$(lab_state_dir)
    base=$(image_fetch "$FLATCAR_VERSION")
    "$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" \
        -template "$LAB_DIR/butane/node.bu.tmpl" -out "$state/render" -transpile \
        -var "ssh_pubkey=$(cat "$key.pub")" -var "serve_port=$PORT"
    vm_create "$NAME" "$base" 20G
    vm_start "$NAME" "$state/render/$NAME.ign" 2048 2 user 52:54:00:77:03:01 2224
    vm_wait_ssh "$NAME" 300
}

cmd_verify() {
    vm_is_running "$NAME" || die "VM is not running (make lab03-up)"
    local tag=${1:-v1}
    check "running Flatcar $FLATCAR_VERSION" ". /etc/os-release && [ \"\$VERSION_ID\" = $FLATCAR_VERSION ]"
    check "systemd-sysext lists flatcar-hello" 'systemd-sysext status | grep -q flatcar-hello'
    check "/usr is now an overlay (the extension is merged)" '[ "$(findmnt -no FSTYPE /usr)" = overlay ]'
    check "the extension image on disk matches the pinned hash" \
        "[ \"\$(sha256sum /opt/extensions/flatcar-hello/flatcar-hello-$tag.raw | cut -d' ' -f1)\" = $(expected_hash "$tag") ]"
    check "/etc/extensions/flatcar-hello.raw links to $tag" \
        "[ \"\$(readlink /etc/extensions/flatcar-hello.raw)\" = /opt/extensions/flatcar-hello/flatcar-hello-$tag.raw ]"
    check "the binary came from the extension and reports $tag" "[ \"\$(/usr/bin/flatcar-hello --version)\" = $tag ]"
    check "the Upholds= drop-in started the service" 'systemctl is-active --quiet flatcar-hello.service'
    check "the service answers and sees the host OS" \
        ". /etc/os-release && curl -fsS http://127.0.0.1:8088/info | grep -q \"\\\"os_version_id\\\":\\\"\$VERSION_ID\\\"\""
    check "/usr is still not writable by the admin" '! sudo touch /usr/bin/lab-write-test'
    if [ "$fail" -eq 0 ]; then log "lab 03 ($tag): all checks passed"; else log "lab 03 ($tag): checks FAILED"; fi
    return "$fail"
}

# Swap to v2 by hand: fetch, verify against SHA256SUMS, repoint the link, refresh sysext.
cmd_upgrade_manual() {
    vm_is_running "$NAME" || die "VM is not running"
    [ -f "$LAB_DIR/out/flatcar-hello-v2.raw" ] || die "run 'make lab03-build' first (it builds v2)"
    "$LAB_DIR/scripts/serve.sh" start
    local want
    want=$(expected_hash v2)
    sh_vm "sudo curl -fsS -o /opt/extensions/flatcar-hello/flatcar-hello-v2.raw http://10.0.2.2:$PORT/flatcar-hello-v2.raw"
    sh_vm "[ \"\$(sha256sum /opt/extensions/flatcar-hello/flatcar-hello-v2.raw | cut -d' ' -f1)\" = $want ]" || die "downloaded v2 does not match the expected hash; not switching"
    sh_vm 'sudo ln -sfn /opt/extensions/flatcar-hello/flatcar-hello-v2.raw /etc/extensions/flatcar-hello.raw'
    # Flatcar's documented way to reload extensions at runtime.
    sh_vm 'sudo systemctl restart systemd-sysext'
    sh_vm 'sudo systemctl restart flatcar-hello.service'
    sleep 2
    cmd_verify v2
}

# Experimental: let systemd-sysupdate find v2 through the SHA256SUMS index.
cmd_upgrade_sysupdate() {
    vm_is_running "$NAME" || die "VM is not running"
    "$LAB_DIR/scripts/serve.sh" start
    sh_vm 'sudo /usr/lib/systemd/systemd-sysupdate -C flatcar-hello update' || die "sysupdate failed; see the README note on transfer file suffixes and Verify="
    sh_vm 'ls -l /opt/extensions/flatcar-hello/ /etc/extensions/flatcar-hello.raw'
    sh_vm 'sudo systemctl restart systemd-sysext && sudo systemctl restart flatcar-hello.service'
    sleep 2
    cmd_verify v2
}

case ${1:-} in
up) cmd_up ;;
verify) shift || true; cmd_verify "$@" ;;
upgrade-manual) cmd_upgrade_manual ;;
upgrade-sysupdate) cmd_upgrade_sysupdate ;;
down)
    vm_stop "$NAME"
    "$LAB_DIR/scripts/serve.sh" stop
    ;;
destroy)
    vm_destroy "$NAME"
    "$LAB_DIR/scripts/serve.sh" stop
    rm -rf "$LAB_DIR/.state"
    ;;
*) die "usage: $0 up|verify [TAG]|upgrade-manual|upgrade-sysupdate|down|destroy" ;;
esac
