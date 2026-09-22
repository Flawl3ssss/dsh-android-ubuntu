#!/system/bin/sh
# launch-dsh.sh — run dsh web inside proot. Contract for Android shell (DshService):
#   sh launch-dsh.sh start   — start daemon (idempotent), writes pidfile, logs to dsh.out.log
#   sh launch-dsh.sh stop    — stop daemon
#   sh launch-dsh.sh status  — prints "running <pid>" / "stopped" (+ exit code)
#   sh launch-dsh.sh exec -- <cmd...> — one-shot command inside the guest (used by install.sh)
#   sh launch-dsh.sh kill-terminal — idempotent: kill guest PTY shells, dsh web survives
#     (contract android-shell/task-2: DshService exports DSH_TRUSTED_HOST; KILL-SWITCH.md)
# WebView waits for: healthcheck.sh --wait 60  (then loads http://127.0.0.1:8081/)
# NEVER invokes /usr/bin/proot — only: /system/bin/linker64 <libdir>/libproot.so
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_FILES="${APP_FILES:-$HERE}"
if [ ! -d "$APP_FILES/proot/rootfs" ] && [ ! -L "$APP_FILES/proot/current" ] && [ -d "$HERE/rootfs" ]; then
  APP_FILES="$HERE"
fi

LIBDIR="$APP_FILES/proot/lib"
# A/B-ready: prefer update-guard's 'current' symlink when present
if [ -L "$APP_FILES/proot/current" ]; then ROOTFS="$(readlink -f "$APP_FILES/proot/current")"; else ROOTFS="$APP_FILES/proot/rootfs"; fi
RUNDIR="$APP_FILES/dsh/run"
LOGDIR="$APP_FILES/dsh/logs"
PIDFILE="$RUNDIR/dsh.pid"
LOGFILE="$LOGDIR/dsh.out.log"
LINKER="${LINKER:-/system/bin/linker64}"

DSH_PORT="${DSH_PORT:-8081}"
DSH_HOST="${DSH_HOST:-127.0.0.1}"

log() { echo "[launch-dsh] $*"; }
die() { echo "[launch-dsh] FATAL: $*" >&2; exit 1; }

check_tree() {
  [ -e "$LINKER" ] || die "linker not found: $LINKER"
  [ -f "$LIBDIR/libproot.so" ] || die "libproot.so missing in $LIBDIR (run install.sh with APK_PATH)"
  { [ -d "$ROOTFS/bin" ] || [ -d "$ROOTFS/usr/bin" ]; } || die "rootfs not unpacked at $ROOTFS (run install.sh)"
}

# Optional binds: only added when the host dir exists+readable (scoped-storage safe).
extra_binds() {
  B=""
  if [ -r /sdcard/Download ]; then B="$B -b /sdcard/Download:/phone/Download"; fi
  if [ -r /sdcard/DCIM ]; then B="$B -b /sdcard/DCIM:/phone/DCIM"; fi
  echo "$B"
}

proot_base() {
  # echoes the base proot invocation (no guest command); caller appends.
  echo "$LINKER $LIBDIR/libproot.so -r $ROOTFS -0 -w /root -b /dev -b /proc -b /sys$(extra_binds) -b $APP_FILES/dsh-home:/dsh-home"
}

guest_env() {
  # hermetic guest env; DSH_HOME lives on the bind-mounted host dir.
  echo "env -i HOME=/root USER=root TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 DSH_HOME=/dsh-home PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

ensure_dirs() { mkdir -p "$RUNDIR" "$LOGDIR" "$APP_FILES/dsh-home" "$ROOTFS/dsh-home" 2>/dev/null || mkdir -p "$RUNDIR" "$LOGDIR" "$APP_FILES/dsh-home"; }

running_pid() {
  [ -f "$PIDFILE" ] || return 1
  PID="$(cat "$PIDFILE" 2>/dev/null)" || return 1
  [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || return 1
  echo "$PID"
}

do_start() {
  check_tree; ensure_dirs
  if PID="$(running_pid)"; then log "already running (pid $PID)"; return 0; fi
  # shellcheck disable=SC2086
  nohup sh -c "$(proot_base) $(guest_env) dsh --profile web --host $DSH_HOST --port $DSH_PORT --no-open --trusted-host ${DSH_TRUSTED_HOST:-$DSH_HOST:$DSH_PORT} >>$LOGFILE 2>&1" \
    >>"$LOGFILE" 2>&1 &
  echo $! > "$PIDFILE"
  log "started (launcher pid $(cat "$PIDFILE")), log: $LOGFILE"
  log "waiting for readiness..."
  sh "$HERE/healthcheck.sh" --wait "${HEALTHCHECK_TIMEOUT:-60}" || {
    log "NOT ready after timeout — see $LOGFILE"
    return 1
  }
  log "ready at http://$DSH_HOST:$DSH_PORT/"
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

do_exec() {
  check_tree; ensure_dirs
  shift # drop 'exec'
  [ "${1:-}" = "--" ] && shift
  # NOTE: "$@" is intentionally flattened — exec is for simple install-time commands.
  # shellcheck disable=SC2086,SC2048
  exec sh -c "$(proot_base) $(guest_env) $*"
}

do_kill_terminal() {
  # Kill-switch (TERMINAL.md blocker 7, android/KILL-SWITCH.md): terminate guest
  # PTY shells started by dsh-terminal-bash (/bin/bash in guest). dsh web itself
  # runs under node and is NOT matched. Idempotent: always exit 0.
  check_tree; ensure_dirs
  # shellcheck disable=SC2086
  sh -c "$(proot_base) $(guest_env) pkill -f '/bin/bash' || true" >>"$LOGFILE" 2>&1 || true
  echo "[launch-dsh] terminal-kill $(date -u +%FT%TZ)" >>"$LOGFILE" 2>&1 || true
  log "terminal sessions killed (marker appended)"
}

case "${1:-status}" in
  start) do_start;;
  stop) do_stop;;
  status) do_status;;
  exec) do_exec "$@";;
  kill-terminal) do_kill_terminal;;
  *) die "usage: launch-dsh.sh {start|stop|status|exec -- <cmd>|kill-terminal}";;
esac
