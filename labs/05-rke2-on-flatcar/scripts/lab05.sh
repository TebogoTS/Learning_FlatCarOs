#!/usr/bin/env bash
# Lab 05 driver: RKE2 on Flatcar (1 server, 2 agents), then an RKE2 upgrade and an OS update
# coordinated by system-upgrade-controller and kured.
#   lab05.sh render          render and transpile the three Ignition configs
#   lab05.sh hosts           DHCP host lines for: sudo labs/lib/net.sh dhcp-start FILE
#   lab05.sh up              create and boot the VMs (old Flatcar release, RKE2 start version)
#   lab05.sh status          VMs, RKE2 nodes and versions
#   lab05.sh kubectl ARGS    run the server's kubectl as root with the cluster's admin kubeconfig
#   lab05.sh addons          install system-upgrade-controller and kured from hash-pinned manifests
#   lab05.sh upgrade-rke2    apply the SUC plans: server first, then agents, one node at a time
#   lab05.sh os-update NODE  unfreeze updates on NODE and stage the Flatcar update (kured then reboots it)
#   lab05.sh down | destroy
# Commands in single quotes are meant to be expanded by the VM's shell.
# shellcheck disable=SC2016
# shellcheck shell=bash
# shellcheck source=../../lib/qemu.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/qemu.sh"
. "$LAB_DIR/../lib/image.sh"
# shellcheck source=../artifacts.env
. "$LAB_DIR/artifacts.env"

STATE=$(lab_state_dir)
RENDER=$STATE/render
SERVER=rke2-server
OLD=$FLATCAR_OLD_VERSION

nodes() { "$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" -list; }
enc() { printf '%s' "${1//+/%2B}"; }

# nodegen_render OUTDIR SSH_PUBKEY TOKEN
nodegen_render() {
    [ -x "$TOOLS_BIN/nodegen" ] || die "run 'make tools' first (from the repository root)"
    mkdir -p "$1"
    "$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" \
        -template "server=$LAB_DIR/butane/server.bu.tmpl" \
        -template "agent=$LAB_DIR/butane/agent.bu.tmpl" \
        -partial "$LAB_DIR/butane/common.tmpl" \
        -out "$1" -transpile \
        -var "ssh_pubkey=$2" -var "token=$3" \
        -var "rke2_tag_url=$(enc "$RKE2_VERSION_START")" \
        -var "install_sh_sha256=$RKE2_INSTALL_SH_SHA256" \
        -var "tarball_sha256=$RKE2_START_TARBALL_SHA256" \
        -var "sums_sha256=$RKE2_START_SUMS_SHA256"
}

token() {
    local f=$STATE/token
    [ -s "$f" ] || { need openssl; openssl rand -hex 24 >"$f"; chmod 0600 "$f"; }
    cat "$f"
}

render() {
    local key
    key=$(ensure_ssh_key)
    nodegen_render "$RENDER" "$(cat "$key.pub")" "$(token)"
}

# render-ci: fixture ssh key and token, output where `make check` looks.
render_ci() {
    nodegen_render "$REPO_ROOT/build/lab05" \
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture lab-ci" \
        "fixture-token-not-secret"
}

hosts() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do printf '%s,%s,%s\n' "$mac" "$ip" "$name"; done < <(nodes)
}

up() {
    need qemu-img qemu-system-x86_64 ssh ssh-keygen curl gpg
    ip link show "$LAB_BRIDGE" >/dev/null 2>&1 || die "bridge $LAB_BRIDGE missing: run 'sudo labs/lib/net.sh up' (see labs/README.md)"
    render
    local base name role ip mac mem
    # Start from the OLD Flatcar release so there is a real OS update to take later.
    base=$(image_fetch "$OLD")
    while IFS=$'\t' read -r name role ip mac; do
        vm_create "$name" "$base" 30G
        mem=3072
        [ "$role" = server ] && mem=4096
        vm_start "$name" "$RENDER/$name.ign" "$mem" 2 bridge "$mac" "$ip"
    done < <(nodes)
    while IFS=$'\t' read -r name role ip mac; do vm_wait_ssh "$name" 600; done < <(nodes)
    log "VMs are up on Flatcar $OLD. RKE2 installs from the pinned artifacts now; watch with: make lab05-status"
}

kc() { vm_ssh "$SERVER" sudo /opt/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml "$@"; }

status() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do
        if vm_is_running "$name"; then
            printf '%-14s running  os=%s  rke2=%s\n' "$name" \
                "$(vm_ssh "$name" '. /etc/os-release; echo $VERSION_ID' 2>/dev/null || echo '?')" \
                "$(vm_ssh "$name" '/opt/rke2/bin/rke2 --version 2>/dev/null | head -1 | cut -d" " -f3' 2>/dev/null || echo 'not installed yet')"
        else
            printf '%-14s stopped\n' "$name"
        fi
    done < <(nodes)
    kc get nodes -o wide 2>/dev/null || echo "(API not answering yet)"
}

# fetch_pinned URL SHA256: print the file only if its hash matches.
fetch_pinned() {
    local f
    f=$(mktemp)
    download "$1" "$f"
    [ "$(sha256_of "$f")" = "$2" ] || { rm -f "$f"; die "hash mismatch for $1"; }
    cat "$f"
    rm -f "$f"
}

addons() {
    local suc=https://github.com/rancher/system-upgrade-controller/releases/download/$SUC_VERSION
    log "installing system-upgrade-controller $SUC_VERSION (hash-checked)"
    fetch_pinned "$suc/crd.yaml" "$SUC_CRD_SHA256" | kc apply -f -
    fetch_pinned "$suc/system-upgrade-controller.yaml" "$SUC_DEPLOY_SHA256" | kc apply -f -
    log "installing kured 1.23.0 (RBAC hash-checked, DaemonSet from manifests/kured-ds.yaml)"
    fetch_pinned "https://raw.githubusercontent.com/kubereboot/kured/1.23.0/kured-rbac.yaml" "$KURED_RBAC_SHA256" | kc apply -f -
    kc apply -f - <"$LAB_DIR/manifests/kured-ds.yaml"
    kc -n system-upgrade rollout status deploy/system-upgrade-controller --timeout=300s
    kc -n kube-system rollout status ds/kured --timeout=300s
}

upgrade_rke2() {
    log "applying SUC plans for $RKE2_VERSION_UPGRADE"
    sed "s|__RKE2_VERSION_UPGRADE__|$RKE2_VERSION_UPGRADE|g" "$LAB_DIR/manifests/suc-plans.yaml" | kc apply -f -
    log "watch: make lab05-kubectl ARGS='-n system-upgrade get plans,jobs -o wide'   and   make lab05-status"
}

os_update() {
    local node=${1:?usage: lab05.sh os-update NODE}
    log "$node: unfreezing Flatcar updates and staging the update"
    vm_ssh "$node" 'sudo sed -i "/^SERVER=disabled/d" /etc/flatcar/update.conf && sudo systemctl restart update-engine && sudo update_engine_client -update' || true
    vm_ssh "$node" 'ls -l /run/reboot-required 2>&1; update_engine_client -status 2>&1 | grep -E "CURRENT_OP|NEW_VERSION"' || true
    log "when /run/reboot-required exists, kured drains and reboots the node (one at a time, never during a SUC job)"
}

down() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do vm_stop "$name"; done < <(nodes)
}

destroy() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do vm_destroy "$name"; done < <(nodes)
    rm -rf "$RENDER" "$STATE/token"
}

sub=${1:-}
[ $# -gt 0 ] && shift
case $sub in
render) render ;;
render-ci) render_ci ;;
hosts) hosts ;;
up) up ;;
status) status ;;
kubectl) kc "$@" ;;
addons) addons ;;
upgrade-rke2) upgrade_rke2 ;;
os-update) os_update "$@" ;;
down) down ;;
destroy) destroy ;;
*) die "usage: $0 render|hosts|up|status|kubectl ARGS|addons|upgrade-rke2|os-update NODE|down|destroy" ;;
esac
