#!/usr/bin/env bash
# Plain-QEMU VM helpers for the labs. Source this file; do not execute it.
#
# Design notes
#  * Each VM is a qcow2 overlay on a verified, read-only base image, so the base is
#    never written and a "rebuild" is just deleting the overlay.
#  * Ignition is delivered the way Flatcar's own QEMU wrapper does it:
#    -fw_cfg name=opt/org.flatcar-linux/config,file=<config.ign>
#    (see build_library/qemu_template.sh in flatcar/scripts).
#  * Two network modes: "user" (no privileges, ssh via a forwarded localhost port)
#    and "bridge" (needs the host bridge from net.sh, gives each VM a real address).
#  * Set VM_DRY_RUN=1 to print the QEMU command instead of running it.
# shellcheck shell=bash
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# vm_dir NAME: state directory of a VM.
vm_dir() {
    local d
    d=$(lab_state_dir)/vms/$1
    mkdir -p "$d"
    printf '%s\n' "$d"
}

# vm_accel_args: KVM when usable, otherwise (slow) TCG emulation.
vm_accel_args() {
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        printf '%s\n' -machine q35,accel=kvm -cpu host
    else
        log "WARNING: /dev/kvm is not usable; falling back to TCG emulation (very slow)"
        printf '%s\n' -machine q35,accel=tcg -cpu max
    fi
}

# vm_create NAME BASE_IMAGE [DISK_SIZE]: create the copy-on-write overlay once.
vm_create() {
    local name=$1 base=$2 size=${3:-20G} dir
    need qemu-img
    dir=$(vm_dir "$name")
    if [ -e "$dir/disk.qcow2" ]; then
        log "overlay for $name already exists (delete it to re-provision)"
        return
    fi
    qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$dir/disk.qcow2" "$size"
}

# vm_start NAME IGNITION MEM_MIB CPUS NETMODE MAC SSH_PORT_OR_IP [EXTRA_HOSTFWD...]
#   NETMODE=user:   arg 7 is the host port forwarded to guest ssh; EXTRA_HOSTFWD are "host:guest" pairs.
#   NETMODE=bridge: arg 7 is the VM's IP address (recorded so vm_ssh can reach it).
vm_start() {
    local name=$1 ign=$2 mem=$3 cpus=$4 netmode=$5 mac=$6 addr=$7
    shift 7
    local dir
    dir=$(vm_dir "$name")
    [ -f "$dir/disk.qcow2" ] || die "no disk for $name; run vm_create first"
    [ -f "$ign" ] || die "Ignition file not found: $ign"
    if vm_is_running "$name"; then
        log "$name is already running"
        return
    fi

    local netdev
    case $netmode in
    user)
        netdev="user,id=net0,hostfwd=tcp:127.0.0.1:${addr}-:22"
        local f
        for f in "$@"; do
            netdev+=",hostfwd=tcp:127.0.0.1:${f%%:*}-:${f#*:}"
        done
        printf '127.0.0.1 %s\n' "$addr" >"$dir/addr"
        ;;
    bridge)
        netdev="bridge,id=net0,br=${LAB_BRIDGE}"
        printf '%s 22\n' "$addr" >"$dir/addr"
        ;;
    *) die "unknown network mode: $netmode" ;;
    esac

    local accel
    # shellcheck disable=SC2207
    accel=($(vm_accel_args))

    local cmd=(
        qemu-system-x86_64
        -name "$name"
        "${accel[@]}"
        -smp "$cpus" -m "$mem"
        -display none -serial "file:$dir/console.log"
        -daemonize -pidfile "$dir/pid"
        -drive "if=none,id=blk,file=$dir/disk.qcow2,format=qcow2"
        -device "virtio-blk-pci,drive=blk,bootindex=1"
        -netdev "$netdev" -device "virtio-net-pci,netdev=net0,mac=$mac"
        -object "rng-random,filename=/dev/urandom,id=rng0" -device "virtio-rng-pci,rng=rng0"
        -fw_cfg "name=opt/org.flatcar-linux/config,file=$ign"
    )

    if [ "${VM_DRY_RUN:-0}" = 1 ]; then
        printf '%s ' "${cmd[@]}"
        printf '\n'
        return
    fi
    command -v qemu-system-x86_64 >/dev/null 2>&1 || die "qemu-system-x86_64 not found (install qemu-system-x86)"
    log "starting $name ($netmode, $mem MiB, $cpus vCPU)"
    "${cmd[@]}" || die "qemu failed to start $name (bridge mode needs qemu-bridge-helper permission for $LAB_BRIDGE; see labs/README.md)"
}

vm_pid() {
    local f
    f=$(vm_dir "$1")/pid
    [ -s "$f" ] && cat "$f"
}

vm_is_running() {
    local pid
    pid=$(vm_pid "$1" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# vm_stop NAME: terminate the VM (hard power-off; the overlay keeps its state).
vm_stop() {
    local pid
    pid=$(vm_pid "$1" 2>/dev/null) || return 0
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "stopping $1 (pid $pid)"
        kill "$pid"
        local _
        for _ in $(seq 1 30); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$(vm_dir "$1")/pid"
}

# vm_destroy NAME: stop and delete all state of the VM.
vm_destroy() {
    vm_stop "$1"
    rm -rf "$(vm_dir "$1")"
}

# vm_ssh NAME COMMAND...: run a command in the VM as core.
vm_ssh() {
    local name=$1 host port key
    shift
    read -r host port <"$(vm_dir "$name")/addr" || die "no address recorded for $name"
    key=$(ensure_ssh_key)
    # shellcheck disable=SC2046
    ssh $(lab_ssh_opts) -i "$key" -p "$port" "core@$host" "$@"
}

# vm_wait_ssh NAME [TIMEOUT_SECONDS]: wait until ssh answers.
vm_wait_ssh() {
    local name=$1 timeout=${2:-300} t=0
    while ! vm_ssh "$name" true >/dev/null 2>&1; do
        t=$((t + 3))
        [ "$t" -ge "$timeout" ] && die "$name: ssh did not come up within ${timeout}s (see $(vm_dir "$name")/console.log)"
        sleep 3
    done
    log "$name: ssh is up"
}
