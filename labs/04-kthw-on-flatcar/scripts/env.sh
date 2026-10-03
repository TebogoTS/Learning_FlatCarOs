#!/usr/bin/env bash
# Shared settings for the lab 04 scripts. Source this file; do not execute it.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are used by the scripts that source this file
# shellcheck source=../../lib/common.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/common.sh"

# STATE holds everything generated: downloaded binaries, PKI, kubeconfigs, rendered
# configs and VM overlays. Tests point it somewhere else with LAB04_STATE.
STATE=${LAB04_STATE:-$(lab_state_dir)}
ART=$STATE/artifacts
PKI=$STATE/pki
KCFG=$STATE/kubeconfigs
RENDER=$STATE/render
mkdir -p "$ART" "$PKI" "$KCFG" "$RENDER"

K8S_BASE_URL=https://dl.k8s.io/$K8S_VERSION/bin/linux/amd64
CNI_URL=https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS_VERSION/cni-plugins-linux-amd64-$CNI_PLUGINS_VERSION.tgz
ETCD_URL=https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-amd64.tar.gz

API_IP=10.77.0.10
API_PORT=6443
WORKERS=(node-0 node-1)
SERVE_PORT=${SERVE_PORT:-8080}
