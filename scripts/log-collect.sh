#!/system/bin/sh
# log-collect.sh — one-tap bugreport collector for the DSH Android wrapper.
# Owner: logs-qa (task-8). Contract with android-shell (task-2):
#   sources: filesDir/dsh.out.log + filesDir/dsh/logs/dsh.out.log (ADR-proot D6,
#            DshConfig.DSH_OUT_LOG_NAME) + DSH_HOME/logs (~/.dsh/logs, bind
#            dsh-home) + logcat tags DshService / dsh-keepalive (DshConfig.LOG_TAG,
#            DshLog.LOG_TAG/FILE_TAG).
# Usage:
#   sh log-collect.sh collect [--out-dir /sdcard/Download]   — build redacted zip
#   sh log-collect.sh --wipe                                 — erase logs (button)
#   sh log-collect.sh --help
# Output: /sdcard/Download/dsh-bugreport-<ts>.zip (Share sheet opens it).
# Secrets are REDACTED in every collected copy — never shipped raw.
set -eu

APP_FILES="${APP_FILES:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
FILES_DIR="$APP_FILES"
DSH_HOME_DIR="${DSH_HOME:-$APP_FILES/dsh-home}"
OUT_DIR_DEFAULT="/sdcard/Download"
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo nots)"
STAGE=""

log() { echo "[log-collect] $*"; }
die() { echo "[log-collect] FATAL: $*" >&2; exit 1; }

usage() {
  sed -n '2,14p' "$0"
}

# redact <file>: in-place mask of secrets. Patterns (case-insensitive):
#   api_key / api-key / apikey / token / pat / github_pat / secret /
#   authorization / bearer / x-api-key assignments, plus raw sk- / github_pat_
#   looking tokens. Replacement keeps the key name, masks the value.
redact_file() {
  F="$1"
  [ -f "$F" ] || return 0
  # 1) key=value / key: value assignments (quiet — never print values)
  sed -i \
    -e 's/\([Aa][Pp][Ii][_-]\?[Kk][Ee][Yy][_-]\?[Ee][Nn][Vv]*[ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Aa][Pp][Ii][_-]\?[Kk][Ee][Yy][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Tt][Oo][Kk][Ee][Nn][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Gg][Ii][Tt][Hh][Uu][Bb][_-]\?[Pp][Aa][Tt][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Pp][Aa][Tt][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Ss][Ee][Cc][Rr][Ee][Tt][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    -e 's/\([Bb][Ee][Aa][Rr][Ee][Rr][ \t][ \t]*\)[^ ]*/\1***REDACTED***/g' \
    -e 's/\([Xx]-[Aa][Pp][Ii]-[Kk][Ee][Yy][ \t]*[=:][ \t]*\).*/\1***REDACTED***/g' \
    "$F"
  # 2) raw token shapes floating without a key name
  sed -i \
    -e 's/sk-[A-Za-z0-9_.-]*/***REDACTED***/g' \
    -e 's/github_pat_[A-Za-z0-9_]*/***REDACTED***/g' \
    -e 's/gh[pousr]_[A-Za-z0-9_]*/***REDACTED***/g' \
    "$F"
}

safe_copy() {
  SRC="$1"; DST="$2"
  if [ -e "$SRC" ]; then
    mkdir -p "$(dirname "$DST")"
    cp -R "$SRC" "$DST" 2>/dev/null || log "skip (unreadable): $SRC"
  fi
}

collect_logcat() {
  DST="$1"
  if ! command -v logcat >/dev/null 2>&1; then
    echo "logcat: not available on this device" > "$DST/logcat-unavailable.txt"
    return 0
  fi
  # Current ring buffer, our tags only (quiet — dump, never stream -d is a snapshot).
  logcat -d -v threadtime DshService:I dsh-keepalive:I '*:S' > "$DST/logcat.txt" 2>/dev/null \
    || echo "logcat dump failed" > "$DST/logcat.txt"
  # Keepalive markers deserve their own grep-friendly slice (DshLog.FILE_TAG format).
  grep -i "keepalive\|dsh-keepalive\|DshService\|restart\|boot-received\|work-rescheduled" \
    "$DST/logcat.txt" > "$DST/logcat-keepalive.txt" 2>/dev/null || true
}

collect_info() {
  DST="$1"
  {
    echo "ts=$TS"
    echo "model=$(getprop ro.product.model 2>/dev/null || echo unknown)"
    echo "android=$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
    echo "sdk=$(getprop ro.build.version.sdk 2>/dev/null || echo unknown)"
  } > "$DST/device.txt" 2>/dev/null || true
  # DSH / node versions (best effort, host or guest).
  (command -v dsh >/dev/null 2>&1 && dsh --version > "$DST/dsh-version.txt" 2>&1) || \
    echo "dsh: version unknown (guest not running?)" > "$DST/dsh-version.txt"
  # settings.yaml — STRUCTURE ONLY, values redacted (apiKeyEnv name stays, key never).
  if [ -f "$DSH_HOME_DIR/settings.yaml" ]; then
    cp "$DSH_HOME_DIR/settings.yaml" "$DST/settings.yaml" 2>/dev/null && redact_file "$DST/settings.yaml" || true
  fi
  if [ -f "$DSH_HOME_DIR/cordis.patch.yml" ]; then
    cp "$DSH_HOME_DIR/cordis.patch.yml" "$DST/cordis.patch.yml" 2>/dev/null && redact_file "$DST/cordis.patch.yml" || true
  fi
  # Zen health snapshot (badge source of truth, no key sent — /v1/models needs none
  # on the loopback sidecar; Authorization header is NEVER added here).
  ZEN_BASE="${ZEN_BASE_URL:-http://127.0.0.1:8787/v1}"
  if command -v curl >/dev/null 2>&1; then
    curl -s -m 5 -o "$DST/zen-models.json" -w 'http=%{http_code}\n' "$ZEN_BASE/models" \
      > "$DST/zen-health.txt" 2>&1 || echo "zen: unreachable ($ZEN_BASE)" > "$DST/zen-health.txt"
  else
    echo "zen: curl missing, skipped (see Diagnostics badge)" > "$DST/zen-health.txt"
  fi
}

do_collect() {
  OUT_DIR="${1:-$OUT_DIR_DEFAULT}"
  mkdir -p "$OUT_DIR" 2>/dev/null || die "cannot write out-dir: $OUT_DIR"
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dsh-bugreport-XXXXXX")" || die "mktemp failed"
  trap 'rm -rf "$STAGE"' EXIT INT TERM
  log "staging in $STAGE"

  # 1) file logs — both historical locations (DshService flat file + ADR D6 subdir)
  safe_copy "$FILES_DIR/dsh.out.log" "$STAGE/files/dsh.out.log"
  safe_copy "$FILES_DIR/dsh/logs/dsh.out.log" "$STAGE/files/dsh-logs-dir.out.log"
  safe_copy "$FILES_DIR/dsh/logs/zen.out.log" "$STAGE/files/zen.out.log"
  # 2) DSH_HOME logs (~/.dsh/logs via dsh-home bind)
  safe_copy "$DSH_HOME_DIR/logs" "$STAGE/dsh-home-logs"
  # 3) pid files (prove which daemons were up)
  safe_copy "$FILES_DIR/dsh/run/dsh.pid" "$STAGE/run/dsh.pid"
  safe_copy "$FILES_DIR/dsh/run/zen.pid" "$STAGE/run/zen.pid"
  # 4) logcat + device info + versions + zen snapshot
  collect_logcat "$STAGE"
  collect_info "$STAGE"

  # 5) REDACT every text artifact before zipping (logs may echo env on crash).
  for f in "$STAGE/files/dsh.out.log" "$STAGE/files/dsh-logs-dir.out.log" \
           "$STAGE/files/zen.out.log" "$STAGE/logcat.txt" "$STAGE/logcat-keepalive.txt"; do
    [ -f "$f" ] && redact_file "$f"
  done
  if [ -d "$STAGE/dsh-home-logs" ]; then
    find "$STAGE/dsh-home-logs" -type f -exec sed -i \
      -e 's/sk-[A-Za-z0-9_.-]*/***REDACTED***/g' \
      -e 's/github_pat_[A-Za-z0-9_]*/***REDACTED***/g' {} + 2>/dev/null || true
  fi

  ZIP="$OUT_DIR/dsh-bugreport-$TS.zip"
  if command -v zip >/dev/null 2>&1; then
    (cd "$STAGE" && zip -qr "$ZIP" .) || die "zip failed"
  elif command -v python3 >/dev/null 2>&1; then
    # Fallback where Info-ZIP is missing (still a real .zip archive).
    STAGE_DIR="$STAGE" ZIP_FILE="$ZIP" python3 -c \
      "import os,zipfile; st=os.environ['STAGE_DIR']; zf=zipfile.ZipFile(os.environ['ZIP_FILE'],'w',zipfile.ZIP_DEFLATED); [zf.write(os.path.join(r,f),os.path.relpath(os.path.join(r,f),st)) for r,_,fs in os.walk(st) for f in fs]; zf.close()" \
      || die "python3 zip fallback failed"
  else
    die "no zip backend (zip/python3) — share logs manually from $STAGE"
  fi
  trap - EXIT INT TERM
  rm -rf "$STAGE"
  log "wrote $ZIP"
  echo "$ZIP"
}

do_wipe() {
  # Button "erase logs": truncate (not delete, to keep fd stability) + clear ring.
  for f in "$FILES_DIR/dsh.out.log" "$FILES_DIR/dsh/logs/dsh.out.log" \
           "$FILES_DIR/dsh/logs/zen.out.log"; do
    [ -f "$f" ] && : > "$f" 2>/dev/null && log "truncated $f" || true
  done
  if [ -d "$DSH_HOME_DIR/logs" ]; then
    find "$DSH_HOME_DIR/logs" -type f -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true
    log "truncated $DSH_HOME_DIR/logs"
  fi
  if command -v logcat >/dev/null 2>&1; then
    logcat -c 2>/dev/null && log "logcat ring cleared" || log "logcat -c denied (expected on some ROMs)"
  fi
  log "wipe done"
}

case "${1:-collect}" in
  collect) shift; do_collect "${1:-$OUT_DIR_DEFAULT}";;
  --out-dir) do_collect "${2:-$OUT_DIR_DEFAULT}";;
  --wipe|wipe) do_wipe;;
  --help|-h|help) usage;;
  *) die "usage: log-collect.sh {collect [--out-dir DIR]|--wipe|--help}";;
esac
