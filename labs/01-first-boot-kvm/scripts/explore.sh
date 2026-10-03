#!/usr/bin/env bash
# Lab 01 guided exploration: prints what the README asks you to look at.
# shellcheck shell=bash
# Commands are single-quoted on purpose: they must be expanded by the shell on the VM, not here.
# shellcheck disable=SC2016
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"
name=lab01
vm_is_running "$name" || die "VM $name is not running (make lab01-up)"

section() { printf '\n===== %s =====\n' "$*"; }
run() {
    printf '$ %s\n' "$*"
    vm_ssh "$name" "$@" 2>&1 || true
}

section "Partition table (labels, sizes)"
run lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINTS
section "GPT attributes: priority / tries / successful per USR slot"
run 'sudo cgpt show "$(rootdev -d)" | grep -E "Label|Attr"'
section "Which partition backs /usr, and what is really mounted there"
run rootdev -s /usr
run 'mount | grep -w /usr'
section "dm-verity: /usr is a verity device"
run 'sudo veritysetup status usr | head -12'
section "/usr is read-only"
run 'sudo touch /usr/should-fail'
section "Kernel command line (note mount.usrflags=ro, usr=PARTUUID=..., verity hash)"
run 'cat /proc/cmdline | tr " " "\n" | grep -E "usr|root|flatcar|verity"'
section "Where state lives: ROOT is ext4 mounted at /"
run 'findmnt /'
section "What Ignition wrote"
run 'cat /etc/lab/provisioned-by-ignition; cat /etc/flatcar/update.conf; cat /var/lib/lab/hello'
section "Kernel and initrd per slot live on the EFI system partition"
run 'ls -la /boot/flatcar/'
section "Extensions merged into /usr (Docker and containerd are sysexts)"
run 'systemd-sysext status'
section "/etc composition (overlay on older releases, confext on 4628+)"
run 'findmnt /etc'
run 'systemd-confext status 2>&1 | head -8'
