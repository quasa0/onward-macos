#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$HOME/Applications/Onward.app"
RUNTIME="$PWD/.runtime"
mkdir -p "$RUNTIME"
PIDFILE="$RUNTIME/onward.pid"
LOG="$RUNTIME/onward.log"
find_pid() {
  ps -axo pid=,comm= | awk -v executable="$APP/Contents/MacOS/Onward" '$2 == executable && !found {print $1; found=1}'
}
stop_app() {
  local pid
  pid=$(find_pid)
  if [ -n "$pid" ]; then
    kill -TERM "$pid"
    for attempt in {1..30}; do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then printf 'Onward did not exit (PID %s).\n' "$pid" >&2; exit 1; fi
  fi
  rm -f "$PIDFILE"
}
case "${1:-status}" in
  start|start-background)
    stop_app
    test -x "$APP/Contents/MacOS/Onward"
    if [ "${1}" = "start-background" ]; then
      args=(--background)
      if [ "${2:-}" = "--resume" ]; then args+=(--resume); fi
      /usr/bin/open -g -n "$APP" --stdout "$LOG" --stderr "$LOG" --args "${args[@]}"
    else
      /usr/bin/open -n "$APP" --stdout "$LOG" --stderr "$LOG"
    fi
    for attempt in {1..50}; do
      pid=$(find_pid)
      observer_pid=$(/usr/bin/plutil -extract observerPID raw -o - "$HOME/Library/Application Support/Onward/observer-status.json" 2>/dev/null || true)
      if [ -n "$pid" ] && [ "$observer_pid" = "$pid" ]; then printf '%s\n' "$pid" > "$PIDFILE"; printf 'Onward PID %s; log %s\n' "$pid" "$LOG"; exit 0; fi
      sleep 0.1
    done
    printf 'Onward failed to launch; see %s\n' "$LOG" >&2; exit 1 ;;
  stop) stop_app; printf 'Onward stopped.\n' ;;
  status) pid=$(find_pid); printf 'PID: %s\nLog: %s\n' "${pid:-not running}" "$LOG" ;;
  *) printf 'Usage: %s start|start-background [--resume]|stop|status\n' "$0" >&2; exit 1 ;;
esac
