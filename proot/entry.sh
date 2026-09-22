#!/system/bin/sh
# entry.sh — single supervisor for the Ubuntu proot stack: zen-adapter THEN dsh web.
# Contract for Android shell (DshService):
#   sh entry.sh start [autostart] [--force]  — memory gate, start zen, wait /health,
#       start dsh, wait ready, then watchdog loop (foreground; run under nohup/setsid)
#   sh entry.sh stop    — stop watchdog + zen + dsh (idempotent)
#   sh entry.sh status  — "zen running <pid> / stopped" + "dsh running <pid> / stopped"
#   sh entry.sh health  — machine-readable "zen-ok ..."/"zen-fail ..." + "dsh-ok ..."/"dsh-fail ..."
# Logs (ISO timestamps inside guest daemons where possible):
#   dsh/logs/entry.log, dsh/logs/zen.out.log, dsh/logs/dsh.out.log (rotated 5x2MB)
# Env: APP_FILES, DSH_HOST/DSH_PORT, ZEN_HOST/ZEN_PORT, ZEN_API_KEY (secret, never logged),
#   NEXUS_DSH_WEB_MIN_FREE_KB (default 400000), NEXUS_DSH_WEB_HEAP_MB, DSH_TRUSTED_HOST,
#   ZEN_SESSIONS_FILE (default /dsh-home/zen-sessions.json), DSH_ENTRY_GUEST (override).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/proot-common.sh"

RUNDIR="$APP_FILES/dsh/run"
LOGDIR="$APP_FILES/dsh/logs"
ZEN_PIDFILE="$RUNDIR/zen.pid"
DSH_PIDFILE="$RUNDIR/dsh.pid"
ENTRY_PIDFILE="$RUNDIR/entry.pid"
ENTRY_LOG="$LOGDIR/entry.log"
ZEN_LOG="$LOGDIR/zen.out.log"
DSH_LOG="$LOGDIR/dsh.out.log"
MIN_FREE_KB="${NEXUS_DSH_WEB_MIN_FREE_KB:-400000}"

log() { echo "$(iso_now) [entry] $*" | tee -a "$ENTRY_LOG" 2>/dev/null || echo "[entry] $*"; }
die() { log "FATAL: $*"; exit 1; }

ensure_dirs() { mkdir -p "$RUNDIR" "$LOGDIR" "$APP_FILES/dsh-home" "$ROOTFS/dsh-home" 2>/dev/null || mkdir -p "$RUNDIR" "$LOGDIR" "$APP_FILES/dsh-home"; }

memory_gate() {
  _mode="${1:-manual}"
  _force=0; for a in "$@"; do [ "$a" = "--force" ] && _force=1; done
  _free="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)" || _free=""
  if [ "$_force" != 1 ] && [ -n "$_free" ] && [ "$_free" -lt "$MIN_FREE_KB" ]; then
    if [ "$_mode" = "autostart" ]; then log "autostart skipped, low memory (${_free} kB < ${MIN_FREE_KB} kB)"; exit 0; fi
    die "low memory (${_free} kB < ${MIN_FREE_KB} kB). Free RAM or retry with --force"
  fi
}

heap_mb() {
  if [ -n "${NEXUS_DSH_WEB_HEAP_MB:-}" ]; then echo "$NEXUS_DSH_WEB_HEAP_MB"; return; fi
  _free="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null)" || _free=""
  if [ -n "$_free" ]; then
    _h=$((_free / 2048)); [ "$_h" -lt 256 ] && _h=256; [ "$_h" -gt 1024 ] && _h=1024; echo "$_h"
  else echo 512; fi
}

http_code() { # http_code <url> -> code or empty
  if command -v curl >/dev/null 2>&1; then curl -s -m 3 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; fi
}

zen_ok() { [ "$(http_code "http://$ZEN_HOST:$ZEN_PORT/v1/models")" = "200" ]; }
dsh_ok() {
  case "$(http_code "http://$DSH_HOST:$DSH_PORT/")" in [1-5][0-9][0-9]) return 0;; *) return 1;; esac
}

wait_for() { # wait_for <secs> <funcname> <label>
  i=0; while [ "$i" -lt "$1" ]; do if "$2"; then log "$3 ready (${i}s)"; return 0; fi; sleep 1; i=$((i+1)); done
  return 1
}

start_zen() {
  if _p="$(running_pid "$ZEN_PIDFILE")"; then log "zen already running (pid $_p)"; return 0; fi
  check_tree || return 1
  rotate_log "$ZEN_LOG"
  log "starting zen-adapter (guest node) on $ZEN_HOST:$ZEN_PORT ..."
  # Dummy keys must NOT reach upstream: adapter without env key uses its builtin,
  # DSH keeps sending its dummy. Real keys pass through (never logged).
  case "${ZEN_API_KEY:-}" in ""|test|dummy|placeholder|public|none|null|undefined|local|not-needed|adapter|zen|zen-local|zen_local|sk-ant-dummy|x|X*)
    _keymode="builtin"; _keyenv="env -u ZEN_API_KEY" ;;
    *) _keymode="env-provided"; _keyenv="" ;;
  esac
  log "zen key mode: $_keymode (value never logged)"
  # shellcheck disable=SC2086
  nohup sh -c "$(proot_base) $(guest_env) $_keyenv ZEN_SESSIONS_FILE=${ZEN_SESSIONS_FILE:-/dsh-home/zen-sessions.json} node /opt/zen-adapter.mjs --port $ZEN_PORT >>$ZEN_LOG 2>&1" \
    >>"$ZEN_LOG" 2>&1 &
  echo $! > "$ZEN_PIDFILE"
  wait_for "${ZEN_START_TIMEOUT:-30}" zen_ok "zen" || { log "zen-fail: no 200 after timeout — see $ZEN_LOG"; return 1; }
}

start_dsh() {
  if _p="$(running_pid "$DSH_PIDFILE")"; then log "dsh already running (pid $_p)"; return 0; fi
  check_tree || return 1
  rotate_log "$DSH_LOG"
  _heap="$(heap_mb)"
  _entry="${DSH_ENTRY_GUEST:-/opt/node/lib/node_modules/@deepseek-ai/dsh/lib/bin.js}"
  log "starting dsh web on $DSH_HOST:$DSH_PORT (heap cap ${_heap}MB, entry $_entry) ..."
  # HMR web profile REQUIRES node --expose-internals (NODE_OPTIONS cannot carry it).
  # shellcheck disable=SC2086
  nohup sh -c "$(proot_base) $(guest_env) NODE_OPTIONS=\"--max-old-space-size=$_heap\" node --expose-internals $_entry --profile web --host $DSH_HOST --port $DSH_PORT --no-open --trusted-host ${DSH_TRUSTED_HOST:-$DSH_HOST:$DSH_PORT} >>$DSH_LOG 2>&1" \
    >>"$DSH_LOG" 2>&1 &
  echo $! > "$DSH_PIDFILE"
  wait_for "${HEALTHCHECK_TIMEOUT:-90}" dsh_ok "dsh" || { log "dsh NOT ready after timeout — see $DSH_LOG"; return 1; }
  log "ready at http://$DSH_HOST:$DSH_PORT/"
}

watchdog() {
  log "watchdog live (15s poll)"
  _zen_fails=0; _dsh_fails=0
  while true; do
    sleep 15
    if zen_ok; then _zen_fails=0; else _zen_fails=$((_zen_fails+1)); log "zen unhealthy x$_zen_fails"; fi
    if dsh_ok; then _dsh_fails=0; else _dsh_fails=$((_dsh_fails+1)); log "dsh unhealthy x$_dsh_fails"; fi
    if [ "$_zen_fails" -ge 3 ]; then
      log "restarting zen..."; rm -f "$ZEN_PIDFILE"; start_zen || { log "zen restart failed, exiting (Android will restart service)"; exit 1; }; _zen_fails=0
    fi
    if [ "$_dsh_fails" -ge 3 ]; then
      log "restarting dsh..."; rm -f "$DSH_PIDFILE"; start_dsh || { log "dsh restart failed, exiting (Android will restart service)"; exit 1; }; _dsh_fails=0
    fi
  done
}

do_start() {
  ensure_dirs; rotate_log "$ENTRY_LOG"
  if _p="$(running_pid "$ENTRY_PIDFILE")"; then log "entry already supervising (pid $_p)"; return 0; fi
  memory_gate "$@"
  check_tree || die "proot tree not ready (run install.sh)"
  start_zen || die "zen failed to start"
  start_dsh || die "dsh failed to start"
  echo $$ > "$ENTRY_PIDFILE"
  log "supervising (pid $$)"
  watchdog
}

do_stop() {
  for f in "$ENTRY_PIDFILE" "$DSH_PIDFILE" "$ZEN_PIDFILE"; do
    if _p="$(running_pid "$f")"; then kill "$_p" 2>/dev/null || true; sleep 1
      if kill -0 "$_p" 2>/dev/null; then kill -9 "$_p" 2>/dev/null || true; fi
      rm -f "$f"; log "stopped $f (was $_p)"
    else rm -f "$f"; fi
  done
  log "all stopped"
}

do_status() {
  if _p="$(running_pid "$ZEN_PIDFILE")"; then echo "zen running $_p"; else echo "zen stopped"; fi
  if _p="$(running_pid "$DSH_PIDFILE")"; then echo "dsh running $_p"; else echo "dsh stopped"; fi
  if _p="$(running_pid "$ENTRY_PIDFILE")"; then echo "entry supervising $_p"; return 0; else echo "entry idle"; return 1; fi
}

do_health() {
  if zen_ok; then echo "zen-ok http://$ZEN_HOST:$ZEN_PORT/v1/models"; else echo "zen-fail http://$ZEN_HOST:$ZEN_PORT/v1/models"; fi
  if dsh_ok; then echo "dsh-ok http://$DSH_HOST:$DSH_PORT/"; return 0; else echo "dsh-fail http://$DSH_HOST:$DSH_PORT/"; return 1; fi
}

case "${1:-status}" in
  start) shift; do_start "$@";;
  stop) do_stop;;
  status) do_status;;
  health) do_health;;
  *) echo "usage: entry.sh {start [autostart] [--force]|stop|status|health}" >&2; exit 1;;
esac
