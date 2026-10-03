#!/usr/bin/env bash
# Build the flatcar-hello system extension image: a squashfs containing a static Go binary,
# a systemd unit started through an Upholds= drop-in (works the same before and after the
# initrd-sysext change in Flatcar 4628+), and the extension-release metadata.
#   build-sysext.sh TAG            e.g. v1 -> out/flatcar-hello-v1.raw
# Needs: go, mksquashfs (squashfs-tools). Output is reproducible modulo file mtimes: we fix
# them to the epoch below so identical inputs give an identical image hash.
# shellcheck shell=bash
# shellcheck source=../../lib/common.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/common.sh"

tag=${1:?usage: build-sysext.sh TAG}
need go mksquashfs unsquashfs
name=flatcar-hello
out=$LAB_DIR/out
tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT
mkdir -p "$out"

install -d "$tree/usr/bin" \
    "$tree/usr/lib/extension-release.d" \
    "$tree/usr/lib/systemd/system/multi-user.target.d"

(cd "$REPO_ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
    -ldflags "-s -w -X main.version=$tag" \
    -o "$tree/usr/bin/$name" ./labs/03-sysext/hello)

# SYSEXT_LEVEL (not VERSION_ID) because the binary is static and does not depend on Flatcar's
# libraries. Use VERSION_ID=<os version> instead if you link against the OS.
cat >"$tree/usr/lib/extension-release.d/extension-release.$name" <<REL
ID=flatcar
SYSEXT_LEVEL=1.0
REL

cat >"$tree/usr/lib/systemd/system/$name.service" <<'UNIT'
[Unit]
Description=flatcar-hello HTTP endpoint (lab 03 system extension payload)
After=network.target

[Service]
ExecStart=/usr/bin/flatcar-hello -serve 127.0.0.1:8088
Restart=on-failure
DynamicUser=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
UNIT

# Start the unit when the extension is merged. Upholds= (rather than a .wants symlink) is what
# the Flatcar docs and the bakery recommend: it also works when the extension is refreshed live.
cat >"$tree/usr/lib/systemd/system/multi-user.target.d/10-$name.conf" <<DROPIN
[Unit]
Upholds=$name.service
DROPIN

# Normalise mtimes and ownership for a reproducible image.
find "$tree" -exec touch -h -d @0 {} +
img=$out/$name-$tag.raw
rm -f "$img"
mksquashfs "$tree" "$img" -all-root -noappend -no-progress -quiet -mkfs-time 0 -all-time 0 >/dev/null

log "built $img ($(wc -c <"$img") bytes), sha256 $(sha256_of "$img")"
unsquashfs -ll "$img" | sed -n '1,40p' >&2
( cd "$out" && sha256sum "$name"-*.raw >SHA256SUMS )
