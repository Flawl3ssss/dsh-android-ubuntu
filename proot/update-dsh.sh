#!/system/bin/sh
# update-dsh.sh — безопасное A/B-обновление DSH в Android proot-обёртке.
# task-6 (update-guard). Зона записи: только этот файл + docs/UPDATE.md.
# Контракты (см. docs/UPDATE.md, docs/ADR-proot.md, docs/DSH-INTERNALS.md):
#   A/B:      <proot>/rootfs.A + <proot>/rootfs.B + симлинк <proot>/current
#   Пин:      distro.json -> dsh.{npm_package, version, channel, npm_tag}
#   Запуск:   launch-dsh.sh start|stop|status|exec (task-1, architect-proot)
#   Ready:    healthcheck.sh [--wait N], exit 0/1; «жив» = ЛЮБОЙ HTTP-ответ
#             (включая 401 trust-fence; auth — зона task-7). Проверено вживую:
#             GET / без токена -> 401, мусорный путь -> 404, /health* -> 404,
#             в tarball чейнджлога НЕТ (dsh-insider). 200 НЕ ожидаем никогда.
#
# Каналы: stable -> npm-тег `latest`, alpha -> npm-тег `alpha`.
# Проверено 2026-09-22: dist-tags {latest: 0.1.5-rc.2, alpha: 0.1.6-alpha.2},
# установлен 0.1.6-alpha.2. Канал по умолчанию: alpha (newest).
#
# Принцип: откат по умолчанию. Обновление ставится в НЕАКТИВНЫЙ слот
# (клон активного + guest `npm install -g pkg@target`), гоняется healthcheck,
# и только потом `current` атомарно переключается. Любой провал -> автооткат:
# симлинк не тронут, битый слот уходит в карантин.
#
# Использование:
#   sh update-dsh.sh status [--json]
#   sh update-dsh.sh check [--channel stable|alpha] [--json]
#   sh update-dsh.sh apply [--channel stable|alpha] [--yes]
#                          [--skip-workspace-backup] [--health-timeout SEC]
#   sh update-dsh.sh rollback [--yes]
#
# Кнопка «Обновить DSH» (нативный экран настроек, НЕ из DSH-сессии):
#   check [--json] -> показать чейнджлог -> подтверждение -> apply --yes.
# Кнопка «Вернуть предыдущую версию»: rollback --yes.
# ЗАПРЕТ: apply/rollback отказываются работать при живой DSH-сессии
# (авторитетно: `launch-dsh.sh status` == running). Обходного флага НЕТ —
# сначала останови DSH из нативного UI. check/status разрешены всегда.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PROOT_DIR="${PROOT_DIR:-$HERE}"
APP_FILES="${APP_FILES:-$HERE}"
DISTRO_JSON="${DISTRO_JSON:-$PROOT_DIR/distro.json}"
LAUNCH_SH="$PROOT_DIR/launch-dsh.sh"
HEALTH_SH="$PROOT_DIR/healthcheck.sh"
RUN_IN_SLOT_HOOK="$PROOT_DIR/run-in-slot.sh"  # предложение к task-1 (см. UPDATE.md)

SLOT_A="$PROOT_DIR/rootfs.A"
SLOT_B="$PROOT_DIR/rootfs.B"
CURRENT_LINK="$PROOT_DIR/current"
QUARANTINE_DIR="$PROOT_DIR/.quarantine"
BACKUP_ROOT="$APP_FILES/backups"
LOG_DIR="$APP_FILES/dsh/logs"
PIDFILE="$APP_FILES/dsh/run/dsh.pid"
LOCK_DIR="$APP_FILES/.update.lock"
STATE_FILE="$APP_FILES/.last-update.json"

LINKER="${LINKER:-/system/bin/linker64}"
LIBDIR="${LIBDIR:-$APP_FILES/proot/lib}"
CHANNEL="${DSH_CHANNEL:-alpha}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
HTTP_TIMEOUT=5
HTTP_RETRIES=3
KEEP_BACKUPS=3
KEEP_UPDATE_LOGS=5
JSON_OUT=0
_YES=0
_SKIP_WS=0

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "нет команды: $1"; }

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ------------------------------------------------------------------ channels

npm_tag_for_channel() {
  case "$1" in
    stable) printf 'latest' ;;
    alpha) printf 'alpha' ;;
    *) die "неизвестный канал: $1 (stable|alpha)" ;;
  esac
}

# npm на хосте (dev) или в госте (устройство: у хоста npm нет).
# Возвращает stdout команды npm <args...> или пусто.
npm_out() {
  if command -v npm >/dev/null 2>&1 && _o="$(npm "$@" 2>/dev/null)"; then
    printf '%s' "$_o"; return 0
  fi
  if [ -x "$LAUNCH_SH" ] && _o="$("$LAUNCH_SH" exec -- npm "$@" 2>/dev/null)"; then
    printf '%s' "$_o"; return 0
  fi
  return 1
}

resolve_target() {
  _tag="$(npm_tag_for_channel "$1")"
  _dt="$(npm_out view "@deepseek-ai/dsh" "dist-tags.$_tag" 2>/dev/null || true)"
  [ -n "${_dt:-}" ] || die "не удалось резолвить npm-тег $_tag (нужна сеть; guest npm: launch-dsh.sh exec)"
  printf '%s' "$_dt" | tr -d ' \t\r\n'
}

# ------------------------------------------------------------------ pin/slots

current_version() {
  if [ -f "$DISTRO_JSON" ] && command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("dsh",{}).get("version",""))' \
      "$DISTRO_JSON" 2>/dev/null || true
  elif [ -f "$DISTRO_JSON" ]; then
    grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$DISTRO_JSON" 2>/dev/null \
      | head -n 1 | sed 's/.*"\(.*\)"/\1/' || true
  fi
}

current_channel() {
  if [ -f "$DISTRO_JSON" ] && command -v python3 >/dev/null 2>&1; then
    _c="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("dsh",{}).get("channel",""))' \
      "$DISTRO_JSON" 2>/dev/null || true)"
    [ -n "${_c:-}" ] && { printf '%s' "$_c"; return 0; }
  fi
  printf '%s' "$CHANNEL"
}

# Активный слот: абсолютный путь (резолв current) или пусто.
active_slot() {
  if [ -L "$CURRENT_LINK" ]; then
    _t="$(readlink "$CURRENT_LINK")"
    case "$_t" in /*) printf '%s' "$_t" ;; *) printf '%s' "$PROOT_DIR/$_t" ;; esac
  fi
}

inactive_slot() {
  _a="$(active_slot)"
  if [ "$_a" = "$SLOT_B" ]; then printf '%s' "$SLOT_A"; else printf '%s' "$SLOT_B"; fi
}

slot_name() { basename "$1"; }

# ------------------------------------------------------------------ guards

# ЗАПРЕТ обновления посреди сессии. Авторитетный сигнал — launch-dsh.sh status.
# Обходного флага нет: останови DSH из нативного UI, потом обновляйся.
guard_active_session() {
  if [ "${DSH_SESSION_ACTIVE:-0}" = "1" ]; then
    die "DSH-сессия активна (DSH_SESSION_ACTIVE=1). Останови DSH и повтори."
  fi
  if [ -x "$LAUNCH_SH" ] && _st="$("$LAUNCH_SH" status 2>/dev/null || true)"; then
    case "$_st" in running*)
      die "DSH-сессия активна ($LAUNCH_SH status: $_st). Останови DSH и повтори." ;;
    esac
  fi
  if [ -f "$PIDFILE" ]; then
    _pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${_pid:-}" ] && kill -0 "$_pid" 2>/dev/null; then
      die "DSH-сессия активна (PID $_pid из $PIDFILE жив). Останови DSH и повтори."
    fi
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "dsh.*web" >/dev/null 2>&1; then
    die "DSH-сессия активна (найден процесс dsh web). Останови DSH и повтори."
  fi
}

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
  else
    _lp="$(cat "$LOCK_DIR/pid" 2>/dev/null || printf '?')"
    if [ "$_lp" != "?" ] && kill -0 "$_lp" 2>/dev/null; then
      die "обновление уже выполняется (PID $_lp). Дождись завершения."
    fi
    log "WARN: stale lock ($LOCK_DIR, PID $_lp), забираю"
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"
    printf '%s' "$$" > "$LOCK_DIR/pid"
    trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
  fi
}

# ------------------------------------------------------------------ changelog

# Локального чейнджлога нет (в tarball только lib/*.js). Источник — сеть:
# `npm view time` (версии+даты в диапазоне) + ссылка на GitHub releases
# (notes может не быть — необязательный источник). Ядро — diff версий.
show_changelog() {
  _from="$1"; _to="$2"
  log "Чейнджлог $_from -> $_to (npm registry + релизы — необязательно):"
  if _t="$(npm_out view "@deepseek-ai/dsh" time --json 2>/dev/null || true)" && [ -n "${_t:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then
      printf '%s' "$_t" | python3 -c '
import json,sys
try: t=json.load(sys.stdin)
except Exception: sys.exit(0)
frm,to=sys.argv[1],sys.argv[2]
vers=sorted([v for v in t if v[:1].isdigit()])
inside=(frm in ("","unknown"))
for v in vers:
    if v==frm: inside=True; continue
    if inside: print("  - %s  (%s)"%(v,t.get(v,"?")))
    if v==to: break' "$_from" "$_to" 2>/dev/null || log "  (разбор npm time не удался)"
    else
      log "  (нет python3 для разбора; версии: $_from -> $_to)"
    fi
  else
    log "  (npm registry недоступен; версии: $_from -> $_to)"
  fi
  log "  Notes (если есть): https://github.com/deepseek-ai/deepseek-harness/releases/tag/v$_to"
}

confirm_or_die() {
  if [ "$_YES" = "1" ]; then log "Подтверждено флагом --yes."; return 0; fi
  printf 'Продолжить? [y/N] ' >&2
  read -r _ans || _ans=""
  case "$_ans" in y|Y|yes|YES) log "Подтверждено пользователем." ;; *) die "Отменено пользователем." ;; esac
}

# ------------------------------------------------------------------ backup

backup_all() {
  _ts="$(date -u '+%Y%m%dT%H%M%SZ')"
  _dir="$BACKUP_ROOT/$_ts"
  mkdir -p "$_dir"
  log "Бэкап -> $_dir"
  need tar
  if [ -d "$APP_FILES/dsh-home" ]; then
    tar -czf "$_dir/dsh-home.tar.gz" --exclude='logs' --exclude='*.log' \
      --exclude='cache' --exclude='node_modules' -C "$APP_FILES" dsh-home 2>/dev/null \
      || die "бэкап dsh-home не удался"
  else
    log "WARN: $APP_FILES/dsh-home отсутствует, пропускаю"
  fi
  if [ -d "${HOME:-/nonexistent}/.dsh" ] && [ "${HOME:-/nonexistent}/.dsh" != "$APP_FILES/dsh-home" ]; then
    tar -czf "$_dir/dot-dsh.tar.gz" --exclude='logs' --exclude='*.log' \
      --exclude='cache' --exclude='node_modules' -C "$HOME" .dsh 2>/dev/null \
      || log "WARN: бэкап ~/.dsh не удался, продолжаю"
  fi
  if [ "$_SKIP_WS" = "1" ]; then
    log "Бэкап workspace пропущен (--skip-workspace-backup)."
  else
    _ws="${DSH_WORKSPACE:-$APP_FILES/workspace}"
    if [ -d "$_ws" ]; then
      tar -czf "$_dir/workspace.tar.gz" --exclude='node_modules' --exclude='.cache' \
        --exclude='dist' --exclude='build' -C "$(dirname "$_ws")" "$(basename "$_ws")" 2>/dev/null \
        || die "бэкап workspace не удался"
    else
      log "WARN: workspace $_ws отсутствует, пропускаю (задай DSH_WORKSPACE)"
    fi
  fi
  {
    printf 'timestamp=%s\n' "$_ts"
    printf 'from_version=%s\n' "$1"
    printf 'to_version=%s\n' "$2"
    printf 'channel=%s\n' "$3"
  } > "$_dir/manifest.txt"
  (cd "$_dir" && sha256sum ./*.tar.gz > SHA256SUMS 2>/dev/null || true)
  _n="$(ls -1 "$BACKUP_ROOT" 2>/dev/null | wc -l)"
  if [ "$_n" -gt "$KEEP_BACKUPS" ]; then
    ls -1 "$BACKUP_ROOT" | sort | head -n "$((_n - KEEP_BACKUPS))" | while read -r _old; do
      rm -rf "$BACKUP_ROOT/$_old" && log "Ротация бэкапов: удалён $_old"
    done
  fi
  printf '%s' "$_dir"
}

# ------------------------------------------------------------------ slot runs

# Однократная команда в КОНКРЕТНОМ слоте (не current!). Приоритет:
# 1) хук run-in-slot.sh (предложение к task-1), 2) зеркало proot_base/guest_env
# из launch-dsh.sh (поддерживать синхронно!). Команды — простые, т.к. exec
# сплющивает аргументы (ограничение launch-dsh.sh, см. ADR §D5/R4).
slot_base_cmd() {
  if [ -x "$RUN_IN_SLOT_HOOK" ]; then printf 'HOOK %s' "$RUN_IN_SLOT_HOOK"; return 0; fi
  [ -e "$LINKER" ] || die "линкер отсутствует: $LINKER"
  [ -f "$LIBDIR/libproot.so" ] || die "libproot.so отсутствует: $LIBDIR (сначала install.sh)"
  _b=""
  [ -r /sdcard/Download ] && _b="$_b -b /sdcard/Download:/phone/Download"
  [ -r /sdcard/DCIM ] && _b="$_b -b /sdcard/DCIM:/phone/DCIM"
  printf '%s' "$LINKER $LIBDIR/libproot.so -r $1 -0 -w /root -b /dev -b /proc -b /sys$_b -b $APP_FILES/dsh-home:/dsh-home"
}

slot_guest_env() {
  printf '%s' "env -i HOME=/root USER=root TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 DSH_HOME=/dsh-home PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}


slot_run_npm() {
  _slot="$1"; shift
  env -u PREFIX PATH="/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH" HOME=/root sh -c "$(slot_base_cmd "$_slot") $*"
}

# slot_run <slot> <cmd...>: выполнить простую команду в слоте, вернуть её код.
slot_run() {
  _slot="$1"; shift
  if [ -x "$RUN_IN_SLOT_HOOK" ]; then
    "$RUN_IN_SLOT_HOOK" "$_slot" "$@"
    return $?
  fi
  # shellcheck disable=SC2086
  sh -c "$(slot_base_cmd "$_slot") $(slot_guest_env) $*"
}

slot_dsh_version() {
  slot_run "$1" dsh --version 2>/dev/null || true
}

# ------------------------------------------------------------------ http

http_get_code() {
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" "$1" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    _out="$(wget -q -O /dev/null --timeout="$HTTP_TIMEOUT" -S "$1" 2>&1 || true)"
    printf '%s' "$_out" | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | tail -n 1 | awk '{print $2}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys,urllib.request,urllib.error
try:
    print(urllib.request.urlopen(sys.argv[1],timeout=int(sys.argv[2])).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    pass' "$1" "$HTTP_TIMEOUT" 2>/dev/null || true
  fi
}

free_port() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])' 2>/dev/null && return 0
  fi
  _p=18081
  while [ "$_p" -lt 18101 ]; do
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import socket,sys;s=socket.socket();s.bind(("127.0.0.1",int(sys.argv[1])))' "$_p" 2>/dev/null \
        && { printf '%s' "$_p"; return 0; }
    elif command -v busybox >/dev/null 2>&1; then
      busybox nc -z 127.0.0.1 "$_p" 2>/dev/null || { printf '%s' "$_p"; return 0; }
    else
      printf '%s' "$_p"; return 0
    fi
    _p=$((_p + 1))
  done
  die "нет свободного порта для healthcheck"
}

stop_server() {
  kill "$1" 2>/dev/null || true
  sleep 1
  if kill -0 "$1" 2>/dev/null; then kill -9 "$1" 2>/dev/null || true; fi
  wait "$1" 2>/dev/null || true
}

# Healthcheck слота (3 ступени, критерии проверены вживую dsh-insider):
#  1) dsh --version в слоте == TARGET (правильный бинарь);
#  2) healthcheck.sh (контракт task-1) с DSH_PORT=эфемерный: ЛЮБОЙ HTTP-ответ
#     (401 trust-fence = жив). 200 НЕ ждём — токен только в консоли dsh web;
#  3) второй критерий (ред-флаг критика: 401 не отличает жив от залипшего):
#     404 на заведомо мусорном пути доказывает, что отвечает роутер.
#     Без curl/wget/python3 ступень 3 пропускается (degraded, с WARN).
#  Отсутствие ответа после HTTP_RETRIES ретраев = «мёртв».
healthcheck_slot() {
  _slot="$1"; _ver="$2"
  log "Healthcheck $(slot_name "$_slot") (target $_ver, бюджет ${HEALTH_TIMEOUT}s)..."
  _got="$(slot_dsh_version "$_slot")"
  [ "$_got" = "$_ver" ] || { log "Healthcheck FAIL [1/3]: dsh --version='$_got', ожидалось '$_ver'"; return 1; }
  log "  [1/3] dsh --version = $_ver OK"
  [ -x "$HEALTH_SH" ] || die "healthcheck.sh отсутствует: $HEALTH_SH"
  _port="$(free_port)"
  _srvlog="${TMPDIR:-/tmp}/dsh-hc-$$.log"
  # shellcheck disable=SC2086
  nohup sh -c "exec $(slot_base_cmd "$_slot") $(slot_guest_env) dsh --profile web --host 127.0.0.1 --port $_port --no-open >>$_srvlog 2>&1" \
    >>"$_srvlog" 2>&1 &
  _srv=$!
  _deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  _c1=""
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    if ! kill -0 "$_srv" 2>/dev/null; then
      log "Healthcheck FAIL: dsh web упал при старте. Хвост лога (токен затёрт):"
      sed 's/token=[^& "]*\?/token=REDACTED/g' "$_srvlog" 2>/dev/null | tail -n 20 >&2 || true
      rm -f "$_srvlog"; return 1
    fi
    _try=0; _c1=""
    while [ "$_try" -lt "$HTTP_RETRIES" ]; do
      _c1="$(http_get_code "http://127.0.0.1:$_port/")"
      [ -n "${_c1:-}" ] && break
      _try=$((_try + 1)); sleep 1
    done
    [ -n "${_c1:-}" ] && break
    sleep 2
  done
  if [ -z "${_c1:-}" ]; then
    stop_server "$_srv"; rm -f "$_srvlog"
    log "Healthcheck FAIL [2/3]: нет HTTP-ответа за ${HEALTH_TIMEOUT}s (refused/timeout)"
    return 1
  fi
  log "  [2/3] healthcheck.sh (DSH_PORT=$_port) PASS: GET / -> $_c1"
  if [ -n "$(DSH_HOST=127.0.0.1 DSH_PORT="$_port" sh "$HEALTH_SH" 2>/dev/null || true)" ] \
     || DSH_HOST=127.0.0.1 DSH_PORT="$_port" sh "$HEALTH_SH" >/dev/null 2>&1; then
    log "  [2/3b] healthcheck.sh exit 0 — подтверждено контрактом task-1"
  else
    stop_server "$_srv"; rm -f "$_srvlog"
    log "Healthcheck FAIL [2/3b]: healthcheck.sh вернул != 0"
    return 1
  fi
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    _c2="$(http_get_code "http://127.0.0.1:$_port/__dsh_update_probe_no_such_path__" || true)"
    stop_server "$_srv"; rm -f "$_srvlog"
    [ -n "${_c2:-}" ] || { log "Healthcheck FAIL [3/3]: мусорный путь без ответа (сокет залип?)"; return 1; }
    log "  [3/3] junk-path -> $_c2 OK (роутер отвечает)"
  else
    stop_server "$_srv"; rm -f "$_srvlog"
    log "  [3/3] SKIP (нет HTTP-клиента): degraded — полагаемся на healthcheck.sh"
  fi
  log "Healthcheck PASS"
  return 0
}

# ------------------------------------------------------------------ A/B ops

quarantine_slot() {
  mkdir -p "$QUARANTINE_DIR"
  _q="$QUARANTINE_DIR/$(slot_name "$1")-failed-$(date -u '+%Y%m%dT%H%M%SZ')"
  if mv "$1" "$_q" 2>/dev/null; then
    log "Битый слот изолирован: $_q (диагностика — зона logs-qa)"
  else
    rm -rf "$1"; log "Битый слот удалён: $1"
  fi
  ls -d "$QUARANTINE_DIR"/* 2>/dev/null | sort | head -n -1 2>/dev/null | while read -r _old; do
    rm -rf "$_old" && log "Ротация карантина: удалён $_old"
  done
  return 0
}

# Миграция legacy (один rootfs/, без current): mv rootfs -> rootfs.A + symlink.
# Ничего не копируем (rename мгновенный), active-смысл сохраняется.
ensure_ab_layout() {
  if [ -L "$CURRENT_LINK" ]; then return 0; fi
  if [ -d "$SLOT_A" ] || [ -d "$SLOT_B" ]; then
    if [ -d "$SLOT_A" ]; then flip_current "rootfs.A"; else flip_current "rootfs.B"; fi
    log "current отсутствовал: привязан к существующему слоту ($(readlink "$CURRENT_LINK"))"
    return 0
  fi
  if [ -d "$PROOT_DIR/rootfs" ]; then
    mv "$PROOT_DIR/rootfs" "$SLOT_A" || die "миграция rootfs -> rootfs.A не удалась"
    flip_current "rootfs.A"
    log "Миграция legacy: rootfs/ -> rootfs.A + current"
    return 0
  fi
  die "нет установленной системы (ни current, ни rootfs/): сначала sh install.sh"
}

flip_current() { ln -sfn "$1" "$CURRENT_LINK"; }

# Пин в distro.json: dsh.{version, npm_tag} + verifiedAt. Остальное не трогаем.
write_pin() {
  _ver="$1"; _tag="$(npm_tag_for_channel "$2")"; _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  [ -f "$DISTRO_JSON" ] || { log "WARN: $DISTRO_JSON отсутствует — пин не записан"; return 0; }
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$DISTRO_JSON" "$_ver" "$_tag" "$_ts" <<'PYEOF' || die "запись пина не удалась"
import json,sys
f,ver,tag,ts=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
doc=json.load(open(f))
doc.setdefault("dsh",{}).update({"version":ver,"npm_tag":tag,"verifiedAt":ts})
open(f+".tmp","w").write(json.dumps(doc,indent=2,ensure_ascii=False)+"\n")
PYEOF
    mv "$DISTRO_JSON.tmp" "$DISTRO_JSON"
    log "Пин записан: dsh.version=$_ver dsh.npm_tag=$_tag"
  else
    log "WARN: нет python3 — обнови distro.json вручную: dsh.version=$_ver"
  fi
}

write_state() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$STATE_FILE" "$1" "$2" "$3" "$4" "$(active_slot)" <<'PYEOF' 2>/dev/null || true
import json,sys,datetime
f,frm,to,ch,res,slot=sys.argv[1:]
json.dump({"from":frm,"to":to,"channel":ch,"result":res,
           "at":datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "activeSlot":slot},open(f,"w"),indent=2)
PYEOF
  fi
}

# Клон активного слота -> неактивный, затем guest npm upgrade только DSH
# (rootfs+node пинованы и идентичны — перекачивать не нужно, активный не тронут).
prepare_slot() {
  _src="$1"; _dst="$2"; _ver="$3"
  [ -d "$_src" ] || die "активный слот отсутствует: $_src"
  log "Клонирую $(slot_name "$_src") -> $(slot_name "$_dst") (cp -a, активный не тронут)..."
  rm -rf "$_dst"
  cp -a "$_src" "$_dst" || die "клонирование слота не удалось"
  log "Guest npm upgrade в $(slot_name "$_dst"): @deepseek-ai/dsh@$_ver ..."
  slot_run_npm "$_dst" npm install -g --prefix /opt/node "@deepseek-ai/dsh@$_ver" \
    || { log "ERROR: guest npm install не удался"; return 1; }
  return 0
}

# ------------------------------------------------------------------ commands

cmd_status() {
  _cur="$(current_version)"; [ -n "${_cur:-}" ] || _cur="unknown"
  _ch="$(current_channel)"
  _tgt="$(resolve_target "$_ch" 2>/dev/null || printf 'unresolved')"
  _slot="$(active_slot)"; [ -n "${_slot:-}" ] || _slot="none"
  if [ "$JSON_OUT" = "1" ]; then
    printf '{"current":"%s","channel":"%s","target":"%s","activeSlot":"%s"}\n' \
      "$(json_escape "$_cur")" "$(json_escape "$_ch")" \
      "$(json_escape "$_tgt")" "$(json_escape "$_slot")"
  else
    log "DSH: current=$_cur channel=$_ch target[$_ch]=$_tgt activeSlot=$_slot"
  fi
}

cmd_check() {
  _ch="$CHANNEL"
  _cur="$(current_version)"; [ -n "${_cur:-}" ] || _cur="unknown"
  _tgt="$(resolve_target "$_ch")" || die "цель не резолвится (нужна сеть)"
  if [ "$JSON_OUT" = "1" ]; then
    _avail=true; [ "$_cur" = "$_tgt" ] && _avail=false
    printf '{"current":"%s","channel":"%s","target":"%s","updateAvailable":%s}\n' \
      "$(json_escape "$_cur")" "$(json_escape "$_ch")" "$(json_escape "$_tgt")" "$_avail"
    return 0
  fi
  log "Канал=$_ch (npm-тег $(npm_tag_for_channel "$_ch")): текущая=$_cur, доступная=$_tgt"
  if [ "$_cur" = "$_tgt" ]; then
    log "Обновление не требуется."
  else
    show_changelog "$_cur" "$_tgt"
    log "Установка: apply --channel $_ch --yes (только при остановленном DSH)"
  fi
}

cmd_apply() {
  guard_active_session
  acquire_lock
  mkdir -p "$PROOT_DIR" "$BACKUP_ROOT" "$LOG_DIR" "$QUARANTINE_DIR"
  _ch="$CHANNEL"
  _cur="$(current_version)"; [ -n "${_cur:-}" ] || _cur="unknown"
  _tgt="$(resolve_target "$_ch")" || die "цель не резолвится (нужна сеть)"
  log "Apply: $_cur -> $_tgt (канал $_ch)"
  if [ "$_cur" = "$_tgt" ]; then
    log "Уже последняя версия. Нечего делать."; write_state "$_cur" "$_tgt" "$_ch" "noop"; return 0
  fi
  show_changelog "$_cur" "$_tgt"
  confirm_or_die
  _bdir="$(backup_all "$_cur" "$_tgt" "$_ch")"
  log "Бэкап готов: $_bdir"
  ensure_ab_layout
  _src="$(active_slot)"; _new="$(inactive_slot)"
  log "Активный: $(slot_name "$_src"), целевой: $(slot_name "$_new")"
  if ! prepare_slot "$_src" "$_new" "$_tgt"; then
    log "ERROR: подготовка $(slot_name "$_new") не удалась — откат не нужен (активный не тронут)"
    quarantine_slot "$_new"
    write_state "$_cur" "$_tgt" "$_ch" "install-failed"
    exit 1
  fi
  if ! healthcheck_slot "$_new" "$_tgt"; then
    log "ERROR: healthcheck провален — АВТООТКАТ (переключения нет)"
    quarantine_slot "$_new"
    write_state "$_cur" "$_tgt" "$_ch" "healthcheck-failed-rolled-back"
    exit 1
  fi
  flip_current "$(slot_name "$_new")"
  _smoke="$(slot_dsh_version "$_new")"
  if [ "$_smoke" != "$_tgt" ]; then
    log "ERROR: smoke после переключения ('$_smoke') — возвращаю $(slot_name "$_src")"
    flip_current "$(slot_name "$_src")"
    quarantine_slot "$_new"
    write_state "$_cur" "$_tgt" "$_ch" "post-switch-failed-rolled-back"
    exit 1
  fi
  write_pin "$_tgt" "$_ch"
  write_state "$_cur" "$_tgt" "$_ch" "ok"
  log "OK: DSH $_cur -> $_tgt. Предыдущий слот ($(slot_name "$_src")) сохранён для rollback."
}

cmd_rollback() {
  guard_active_session
  acquire_lock
  _cur_slot="$(active_slot)"
  [ -n "${_cur_slot:-}" ] || die "активный слот неизвестен (нет current), откат невозможен"
  _prev="$(inactive_slot)"
  [ -d "$_prev" ] || die "слот для отката отсутствует ($(slot_name "$_prev"))"
  _pv="$(slot_dsh_version "$_prev")"
  [ -n "${_pv:-}" ] || die "в $(slot_name "$_prev") нет рабочего dsh, откат невозможен"
  log "Rollback: $(slot_name "$_cur_slot") ($(slot_dsh_version "$_cur_slot")) -> $(slot_name "$_prev") ($_pv)"
  confirm_or_die
  flip_current "$(slot_name "$_prev")"
  _smoke="$(slot_dsh_version "$_prev")"
  [ -n "${_smoke:-}" ] || die "smoke после отката провален"
  write_pin "$_smoke" "$(current_channel)"
  write_state "rollback-from" "$_smoke" "$(current_channel)" "rollback-ok"
  log "OK: откат выполнен, активна версия $_smoke"
}

usage() {
  printf 'usage: sh update-dsh.sh {status|check|apply|rollback} [opts]\n' >&2
  printf '  opts: --channel stable|alpha (def: %s)  --yes  --json (status|check)\n' "$CHANNEL" >&2
  printf '        --skip-workspace-backup  --health-timeout SEC (def: %s)\n' "$HEALTH_TIMEOUT" >&2
  printf '  env:  APP_FILES PROOT_DIR DISTRO_JSON DSH_CHANNEL DSH_WORKSPACE HEALTH_TIMEOUT LINKER LIBDIR\n' >&2
  exit 2
}

# ------------------------------------------------------------------ main

CMD="${1:-}"; shift 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --channel=*) CHANNEL="${1#--channel=}"; shift ;;
    --yes|-y) _YES=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --skip-workspace-backup) _SKIP_WS=1; shift ;;
    --health-timeout) HEALTH_TIMEOUT="${2:-120}"; shift 2 ;;
    --health-timeout=*) HEALTH_TIMEOUT="${1#--health-timeout=}"; shift ;;
    -h|--help) usage ;;
    *) die "неизвестный флаг: $1" ;;
  esac
done
export _YES _SKIP_WS

# Лог apply/rollback — в dsh/logs (точка сбора logs-qa, task-8), ротация.
case "$CMD" in
  apply|rollback)
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    if [ -d "$LOG_DIR" ]; then
      _ulf="$LOG_DIR/update-$(date -u '+%Y%m%dT%H%M%SZ').log"
      ls -1 "$LOG_DIR"/update-*.log 2>/dev/null | sort | head -n -"$KEEP_UPDATE_LOGS" 2>/dev/null | while read -r _o; do rm -f "$_o"; done
      exec >>"$_ulf" 2>&1 || true
      log "Лог обновления: $_ulf"
    fi
    ;;
esac

case "$CMD" in
  status) cmd_status ;;
  check) cmd_check ;;
  apply) cmd_apply ;;
  rollback) cmd_rollback ;;
  *) usage ;;
esac
