#!/usr/bin/env bash
# KTHW chapters 04, 05 and 06: certificate authority and certificates (openssl), kubeconfigs,
# and the data-encryption key. Output goes to $STATE/{pki,kubeconfigs}; nothing is committed.
#   pki.sh            generate whatever is missing (idempotent)
#   pki.sh --force    regenerate everything
# shellcheck shell=bash
# shellcheck source=env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"
need openssl base64

force=0
[ "${1:-}" = "--force" ] && force=1
conf=$LAB_DIR/config/ca.conf

certs=(admin node-0 node-1 kube-proxy kube-scheduler kube-controller-manager kube-api-server service-accounts)

gen_ca() {
    if [ -s "$PKI/ca.crt" ] && [ $force = 0 ]; then return; fi
    openssl genrsa -out "$PKI/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -sha512 -noenc -key "$PKI/ca.key" -days 3653 \
        -config "$conf" -out "$PKI/ca.crt"
    log "created CA"
}

gen_cert() {
    local c=$1
    if [ -s "$PKI/$c.crt" ] && [ $force = 0 ]; then return; fi
    openssl genrsa -out "$PKI/$c.key" 4096 2>/dev/null
    openssl req -new -key "$PKI/$c.key" -sha256 -config "$conf" -section "$c" -out "$PKI/$c.csr"
    openssl x509 -req -days 3653 -in "$PKI/$c.csr" -copy_extensions copyall -sha256 \
        -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -out "$PKI/$c.crt" 2>/dev/null
    log "issued $c"
}

# kubeconfig NAME USER SERVER: write a kubeconfig with embedded credentials, the same
# structure `kubectl config set-cluster/set-credentials/set-context` produces.
kubeconfig() {
    local name=$1 user=$2 server=$3 out=$KCFG/$1.kubeconfig
    if [ -s "$out" ] && [ $force = 0 ]; then return; fi
    cat >"$out" <<KC
apiVersion: v1
kind: Config
clusters:
  - name: kubernetes-the-hard-way
    cluster:
      certificate-authority-data: $(base64 -w0 "$PKI/ca.crt")
      server: $server
users:
  - name: $user
    user:
      client-certificate-data: $(base64 -w0 "$PKI/$name.crt")
      client-key-data: $(base64 -w0 "$PKI/$name.key")
contexts:
  - name: default
    context:
      cluster: kubernetes-the-hard-way
      user: $user
current-context: default
KC
    chmod 0600 "$out"
}

gen_ca
for c in "${certs[@]}"; do gen_cert "$c"; done
chmod 0600 "$PKI"/*.key

# KTHW chapter 05: each component talks to the API server it can reach. Controller manager,
# scheduler and admin use the loopback address because they run on the server; kubelets and
# kube-proxy use the server's lab address.
remote=https://$API_IP:$API_PORT
local_api=https://127.0.0.1:$API_PORT
for w in "${WORKERS[@]}"; do kubeconfig "$w" "system:node:$w" "$remote"; done
kubeconfig kube-proxy system:kube-proxy "$remote"
kubeconfig kube-controller-manager system:kube-controller-manager "$local_api"
kubeconfig kube-scheduler system:kube-scheduler "$local_api"
kubeconfig admin admin "$local_api"
# For use from the jumpbox (chapter 10).
if [ ! -s "$KCFG/admin-remote.kubeconfig" ] || [ $force = 1 ]; then
    sed "s#$local_api#$remote#" "$KCFG/admin.kubeconfig" >"$KCFG/admin-remote.kubeconfig"
    chmod 0600 "$KCFG/admin-remote.kubeconfig"
fi

# KTHW chapter 06: a fresh 32-byte AES key for secrets encryption at rest.
enc=$STATE/encryption-config.yaml
if [ ! -s "$enc" ] || [ $force = 1 ]; then
    key=$(head -c 32 /dev/urandom | base64 -w0)
    sed "s#\${ENCRYPTION_KEY}#$key#" "$LAB_DIR/config/encryption-config.yaml" >"$enc"
    chmod 0600 "$enc"
    log "created encryption config"
fi
log "PKI, kubeconfigs and encryption config ready in $STATE"
