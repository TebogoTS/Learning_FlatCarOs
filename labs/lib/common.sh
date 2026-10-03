#!/usr/bin/env bash
# Shared helpers for the lab scripts. Source this file; do not execute it.
# shellcheck shell=bash

set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$LIB_DIR/../.." && pwd)
export REPO_ROOT LIB_DIR

# shellcheck source=../../versions.env
. "$REPO_ROOT/versions.env"

CACHE_DIR=${CACHE_DIR:-$REPO_ROOT/.cache}
TOOLS_BIN=${TOOLS_BIN:-$REPO_ROOT/tools/bin}
export CACHE_DIR TOOLS_BIN

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() {
    log "ERROR: $*"
    exit 1
}

# need CMD...: fail with a clear message when a prerequisite is missing.
need() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
    done
}

# sha256_of FILE: print the hex SHA-256 of a file (GNU or BSD tooling).
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# download URL DEST: fetch with retries, writing atomically.
download() {
    local url=$1 dest=$2 tmp
    tmp=$(mktemp "${dest}.XXXXXX")
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
        rm -f "$tmp"
        die "download failed: $url"
    fi
    mv "$tmp" "$dest"
}

# lab_state_dir: per-lab runtime state (image overlays, keys, pki). Gitignored.
# LAB_DIR must be set by the calling lab script.
lab_state_dir() {
    : "${LAB_DIR:?LAB_DIR must be set}"
    mkdir -p "$LAB_DIR/.state"
    printf '%s\n' "$LAB_DIR/.state"
}

# ensure_ssh_key: create the lab's ed25519 key pair once; print the private key path.
ensure_ssh_key() {
    local dir key
    dir=$(lab_state_dir)
    key=$dir/id_ed25519
    if [ ! -f "$key" ]; then
        need ssh-keygen
        ssh-keygen -q -t ed25519 -N '' -C "flatcar-deep-dive-lab" -f "$key"
    fi
    printf '%s\n' "$key"
}

# lab_ssh_opts: ssh options for throwaway lab VMs (host keys change on every rebuild).
lab_ssh_opts() {
    printf '%s\n' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -o BatchMode=yes
}
