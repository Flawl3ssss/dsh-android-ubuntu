#!/system/bin/sh
# launch-dsh.sh — run dsh web inside proot. Contract for Android shell (DshService):
#   sh launch-dsh.sh start   — full stack via entry.sh (zen first, then dsh)
#   sh launch-dsh.sh stop    — stop stack via entry.sh
#   sh launch-dsh.sh status  — stack status via entry.sh
#   sh launch-dsh.sh exec -- <cmd...> — one-shot command inside the guest (used by install.sh)
#   sh launch-dsh.sh kill-terminal — idempotent: kill guest PTY shells, dsh web survives
# WebView waits for: healthcheck.sh --wait 60  (then loads http://127.0.0.1:8081/)
# NEVER invokes /usr/bin/proot — only: /system/bin/linker64 <libdir>/libproot.so
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/proot-common.sh"

LOGDIR="$APP_FILES/dsh/logs"
LOGFILE="$LOGDIR/dsh.out.log"

log() { echo "[launch-dsh] $*"; }
die() { echo "[launch-dsh] FATAL: $*" >&2; exit 1; }

ensure_dirs() { mkdir -p "$APP_FILES/dsh/run" "$LOGDIR" "$APP_FILES/dsh-home" "$ROOTFS/dsh-home" 2>/dev/null || mkdir -p "$APP_FILES/dsh/run" "$LOGDIR" "$APP_FILES/dsh-home"; }

do_exec() {
  check_tree; ensure_dirs
  shift # drop 'exec'
  [ "${1:-}" = "--" ] && shift
  # NOTE: "$@" is intentionally flattened — exec is for simple install-time commands.
  # shellcheck disable=SC2086,SC2048
  exec sh -c "$(proot_base) $(guest_env) $*"
}


do_exec_npm() {
  check_tree; ensure_dirs
  shift # drop exec-npm
  if [ "${1:-}" = "--" ]; then shift; fi
  env -u PREFIX PATH="$(npm_guest_path):$PATH" HOME=/root sh -c "$(proot_base) $*"
}

do_kill_terminal() {
  # Kill-switch: terminate guest PTY shells started by dsh-terminal-bash (/bin/bash
  # in guest). dsh web itself runs under node and is NOT matched. Idempotent: exit 0.
  check_tree; ensure_dirs
  # shellcheck disable=SC2086
  sh -c "$(proot_base) $(guest_env) pkill -f '/bin/bash' || true" >>"$LOGFILE" 2>&1 || true
  echo "[launch-dsh] terminal-kill $(date -u +%FT%TZ 2>/dev/null || date)" >>"$LOGFILE" 2>&1 || true
  log "terminal sessions killed (marker appended)"
}

case "${1:-status}" in
  start) shift; exec sh "$HERE/entry.sh" start "$@";;
  stop) exec sh "$HERE/entry.sh" stop;;
  status) exec sh "$HERE/entry.sh" status;;
  health) exec sh "$HERE/entry.sh" health;;
  exec) do_exec "$@";;
  exec-npm) do_exec_npm "$@";;
  kill-terminal) do_kill_terminal;;
  *) die "usage: launch-dsh.sh {start|stop|status|health|exec [--] <cmd>|exec-npm [--] <cmd>|kill-terminal}";;
esac
