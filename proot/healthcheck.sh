#!/system/bin/sh
# healthcheck.sh — readiness probe for dsh web inside proot.
#   sh healthcheck.sh            — single check: exit 0 = ready, 1 = not ready
#   sh healthcheck.sh --wait N   — poll up to N seconds, exit 0 on first success
# Contract for DshService splash screen: wait ==> WebView loads http://127.0.0.1:8081/
# "Ready" = the port returns ANY HTTP response (even 401 from the browser-trust
# fence counts: it proves the server is up; auth is the WebView's business, task-7).
# Host-side check only — no guest/proot involvement.
set -eu

DSH_HOST="${DSH_HOST:-127.0.0.1}"
DSH_PORT="${DSH_PORT:-8081}"

one_check() {
  # 1) curl if present: any HTTP status line = up
  if command -v curl >/dev/null 2>&1; then
    CODE="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$DSH_HOST:$DSH_PORT/" 2>/dev/null)" || return 1
    case "$CODE" in [1-5][0-9][0-9]) return 0;; *) return 1;; esac
  fi
  # 2) wget fallback
  if command -v wget >/dev/null 2>&1; then
    wget -q -T 3 -O /dev/null "http://$DSH_HOST:$DSH_PORT/" 2>/dev/null && return 0
    # wget fails on 4xx/5xx too — but a *connection* success still proves liveness;
    # without curl we cannot distinguish, so fall through to TCP probe.
    true
  fi
  # 3) raw TCP connect via nc (openbsd/busybox)
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$DSH_HOST" "$DSH_PORT" 2>/dev/null && return 0 || return 1
  fi
  return 1
}

if [ "${1:-}" = "--wait" ]; then
  TIMEOUT="${2:-60}"
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    if one_check; then echo "ready http://$DSH_HOST:$DSH_PORT/ (${i}s)"; exit 0; fi
    sleep 1
    i=$((i + 1))
  done
  echo "NOT ready after ${TIMEOUT}s: http://$DSH_HOST:$DSH_PORT/" >&2
  exit 1
else
  if one_check; then echo "ready http://$DSH_HOST:$DSH_PORT/"; exit 0; else echo "not ready http://$DSH_HOST:$DSH_PORT/" >&2; exit 1; fi
fi
