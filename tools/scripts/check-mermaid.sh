#!/usr/bin/env bash
# Parse-check every Mermaid diagram: each ```mermaid block in docs/*.md and each docs/diagrams/*.mmd.
# Renders with @mermaid-js/mermaid-cli, which needs Node and a Chromium. Optional: not part of
# `make validate` because of that dependency.
#   MMDC=path/to/mmdc  CHROME=/path/to/chromium  tools/scripts/check-mermaid.sh
# Without MMDC, it installs the pinned CLI into .cache/mermaid (needs npm and network).
# shellcheck shell=bash
# shellcheck source=../../labs/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../labs/lib/common.sh"
need node npm python3

MERMAID_CLI_VERSION=12.0.0
work=$CACHE_DIR/mermaid
mkdir -p "$work/out"
mmdc=${MMDC:-$work/node_modules/.bin/mmdc}
if [ ! -x "$mmdc" ]; then
    log "installing @mermaid-js/mermaid-cli@$MERMAID_CLI_VERSION into $work"
    (cd "$work" && PUPPETEER_SKIP_DOWNLOAD=1 npm install --silent "@mermaid-js/mermaid-cli@$MERMAID_CLI_VERSION")
fi
chrome=${CHROME:-}
if [ -z "$chrome" ]; then
    for c in /opt/pw-browsers/chromium chromium chromium-browser google-chrome; do
        if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then chrome=$c; break; fi
    done
fi
[ -n "$chrome" ] || die "no Chromium found; set CHROME=/path/to/chromium"
printf '{"executablePath":"%s","args":["--no-sandbox","--disable-gpu"]}\n' "$(command -v "$chrome" || echo "$chrome")" >"$work/puppeteer.json"

rm -f "$work"/out/*
(cd "$REPO_ROOT" && python3 - "$work/out" <<'PY'
import glob, os, re, sys
out = sys.argv[1]
for f in sorted(glob.glob("docs/*.md")):
    for i, m in enumerate(re.finditer(r"```mermaid\n(.*?)```", open(f).read(), re.S)):
        open(f"{out}/{os.path.basename(f)[:-3]}-{i}.mmd", "w").write(m.group(1))
for f in sorted(glob.glob("docs/diagrams/*.mmd")):
    open(f"{out}/diagram-{os.path.basename(f)}", "w").write(open(f).read())
PY
)

fail=0
for f in "$work"/out/*.mmd; do
    if timeout 120 "$mmdc" -p "$work/puppeteer.json" -i "$f" -o "${f%.mmd}.svg" >/dev/null 2>"${f%.mmd}.err"; then
        log "ok   $(basename "$f")"
    else
        log "FAIL $(basename "$f")"
        sed 's/^/    /' "${f%.mmd}.err" | head -8 >&2
        fail=1
    fi
done
exit $fail
