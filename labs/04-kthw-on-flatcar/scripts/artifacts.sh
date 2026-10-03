#!/usr/bin/env bash
# KTHW chapter 02 (the jumpbox): download the binaries once, verify each against the
# checksum the upstream project publishes, and lay them out as the files the VMs will fetch.
#   artifacts.sh            download and verify (needs network)
#   artifacts.sh --fixture  create tiny stand-in files so configs can be rendered offline (CI only)
# shellcheck shell=bash
# shellcheck source=env.sh
. "$(dirname "${BASH_SOURCE[0]}")/env.sh"

K8S_BINS=(kube-apiserver kube-controller-manager kube-scheduler kube-proxy kubelet kubectl)
CNI_PLUGINS=(bridge host-local loopback)
ETCD_BINS=(etcd etcdctl)

fixture() {
    local f
    for f in "${K8S_BINS[@]}" "${CNI_PLUGINS[@]}" "${ETCD_BINS[@]}"; do
        printf 'fixture %s\n' "$f" >"$ART/$f"
    done
}

# fetch_verified URL DEST EXPECTED_SHA256
fetch_verified() {
    local url=$1 dest=$2 want=$3 got
    if [ -s "$dest" ] && [ "$(sha256_of "$dest")" = "$want" ]; then
        return
    fi
    download "$url" "$dest"
    got=$(sha256_of "$dest")
    [ "$got" = "$want" ] || {
        rm -f "$dest"
        die "checksum mismatch for $url: got $got, upstream says $want"
    }
}

real() {
    need curl tar sha256sum
    local b want dl=$STATE/downloads
    mkdir -p "$dl"

    for b in "${K8S_BINS[@]}"; do
        # dl.k8s.io publishes <binary>.sha256 containing only the hex digest.
        want=$(curl -fsSL --retry 3 "$K8S_BASE_URL/$b.sha256" | tr -d '[:space:]')
        [[ $want =~ ^[0-9a-f]{64}$ ]] || die "unexpected checksum file for $b: '$want'"
        fetch_verified "$K8S_BASE_URL/$b" "$ART/$b" "$want"
        chmod 0755 "$ART/$b"
        log "ok $b ($K8S_VERSION)"
    done

    # CNI plugins: the release ships <tarball>.sha256 in "digest  filename" form.
    local cni=$dl/cni-plugins.tgz
    want=$(curl -fsSL --retry 3 "$CNI_URL.sha256" | awk '{print $1}')
    [[ $want =~ ^[0-9a-f]{64}$ ]] || die "unexpected CNI checksum file"
    fetch_verified "$CNI_URL" "$cni" "$want"
    for b in "${CNI_PLUGINS[@]}"; do
        tar -xzf "$cni" -C "$ART" "./$b"
        chmod 0755 "$ART/$b"
    done
    log "ok cni plugins ($CNI_PLUGINS_VERSION): ${CNI_PLUGINS[*]}"

    # etcd: SHA256SUMS lists every platform archive.
    local etcd_tgz=$dl/etcd.tar.gz etcd_dir=etcd-$ETCD_VERSION-linux-amd64
    want=$(curl -fsSL --retry 3 "${ETCD_URL%/*}/SHA256SUMS" | awk -v f="etcd-$ETCD_VERSION-linux-amd64.tar.gz" '$2==f{print $1}')
    [[ $want =~ ^[0-9a-f]{64}$ ]] || die "etcd archive not found in SHA256SUMS"
    fetch_verified "$ETCD_URL" "$etcd_tgz" "$want"
    for b in "${ETCD_BINS[@]}"; do
        tar -xzf "$etcd_tgz" -C "$ART" --strip-components=1 "$etcd_dir/$b"
        chmod 0755 "$ART/$b"
    done
    log "ok etcd ($ETCD_VERSION): ${ETCD_BINS[*]}"

    log "artifacts ready in $ART"
}

case ${1:-} in
--fixture) fixture ;;
"") real ;;
*) die "usage: $0 [--fixture]" ;;
esac
