#!/usr/bin/env bash
# Check every rendered Butane config under build/:
#  1. transpile with the pinned Butane binary (--strict), failing on any warning;
#  2. where nodegen already produced <name>.ign (library path), require byte-identical
#     output to the binary, proving both paths agree;
#  3. run butanecheck policy checks.
# Per-lab policy flags can be placed in build/<lab>/butanecheck.flags (one line).
# shellcheck shell=bash
# shellcheck source=../../labs/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../labs/lib/common.sh"

butane=$TOOLS_BIN/butane
check=$TOOLS_BIN/butanecheck
[ -x "$butane" ] || die "run 'make butane' first"
[ -x "$check" ] || die "run 'make tools' first"

[ "$("$butane" --version)" = "Butane $BUTANE_VERSION" ] || die "unexpected butane version: $("$butane" --version)"

fail=0
count=0
while IFS= read -r -d '' bu; do
    count=$((count + 1))
    dir=$(dirname "$bu")
    base=${bu%.bu}
    rel=${bu#"$REPO_ROOT"/}

    if ! "$butane" --strict --pretty --files-dir "$dir" "$bu" >"$base.bin.ign" 2>"$base.bin.err"; then
        log "FAIL transpile: $rel"
        sed 's/^/    /' "$base.bin.err" >&2
        fail=1
        continue
    fi
    if [ -f "$base.ign" ] && ! cmp -s "$base.ign" "$base.bin.ign"; then
        log "FAIL library and binary outputs differ: $rel"
        diff <(cat "$base.ign") <(cat "$base.bin.ign") | head -10 >&2 || true
        fail=1
        continue
    fi

    flags=()
    if [ -f "$dir/butanecheck.flags" ]; then
        # shellcheck disable=SC2207
        flags=($(cat "$dir/butanecheck.flags"))
    fi
    if "$check" --variant "$BUTANE_VARIANT" --version "$BUTANE_SPEC_VERSION" "${flags[@]}" "$bu" >"$base.check" 2>&1; then
        log "ok   $rel"
    else
        log "FAIL policy: $rel"
        sed 's/^/    /' "$base.check" >&2
        fail=1
    fi
done < <(find "$REPO_ROOT/build" -name '*.bu' -print0 2>/dev/null | sort -z)

[ "$count" -gt 0 ] || die "no rendered configs found under build/; run 'make render-ci' first"
log "checked $count config(s)"
exit "$fail"
