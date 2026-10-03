#!/usr/bin/env bash
# KTHW chapter 12 (smoke test) as an automated check, run from the jumpbox.
# shellcheck shell=bash
# shellcheck source=env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
. "$LAB_DIR/../lib/qemu.sh"

kubectl=$ART/kubectl
export KUBECONFIG=$KCFG/admin-remote.kubeconfig
fail=0
ok() { log "PASS $*"; }
bad() { log "FAIL $*"; fail=1; }
check() { # description command...
    local d=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

wait_for() { # seconds description command...
    local t=$1 d=$2 i
    shift 2
    for ((i = 0; i < t; i += 3)); do
        if "$@" >/dev/null 2>&1; then ok "$d"; return; fi
        sleep 3
    done
    bad "$d (timed out after ${t}s)"
}

# Chapters 07-09: the services Ignition enabled are running.
check "server: etcd, apiserver, controller-manager, scheduler active" \
    vm_ssh server 'systemctl is-active etcd kube-apiserver kube-controller-manager kube-scheduler'
for w in "${WORKERS[@]}"; do
    check "$w: containerd, kubelet, kube-proxy active" vm_ssh "$w" 'systemctl is-active containerd kubelet kube-proxy'
done
check "etcd answers" vm_ssh server 'sudo /opt/bin/etcdctl endpoint health'

# Chapter 08: the API server is up and RBAC bootstrap ran.
wait_for 120 "API server readyz via the jumpbox" "$kubectl" get --raw /readyz
check "api-server-to-kubelet RBAC exists" "$kubectl" get clusterrole system:kube-apiserver-to-kubelet

# Chapter 09/10: both workers registered and are Ready.
wait_for 180 "both nodes Ready" bash -c "[ \"\$($kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')\" = 2 ]"

# Chapter 06: secrets are encrypted at rest.
"$kubectl" create secret generic kthw-smoke --from-literal=mykey=mydata --dry-run=client -o yaml | "$kubectl" apply -f - >/dev/null 2>&1
if vm_ssh server 'sudo ETCDCTL_API=3 /opt/bin/etcdctl get /registry/secrets/default/kthw-smoke | hexdump -C | grep -q "k8s:enc:aescbc:v1:key1"'; then
    ok "secret is stored encrypted (k8s:enc:aescbc:v1:key1)"
else
    bad "secret is not encrypted at rest"
fi

# Chapter 11 and 12: pods on different nodes, reached across the pod routes.
"$kubectl" delete deploy kthw-web --ignore-not-found >/dev/null 2>&1
"$kubectl" create deployment kthw-web --image=nginx:1.27-alpine --replicas=2 >/dev/null 2>&1
"$kubectl" patch deployment kthw-web --type merge \
    -p '{"spec":{"template":{"spec":{"topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"DoNotSchedule","labelSelector":{"matchLabels":{"app":"kthw-web"}}}]}}}}' >/dev/null 2>&1
wait_for 240 "nginx deployment available (2 replicas)" "$kubectl" wait --for=condition=Available deploy/kthw-web --timeout=3s

ips=$("$kubectl" get pods -l app=kthw-web -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')
nodes_used=$("$kubectl" get pods -l app=kthw-web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l)
if [ "$nodes_used" = 2 ]; then ok "replicas landed on two different nodes"; else bad "replicas did not spread across nodes"; fi
for ip in $ips; do
    # From node-0 and node-1 to every pod IP: proves the networkd pod routes work both ways.
    for w in "${WORKERS[@]}"; do
        check "$w -> pod $ip over the pod routes" vm_ssh "$w" "curl -s --max-time 5 http://$ip | grep -q 'Welcome to nginx'"
    done
done

# Chapter 12: logs and exec go API server -> kubelet, which needs the RBAC from chapter 08.
pod=$("$kubectl" get pods -l app=kthw-web -o jsonpath='{.items[0].metadata.name}')
check "kubectl logs (API server -> kubelet)" "$kubectl" logs "$pod"
check "kubectl exec (API server -> kubelet)" "$kubectl" exec "$pod" -- nginx -v

# Chapter 12: a NodePort service.
"$kubectl" expose deployment kthw-web --port 80 --type NodePort --name kthw-web >/dev/null 2>&1 || true
port=$("$kubectl" get svc kthw-web -o jsonpath='{.spec.ports[0].nodePort}')
for w in "${WORKERS[@]}"; do
    ip=$(grep -E "^$w\b" <("$TOOLS_BIN/nodegen" -inventory "$LAB_DIR/inventory.yaml" -list) | cut -f3)
    check "NodePort $port on $w ($ip)" curl -s --max-time 5 "http://$ip:$port" -o /dev/null
done

"$kubectl" delete deploy,svc kthw-web >/dev/null 2>&1 || true
"$kubectl" delete secret kthw-smoke >/dev/null 2>&1 || true
exit $fail
