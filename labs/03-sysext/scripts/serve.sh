#!/usr/bin/env bash
# Serve out/ over HTTP so the VM can fetch the extension images. In QEMU user-mode
# networking the guest reaches the host's loopback at 10.0.2.2.
#   serve.sh start | stop | status
# shellcheck shell=bash
# shellcheck source=../../lib/common.sh
LAB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_DIR
. "$LAB_DIR/../lib/common.sh"

PORT=${SERVE_PORT:-8089}
state=$(lab_state_dir)
pidfile=$state/serve.pid

running() { [ -s "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; }

case ${1:-} in
start)
    need python3
    [ -d "$LAB_DIR/out" ] || die "run 'make lab03-build' first"
    if running; then
        log "server already running (pid $(cat "$pidfile"))"
        exit 0
    fi
    python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$LAB_DIR/out" >"$state/serve.log" 2>&1 &
    echo $! >"$pidfile"
    sleep 1
    running || die "server failed to start; see $state/serve.log"
    log "serving $LAB_DIR/out on 127.0.0.1:$PORT (guest sees http://10.0.2.2:$PORT/)"
    ;;
stop)
    if running; then
        kill "$(cat "$pidfile")"
        rm -f "$pidfile"
        log "server stopped"
    fi
    ;;
status)
    if running; then echo "running (pid $(cat "$pidfile"))"; else echo stopped; fi
    ;;
*) die "usage: $0 start|stop|status" ;;
esac
