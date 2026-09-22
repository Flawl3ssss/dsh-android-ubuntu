#!/system/bin/sh
# launch-zen.sh — Zen sidecar launcher (zen-adapter.mjs on guest node, inside proot).
# Owner: logs-qa. Thin shim over entry.sh supervision:
#   sh launch-zen.sh start   — full stack via entry.sh (zen first) — idempotent
#   sh launch-zen.sh stop    — stop stack via entry.sh
#   sh launch-zen.sh status  — stack status via entry.sh
#   sh launch-zen.sh health  — probes GET /v1/models, "zen-ok ..." / "zen-fail ..."
# Contract:
#   listens: 127.0.0.1:8787 (env ZEN_HOST/ZEN_PORT), base http://127.0.0.1:8787/v1
#   secret:  ZEN_API_KEY ONLY from process env (EncryptedSharedPrefs at runtime).
#            NEVER written to any file, never echoed to any log. Empty/dummy key =
#            adapter runs on its builtin key, DSH sends dummy (fail-open for UI,
#            chat calls will 401 upstream until a real key is set in Settings).
#   badge:   health == GET $ZEN_BASE_URL/models returns HTTP 200 => "zen-ok".
# NEVER invokes /usr/bin/proot (broken libtalloc). Zen runs INSIDE the proot guest
# on guest node (host Android has no node); DSH reaches it over 127.0.0.1.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ZEN_HOST="${ZEN_HOST:-127.0.0.1}"
ZEN_PORT="${ZEN_PORT:-8787}"
ZEN_BASE_URL="${ZEN_BASE_URL:-http://$ZEN_HOST:$ZEN_PORT/v1}"
ZEN_MODEL="${ZEN_MODEL:-muse-spark-1.3-contributor-free}"

die() { echo "[launch-zen] FATAL: $*" >&2; exit 1; }

do_health() {
  _code=""
  if command -v curl >/dev/null 2>&1; then
    _code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$ZEN_BASE_URL/models" 2>/dev/null)" || _code=""
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 5 -O /dev/null "$ZEN_BASE_URL/models" 2>/dev/null && _code="200" || _code=""
  fi
  if [ "$_code" = "200" ]; then echo "zen-ok $ZEN_BASE_URL/models (model $ZEN_MODEL)"; return 0; else echo "zen-fail $ZEN_BASE_URL/models"; return 1; fi
}

case "${1:-status}" in
  start) shift; exec sh "$HERE/entry.sh" start "$@";;
  stop) exec sh "$HERE/entry.sh" stop;;
  status) exec sh "$HERE/entry.sh" status;;
  health) do_health;;
  *) die "usage: launch-zen.sh {start|stop|status|health}";;
esac
