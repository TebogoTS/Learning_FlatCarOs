#!/usr/bin/env bash
# Fetch and verify Flatcar QEMU base images. Source this file; do not execute it.
# shellcheck shell=bash
# shellcheck source=common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# image_base_url VERSION [CHANNEL]
image_base_url() {
    local version=$1 channel=${2:-$FLATCAR_CHANNEL}
    printf '%s\n' "${FLATCAR_IMAGE_BASE_URL:-https://${channel}.release.flatcar-linux.net/${FLATCAR_BOARD}}/${version}"
}

# image_import_signing_key GNUPGHOME: import the Flatcar image signing key into a private
# keyring, taking it from the pinned copy of flatcar-install and checking the primary-key
# fingerprint against FLATCAR_SIGNING_KEY_FPR before trusting it.
image_import_signing_key() {
    local gnupghome=$1 script keyfile fpr
    need gpg curl awk sed
    script=$CACHE_DIR/flatcar-install
    mkdir -p "$CACHE_DIR"
    [ -s "$script" ] || download "$FLATCAR_INSTALL_URL" "$script"
    keyfile=$gnupghome/flatcar-image-signing-key.asc
    awk '/^GPG_KEY="-----BEGIN PGP PUBLIC KEY BLOCK-----/{p=1; sub(/^GPG_KEY="/,"")} p{print} /^-----END PGP PUBLIC KEY BLOCK-----"/{exit}' "$script" |
        sed 's/"$//' >"$keyfile"
    [ -s "$keyfile" ] || die "could not extract the signing key from $script"
    GNUPGHOME=$gnupghome gpg --batch --quiet --import "$keyfile" 2>/dev/null
    fpr=$(GNUPGHOME=$gnupghome gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    [ "$fpr" = "$FLATCAR_SIGNING_KEY_FPR" ] ||
        die "signing key fingerprint is $fpr, expected $FLATCAR_SIGNING_KEY_FPR"
}

# image_fetch VERSION [CHANNEL]: download the QEMU image for a release, verify its
# signature, and print the path. Result is cached under $CACHE_DIR/flatcar/VERSION/.
image_fetch() {
    local version=$1 channel=${2:-$FLATCAR_CHANNEL} dir base img gh
    need curl gpg
    dir=$CACHE_DIR/flatcar/$version
    img=$dir/flatcar_production_qemu_image.img
    if [ -s "$img" ] && [ -f "$dir/.verified" ]; then
        printf '%s\n' "$img"
        return
    fi
    mkdir -p "$dir"
    base=$(image_base_url "$version" "$channel")
    log "downloading $base/flatcar_production_qemu_image.img"
    download "$base/flatcar_production_qemu_image.img" "$img"
    download "$base/flatcar_production_qemu_image.img.sig" "$img.sig"
    gh=$(mktemp -d)
    chmod 700 "$gh"
    # shellcheck disable=SC2064
    trap "rm -rf '$gh'" RETURN
    image_import_signing_key "$gh"
    if ! GNUPGHOME=$gh gpg --batch --verify "$img.sig" "$img" 2>"$dir/gpg.log"; then
        cat "$dir/gpg.log" >&2
        rm -f "$img"
        die "signature verification FAILED for $version; the image was deleted"
    fi
    date -u +%FT%TZ >"$dir/.verified"
    log "image $version verified against signing key $FLATCAR_SIGNING_KEY_FPR"
    printf '%s\n' "$img"
}
