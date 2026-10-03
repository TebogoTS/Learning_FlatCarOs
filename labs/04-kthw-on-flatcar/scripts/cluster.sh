#!/usr/bin/env bash
# Lab 04 cluster lifecycle: render the three Ignition configs, serve the artifacts, boot the VMs.
#   cluster.sh render     render and transpile the Butane configs (KTHW chapters 03 and 07-09 as config)
#   cluster.sh hosts      print the DHCP host lines for sudo labs/lib/net.sh dhcp-start
#   cluster.sh serve      start|stop the artifact web server on the lab bridge
#   cluster.sh up         render, then create and boot the VMs
#   cluster.sh status     which VMs are running
#   cluster.sh access     write the jumpbox kubeconfig and show how to use it (KTHW chapter 10)
#   cluster.sh down       power the VMs off (disks kept)
#   cluster.sh destroy    delete the VMs and all generated state
# shellcheck shell=bash
# shellcheck source=env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
. "$LAB_DIR/../lib/qemu.sh"
. "$LAB_DIR/../lib/image.sh"

nodes() { "$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" -list; }

render() {
    [ -x "$TOOLS_BIN/nodegen" ] || die "run 'make tools' first (from the repository root)"
    [ -s "$PKI/ca.crt" ] || die "no PKI yet: run 'make lab04-pki'"
    [ -s "$ART/kubelet" ] || die "no artifacts yet: run 'make lab04-artifacts'"
    local key
    key=$(ensure_ssh_key)
    # The templates read keys, kubeconfigs, hashes and static config relative to $STATE.
    rm -rf "${STATE:?}/config" && cp -r "$LAB_DIR/config" "$STATE/config"
    "$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" \
        -template "server=$LAB_DIR/butane/server.bu.tmpl" \
        -template "worker=$LAB_DIR/butane/worker.bu.tmpl" \
        -partial "$LAB_DIR/butane/common.tmpl" \
        -base-dir "$STATE" -out "$RENDER" -transpile \
        -var "ssh_pubkey=$(cat "$key.pub")"
}

hosts() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do
        printf '%s,%s,%s\n' "$mac" "$ip" "$name"
    done < <(nodes)
}

serve() {
    local pidfile=$STATE/serve.pid
    running() { [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }
    case ${1:-} in
    start)
        need python3
        [ -s "$ART/kubelet" ] || die "no artifacts yet: run 'make lab04-artifacts'"
        if running; then log "artifact server already running"; return; fi
        python3 -m http.server "$SERVE_PORT" --bind "$LAB_GATEWAY" --directory "$ART" >"$STATE/serve.log" 2>&1 &
        echo $! >"$pidfile"
        sleep 1
        running || die "artifact server failed to start (is the bridge up? see $STATE/serve.log)"
        log "serving $ART on http://$LAB_GATEWAY:$SERVE_PORT/"
        ;;
    stop)
        if running; then kill "$(cat "$pidfile")"; rm -f "$pidfile"; log "artifact server stopped"; fi
        ;;
    *) die "usage: $0 serve start|stop" ;;
    esac
}

up() {
    need qemu-img qemu-system-x86_64 ssh ssh-keygen curl gpg
    ip link show "$LAB_BRIDGE" >/dev/null 2>&1 || die "bridge $LAB_BRIDGE missing: run 'sudo labs/lib/net.sh up' (see labs/README.md)"
    render
    serve start
    local base name role ip mac
    base=$(image_fetch "$FLATCAR_VERSION")
    while IFS=$'\t' read -r name role ip mac; do
        vm_create "$name" "$base" 20G
        # The control-plane node needs more memory than the workers.
        local mem=2048
        [ "$role" = server ] && mem=3072
        vm_start "$name" "$RENDER/$name.ign" "$mem" 2 bridge "$mac" "$ip"
    done < <(nodes)
    while IFS=$'\t' read -r name role ip mac; do
        vm_wait_ssh "$name" 600
    done < <(nodes)
    log "all VMs are up. Watch the control plane come together:  make lab04-verify"
}

status() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do
        if vm_is_running "$name"; then echo "$name running ($ip)"; else echo "$name stopped"; fi
    done < <(nodes)
}

access() {
    [ -s "$KCFG/admin-remote.kubeconfig" ] || die "no PKI yet: run 'make lab04-pki'"
    [ -x "$ART/kubectl" ] || die "no kubectl yet: run 'make lab04-artifacts'"
    cat <<MSG
Use the pinned kubectl and the admin kubeconfig from the jumpbox:

  export KUBECONFIG=$KCFG/admin-remote.kubeconfig
  $ART/kubectl version
  $ART/kubectl get nodes -o wide
MSG
}

down() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do vm_stop "$name"; done < <(nodes)
    serve stop
}

destroy() {
    local name role ip mac
    while IFS=$'\t' read -r name role ip mac; do vm_destroy "$name"; done < <(nodes)
    serve stop
    rm -rf "$STATE/render"
    log "VMs removed. Generated PKI, kubeconfigs and downloads are kept in $STATE (delete it to start over)."
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
render) render ;;
hosts) hosts ;;
serve) serve "$@" ;;
up) up ;;
status) status ;;
access) access ;;
down) down ;;
destroy) destroy ;;
*) die "usage: $0 render|hosts|serve start|stop|up|status|access|down|destroy" ;;
esac
