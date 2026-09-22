#!/system/bin/sh
# launch-zen.sh — Zen sidecar launcher (OpenAI-compatible LLM proxy for DSH).
# Owner: logs-qa (task-8). Binding point: DSH-INTERNALS.md section 5.
#
#   sh launch-zen.sh start   — start daemon (idempotent), requires ZEN_API_KEY in env
#   sh launch-zen.sh stop    — stop daemon
#   sh launch-zen.sh status  — prints "running <pid>" / "stopped" (+ exit code)
#   sh launch-zen.sh health  — probes GET /v1/models, prints "zen-ok ..." / "zen-fail ..."
#
# Contract:
#   listens: 127.0.0.1:8787 (env ZEN_HOST/ZEN_PORT), OpenAI-compatible base URL
#            http://127.0.0.1:8787/v1  (DSH: llm-deepseek.baseURL + apiKeyEnv)
#   secret:  ZEN_API_KEY comes ONLY from the process environment — DshService
#            injects it from EncryptedSharedPrefs at start time. NEVER written to
#            any file, never echoed to any log (fail-closed when empty).
#   badge:   health == GET $ZEN_BASE_URL/models returns HTTP 200 => "zen-ok",
#            anything else => "zen-fail" (Diagnostics screen polls `health`).
# NEVER invokes /usr/bin/proot (broken libtalloc, see ADR-proot section 1).
# Zen runs as a HOST-side loopback process, not inside the proot guest: the DSH
# guest reaches it over 127.0.0.1 exactly like the local dev setup does.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_FILES="${APP_FILES:-$HERE}"
if [ ! -d "$APP_FILES/dsh" ] && [ -d "$HERE/../dsh" ]; then
  APP_FILES="$(cd "$HERE/.." && pwd)"
fi

RUNDIR="$APP_FILES/dsh/run"
LOGDIR="$APP_FILES/dsh/logs"
PIDFILE="$RUNDIR/zen.pid"
LOGFILE="$LOGDIR/zen.out.log"

ZEN_HOST="${ZEN_HOST:-127.0.0.1}"
ZEN_PORT="${ZEN_PORT:-8787}"
ZEN_BASE_URL="${ZEN_BASE_URL:-http://$ZEN_HOST:$ZEN_PORT/v1}"
# Binary/args are overridable for vendor ROMs; default matches the sidecar name.
ZEN_BIN="${ZEN_BIN:-zen}"
ZEN_ARGS="${ZEN_ARGS:---listen $ZEN_HOST:$ZEN_PORT}"
ZEN_MODEL="${ZEN_MODEL:-muse-spark-1.3-contributor-free}"

log() { echo "[launch-zen] $*"; }
die() { echo "[launch-zen] FATAL: $*" >&2; exit 1; }

# Secret guard: log only PRESENCE (length class), never the value.
check_key() {
  if [ -z "${ZEN_API_KEY:-}" ]; then
    die "ZEN_API_KEY is empty — DshService must export it from EncryptedSharedPrefs before start (refusing to launch without a key)"
  fi
  log "ZEN_API_KEY present (len>=1, value never logged)"
}

ensure_dirs() { mkdir -p "$RUNDIR" "$LOGDIR"; }

running_pid() {
  [ -f "$PIDFILE" ] || return 1
  PID="$(cat "$PIDFILE" 2>/dev/null)" || return 1
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || return 1
  echo "$PID"
}

one_check() {
  # "ok" = the sidecar answers GET /v1/models with HTTP 200.
  # No Authorization header is sent: the loopback sidecar trusts local clients;
  # the real key travels only DSH-process -> sidecar on chat calls, never here.
  if command -v curl >/dev/null 2>&1; then
    CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$ZEN_BASE_URL/models" 2>/dev/null)" || return 1
    [ "$CODE" = "200" ] && return 0 || return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O /dev/null "$ZEN_BASE_URL/models" 2>/dev/null && return 0 || return 1
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$ZEN_HOST" "$ZEN_PORT" 2>/dev/null && return 0 || return 1
  fi
  return 1
}

do_start() {
  check_key; ensure_dirs
  if PID="$(running_pid)"; then log "already running (pid $PID)"; return 0; fi
  command -v "$ZEN_BIN" >/dev/null 2>&1 || die "zen binary not found: $ZEN_BIN (override with ZEN_BIN=/path/to/zen)"
  # Daemonize with nohup; stdout+stderr appended to zen.out.log.
  # NOTE: the environment (incl. ZEN_API_KEY) is inherited, never persisted.
  # shellcheck disable=SC2086
  nohup "$ZEN_BIN" $ZEN_ARGS >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  log "started (pid $(cat "$PIDFILE")), log: $LOGFILE"
  log "waiting for $ZEN_BASE_URL/models ..."
  i=0
  while [ "$i" -lt "${ZEN_START_TIMEOUT:-30}" ]; do
    if one_check; then log "zen-ok $ZEN_BASE_URL (model $ZEN_MODEL)"; return 0; fi
    sleep 1
    i=$((i + 1))
  done
  log "zen-fail: no 200 from $ZEN_BASE_URL/models after ${ZEN_START_TIMEOUT:-30}s — see $LOGFILE"
  return 1
}

do_stop() {
  if PID="$(running_pid)"; then
    kill "$PID" 2>/dev/null || true
    sleep 2
    if kill -0 "$PID" 2>/dev/null; then kill -9 "$PID" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
    log "stopped"
  else
    rm -f "$PIDFILE"
    log "already stopped"
  fi
}

do_status() {
  if PID="$(running_pid)"; then echo "running $PID"; return 0; else echo "stopped"; return 1; fi
}

do_health() {
  # Machine-readable for the Diagnostics badge; exit code mirrors the badge.
  if one_check; then
    echo "zen-ok $ZEN_BASE_URL/models"
    return 0
  else
    echo "zen-fail $ZEN_BASE_URL/models"
    return 1
  fi
}

case "${1:-status}" in
  start) do_start;;
  stop) do_stop;;
  status) do_status;;
  health) do_health;;
  *) die "usage: launch-zen.sh {start|stop|status|health}";;
esac
