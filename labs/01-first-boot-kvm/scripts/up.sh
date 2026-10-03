#!/usr/bin/env bash
# Lab 01: fetch the pinned image, render and transpile the config, boot one VM.
# shellcheck shell=bash
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"
. "$LAB_DIR/../lib/image.sh"

need curl gpg qemu-img qemu-system-x86_64 ssh ssh-keygen
[ -x "$TOOLS_BIN/nodegen" ] || die "run 'make tools' first (from the repository root)"

name=lab01
key=$(ensure_ssh_key)
state=$(lab_state_dir)
base=$(image_fetch "$FLATCAR_VERSION")

"$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" \
    -template "$LAB_DIR/butane/node.bu.tmpl" \
    -out "$state/render" -transpile \
    -var "ssh_pubkey=$(cat "$key.pub")"

vm_create "$name" "$base" 20G
ssh_port=$(grep -o 'ssh_port: "[0-9]*"' "$LAB_DIR/inventory.yaml" | grep -o '[0-9]*')
vm_start "$name" "$state/render/$name.ign" 2048 2 user 52:54:00:77:01:01 "$ssh_port"
vm_wait_ssh "$name" 300
log "VM is up. Try: make lab01-ssh   |   make lab01-explore   |   make lab01-verify"
