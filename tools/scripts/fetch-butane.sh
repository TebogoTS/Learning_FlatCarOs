#!/usr/bin/env bash
# Download the pinned Butane release binary and verify its SHA-256 (pinned in versions.env).
# The hash was recorded on first download during authoring; the release also publishes a
# detached signature, which you should verify independently (see VERSIONS.md).
# shellcheck shell=bash
# shellcheck source=../../labs/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../labs/lib/common.sh"

need curl
dest=$TOOLS_BIN/butane
mkdir -p "$TOOLS_BIN"
if [ -x "$dest" ] && [ "$(sha256_of "$dest")" = "$BUTANE_SHA256" ]; then
    log "butane $BUTANE_VERSION already present and verified"
    exit 0
fi
url=https://github.com/coreos/butane/releases/download/v${BUTANE_VERSION}/butane-x86_64-unknown-linux-gnu
log "downloading $url"
tmp=$(mktemp "$dest.XXXXXX")
curl -fsSL --retry 3 -o "$tmp" "$url" || {
    rm -f "$tmp"
    die "download failed"
}
got=$(sha256_of "$tmp")
if [ "$got" != "$BUTANE_SHA256" ]; then
    rm -f "$tmp"
    die "checksum mismatch for butane $BUTANE_VERSION: got $got, expected $BUTANE_SHA256"
fi
chmod +x "$tmp"
mv "$tmp" "$dest"
log "butane $BUTANE_VERSION installed and verified: $("$dest" --version)"
