#!/usr/bin/env bash
# Run the lab's real control-plane units natively on this machine, without VMs.
#
# This validates what can be validated without booting Flatcar: that the pinned Kubernetes and
# etcd binaries accept the exact flags in the rendered units, that the generated certificates and
# kubeconfigs are accepted, that RBAC bootstrap works, that secrets are encrypted at rest, and that
# the kubelet and kube-proxy configs parse. It cannot validate Flatcar behaviour (Ignition,
# networkd, containerd, CNI): only a real boot does that.
#
# The ExecStart lines are taken from the transpiled Ignition JSON, not copied, so the test cannot
# drift from what the VMs run. Only paths are rewritten (/opt/bin, /var/lib/kubernetes, ...).
# shellcheck shell=bash
# shellcheck disable=SC2317  # functions invoked through traps and helpers
# shellcheck source=env.sh
LAB04_STATE=${LAB04_NATIVE_STATE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.cache/lab04-native}
export LAB04_STATE
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
need python3 curl openssl

[ -x "$TOOLS_BIN/nodegen" ] || die "run 'make tools' first"
"$LAB_DIR/scripts/artifacts.sh"
"$LAB_DIR/scripts/pki.sh"
"$LAB_DIR/scripts/cluster.sh" render >/dev/null

N=$STATE/native
# A previous interrupted run may have left processes behind; they would hold the ports.
if [ -f "$N/pids" ]; then
    xargs -r kill <"$N/pids" 2>/dev/null || true
    sleep 1
fi
rm -rf "$N"
mkdir -p "$N/kubernetes" "$N/config" "$N/etcd" "$N/kubelet" "$N/kube-proxy" "$N/logs"
pids=()
cleanup() {
    local p
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
    wait 2>/dev/null || true
}
trap cleanup EXIT

# extract_unit NAME: print the ExecStart command of a unit in the server's Ignition config.
# extract_file PATH NODE: write the inline content of a file from a node's Ignition config to stdout.
ign_py() {
    python3 - "$@" <<'PY'
import json, sys, urllib.parse, base64, gzip
kind, node, name = sys.argv[1:4]
cfg = json.load(open(f"{sys.argv[4]}/{node}.ign"))
if kind == "unit":
    for u in cfg["systemd"]["units"]:
        if u["name"] == name:
            text = u["contents"].replace("\\\n", " ")
            for line in text.splitlines():
                if line.startswith("ExecStart="):
                    print(" ".join(line[len("ExecStart="):].split()))
                    sys.exit(0)
    sys.exit(f"unit {name} not found")
else:
    for f in cfg["storage"]["files"]:
        if f["path"] == name:
            src = f["contents"]["source"]
            head, data = src.split(",", 1)
            if head.endswith(";base64"):
                raw = base64.b64decode(data)
            else:
                raw = urllib.parse.unquote_to_bytes(data)
            # Butane compresses inline contents when that makes the config smaller.
            if f["contents"].get("compression") == "gzip":
                raw = gzip.decompress(raw)
            sys.stdout.buffer.write(raw)
            sys.exit(0)
    sys.exit(f"file {name} not found")
PY
}

rewrite() {
    sed -e "s#/opt/bin/#$ART/#g" \
        -e "s#/var/lib/kubernetes#$N/kubernetes#g" \
        -e "s#/etc/kubernetes/config#$N/config#g" \
        -e "s#/var/lib/etcd#$N/etcd#g" \
        -e "s#/var/lib/kubelet#$N/kubelet#g" \
        -e "s#/var/lib/kube-proxy#$N/kube-proxy#g" \
        -e "s#/var/log/audit.log#$N/logs/audit.log#g"
}

# Stage the files the units expect, from the same Ignition config.
for f in ca.crt ca.key kube-api-server.crt kube-api-server.key service-accounts.crt service-accounts.key \
    encryption-config.yaml kube-controller-manager.kubeconfig kube-scheduler.kubeconfig admin.kubeconfig; do
    ign_py file server "/var/lib/kubernetes/$f" "$RENDER" >"$N/kubernetes/$f"
done
for f in kube-scheduler.yaml kube-apiserver-to-kubelet.yaml; do
    ign_py file server "/etc/kubernetes/config/$f" "$RENDER" | rewrite >"$N/config/$f"
done
# The API server and etcd both listen on all addresses in the units; this machine is not the VM,
# so the advertised address is the one thing that has to be local.
unit() { ign_py unit server "$1" "$RENDER" | rewrite | sed -e 's#--advertise-address=[0-9.]*#--advertise-address=127.0.0.1#'; }

start() { # name command...
    local name=$1
    shift
    log "starting $name: $*" | cut -c1-200
    # shellcheck disable=SC2086
    eval "$* >$N/logs/$name.log 2>&1 &"
    pids+=("$!")
    echo "$!" >>"$N/pids"
}

fail=0
ok() { log "PASS $*"; }
bad() { log "FAIL $*"; fail=1; }
alive() { kill -0 "${pids[-1]}" 2>/dev/null; }
# check DESCRIPTION COMMAND...: pass or fail on the command's exit status.
check() {
    local d=$1
    shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}
# identity USER EXPECTED: the kubeconfig for USER must authenticate as EXPECTED.
identity() {
    [ "$(as_user "$1" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)" = "$2" ]
}

start etcd "$(unit etcd.service)"
sleep 3
if alive; then ok "etcd started with the unit's flags"; else
    bad "etcd exited"; tail -20 "$N/logs/etcd.log"; exit 1
fi

start kube-apiserver "$(unit kube-apiserver.service)"
kc() { "$ART/kubectl" --kubeconfig "$N/kubernetes/admin.kubeconfig" "$@"; }
for _ in $(seq 1 60); do
    kc get --raw /readyz >/dev/null 2>&1 && break
    alive || break
    sleep 2
done
if kc get --raw /readyz >/dev/null 2>&1; then ok "kube-apiserver ready (flags, certs, encryption config accepted)"; else
    bad "kube-apiserver not ready"; tail -30 "$N/logs/kube-apiserver.log"; exit 1
fi

start kube-controller-manager "$(unit kube-controller-manager.service)"
start kube-scheduler "$(unit kube-scheduler.service)"

# The unit's RBAC step.
check "RBAC manifest applies (kthw-bootstrap-rbac.service)" kc apply -f "$N/config/kube-apiserver-to-kubelet.yaml"
check "clusterrolebinding for the API server's kubelet client exists" kc get clusterrolebinding system:kube-apiserver

# Leader election proves both controllers authenticated with their kubeconfigs and have RBAC.
for lease in kube-controller-manager kube-scheduler; do
    got=0
    for _ in $(seq 1 30); do
        if kc -n kube-system get lease "$lease" >/dev/null 2>&1; then got=1; break; fi
        sleep 2
    done
    if [ $got = 1 ]; then ok "$lease acquired its leader lease"; else
        bad "$lease has no lease"; tail -15 "$N/logs/$lease.log"
    fi
done

# Certificate identities (KTHW chapter 04).
as_user() { "$ART"/kubectl --kubeconfig "$KCFG/$1.kubeconfig" --server "https://127.0.0.1:$API_PORT" "${@:2}"; }
check "admin kubeconfig authenticates as admin" identity admin admin
check "node-0 kubeconfig authenticates as system:node:node-0" identity node-0 system:node:node-0
check "kube-proxy kubeconfig authenticates as system:kube-proxy" identity kube-proxy system:kube-proxy

# Chapter 06: encryption at rest.
kc create secret generic kthw-smoke --from-literal=mykey=mydata >/dev/null
if ETCDCTL_API=3 "$ART/etcdctl" get /registry/secrets/default/kthw-smoke 2>/dev/null | grep -aq 'k8s:enc:aescbc:v1:key1'; then
    ok "secret is stored with the aescbc key1 prefix"
else bad "secret not encrypted"; fi

# Service account tokens use the service-accounts key pair (chapter 04/08).
# The default ServiceAccount is created by the controller manager shortly after it starts.
token_issued() {
    local _
    for _ in $(seq 1 20); do
        kc create token default >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}
check "service account token issued (signed with the service-accounts key)" token_issued

# Controller manager really works: a Deployment produces a ReplicaSet.
kc create deployment smoke --image=registry.k8s.io/pause:3.10 >/dev/null
rs=0
for _ in $(seq 1 20); do
    [ -n "$(kc get rs -l app=smoke -o name 2>/dev/null)" ] && rs=1 && break
    sleep 1
done
if [ $rs = 1 ]; then ok "controller manager created a ReplicaSet"; else bad "no ReplicaSet created"; fi

# Lab 05's add-on manifests, validated by a real API server (the same pinned hashes lab 05 uses):
# CRDs and the controller are applied, then the plans and kured DaemonSet are checked server-side.
L5=$LAB_DIR/../05-rke2-on-flatcar
# shellcheck source=../../05-rke2-on-flatcar/artifacts.env
. "$L5/artifacts.env"
suc=https://github.com/rancher/system-upgrade-controller/releases/download/$SUC_VERSION
pinned() { # URL SHA256 -> file path
    local f
    f=$N/$(basename "$1")
    download "$1" "$f"
    [ "$(sha256_of "$f")" = "$2" ] || die "hash mismatch for $1"
    echo "$f"
}
crd=$(pinned "$suc/crd.yaml" "$SUC_CRD_SHA256")
dep=$(pinned "$suc/system-upgrade-controller.yaml" "$SUC_DEPLOY_SHA256")
rbac=$(pinned "https://raw.githubusercontent.com/kubereboot/kured/1.23.0/kured-rbac.yaml" "$KURED_RBAC_SHA256")
check "system-upgrade-controller CRD applies" kc apply -f "$crd"
check "system-upgrade-controller manifest applies" kc apply -f "$dep"
check "SUC CRD becomes Established" kc wait --for=condition=Established crd/plans.upgrade.cattle.io --timeout=60s
sed "s|__RKE2_VERSION_UPGRADE__|$RKE2_VERSION_UPGRADE|g" "$L5/manifests/suc-plans.yaml" >"$N/suc-plans.yaml"
check "SUC plans (server-plan, agent-plan) are accepted by the CRD schema" kc apply --dry-run=server -f "$N/suc-plans.yaml"
check "kured RBAC applies" kc apply -f "$rbac"
check "kured DaemonSet is accepted" kc apply --dry-run=server -f "$L5/manifests/kured-ds.yaml"

# Kubelet and kube-proxy: the configs must parse (strict decoding). They will then fail to reach a
# container runtime or iptables here, which is not what this checks.
ign_py file node-0 /var/lib/kubelet/kubelet-config.yaml "$RENDER" | rewrite >"$N/kubelet/kubelet-config.yaml"
for f in ca.crt kubelet.crt kubelet.key kubeconfig; do ign_py file node-0 "/var/lib/kubelet/$f" "$RENDER" >"$N/kubelet/$f"; done
sed -i "s#/run/containerd/containerd.sock#$N/nonexistent.sock#" "$N/kubelet/kubelet-config.yaml"
sed -i "s#10.77.0.10#127.0.0.1#" "$N/kubelet/kubeconfig"
# This machine may still be on cgroup v1, which kubelet 1.36 refuses by default; Flatcar uses cgroup v2.
# Allow it for the test only, so the kubelet gets past validation to the container runtime.
echo 'failCgroupV1: false' >>"$N/kubelet/kubelet-config.yaml"
timeout 15 "$ART/kubelet" --config "$N/kubelet/kubelet-config.yaml" --kubeconfig "$N/kubelet/kubeconfig" --root-dir "$N/kubelet/root" --v=2 >"$N/logs/kubelet.log" 2>&1 || true
if grep -qE "strict decoding|unknown field|failed to load|failed to validate|unknown flag|invalid configuration" "$N/logs/kubelet.log"; then
    bad "kubelet rejected its config or flags"; grep -E "strict decoding|unknown|failed to|invalid" "$N/logs/kubelet.log" | head -3 | cut -c1-300
elif grep -q "nonexistent.sock" "$N/logs/kubelet.log"; then
    ok "kubelet accepted its config and flags and tried the configured container runtime socket (absent here, as expected)"
else
    bad "kubelet check inconclusive: see $N/logs/kubelet.log"; head -5 "$N/logs/kubelet.log" | cut -c1-300
fi

ign_py file node-0 /var/lib/kube-proxy/kube-proxy-config.yaml "$RENDER" | rewrite >"$N/kube-proxy/kube-proxy-config.yaml"
ign_py file node-0 /var/lib/kube-proxy/kubeconfig "$RENDER" >"$N/kube-proxy/kubeconfig"
sed -i "s#10.77.0.10#127.0.0.1#" "$N/kube-proxy/kubeconfig"
timeout 10 "$ART/kube-proxy" --config "$N/kube-proxy/kube-proxy-config.yaml" --v=2 >"$N/logs/kube-proxy.log" 2>&1 || true
if grep -qiE "unknown field|strict decoding|failed to (load|read|parse)|unknown flag|invalid configuration" "$N/logs/kube-proxy.log"; then
    bad "kube-proxy rejected its config"; head -5 "$N/logs/kube-proxy.log" | cut -c1-300
elif grep -q "Caches are synced" "$N/logs/kube-proxy.log"; then
    ok "kube-proxy accepted its config and kubeconfig and synced from the API server"
else
    bad "kube-proxy check inconclusive: see $N/logs/kube-proxy.log"
fi

if [ $fail = 0 ]; then log "native control-plane test: all checks passed"; else log "native control-plane test: FAILURES (logs in $N/logs)"; fi
exit $fail
