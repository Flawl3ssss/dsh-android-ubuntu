#!/system/bin/sh
# proot-common.sh — shared helpers, sourced by entry.sh / launch-dsh.sh / launch-zen.sh.
# NEVER invokes /usr/bin/proot (broken musl libtalloc on target devices).
# Only: /system/bin/linker64 <libdir>/libproot.so  (override LINKER for CI).
# shellcheck disable=SC2034
PROOT_COMMON=1

HERE_COMMON="$(cd "$(dirname "$0")" && pwd)"
APP_FILES="${APP_FILES:-$HERE_COMMON}"
if [ ! -d "$APP_FILES/proot/rootfs" ] && [ ! -L "$APP_FILES/proot/current" ] && [ -d "$HERE_COMMON/rootfs" ]; then
  APP_FILES="$HERE_COMMON"
fi

LIBDIR="$APP_FILES/proot/lib"
if [ -L "$APP_FILES/proot/current" ]; then ROOTFS="$(readlink -f "$APP_FILES/proot/current")"; else ROOTFS="$APP_FILES/proot/rootfs"; fi
LINKER="${LINKER:-/system/bin/linker64}"

DSH_HOST="${DSH_HOST:-127.0.0.1}"
DSH_PORT="${DSH_PORT:-8081}"
ZEN_HOST="${ZEN_HOST:-127.0.0.1}"
ZEN_PORT="${ZEN_PORT:-8787}"

extra_binds() {
  B=""
  if [ -r /sdcard/Download ]; then B="$B -b /sdcard/Download:/phone/Download"; fi
  if [ -r /sdcard/DCIM ]; then B="$B -b /sdcard/DCIM:/phone/DCIM"; fi
  echo "$B"
}

proot_base() {
  # echoes base proot invocation; caller appends guest command.
  # shellcheck disable=SC2086
  echo "$LINKER $LIBDIR/libproot.so -r $ROOTFS -0 -w /root -b /dev -b /proc -b /sys$(extra_binds) -b $APP_FILES/dsh-home:/dsh-home"
}

guest_env() {
  echo "env -i HOME=/root USER=root TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 DSH_HOME=/dsh-home PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

check_tree() {
  [ -e "$LINKER" ] || { echo "[proot-common] FATAL: linker not found: $LINKER" >&2; return 1; }
  [ -f "$LIBDIR/libproot.so" ] || { echo "[proot-common] FATAL: libproot.so missing in $LIBDIR" >&2; return 1; }
  { [ -d "$ROOTFS/bin" ] || [ -d "$ROOTFS/usr/bin" ]; } || { echo "[proot-common] FATAL: rootfs not unpacked at $ROOTFS" >&2; return 1; }
}

running_pid() {
  # running_pid <pidfile> -> echoes pid or returns 1
  [ -f "$1" ] || return 1
  _p="$(cat "$1" 2>/dev/null)" || return 1
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null || return 1
  echo "$_p"
}

iso_now() { date -u +%FT%TZ 2>/dev/null || date; }

rotate_log() {
  # rotate_log <file> [max_bytes=2097152 keep=5]
  _f="$1"; _max="${2:-2097152}"
  [ -f "$_f" ] || return 0
  _s="$(wc -c < "$_f" 2>/dev/null)" || return 0
  if [ "$_s" -gt "$_max" ]; then
    rm -f "$_f.5"
    i=4; while [ "$i" -ge 1 ]; do [ -f "$_f.$i" ] && mv "$_f.$i" "$_f.$((i+1))"; i=$((i-1)); done
    mv "$_f" "$_f.1"
  fi
}

# npm install падает под полностью герметичным env -i (SIGABRT в idealTree,
# проверено на Ubuntu 24.04 arm64: 2/2 краша; с окружением хоста минус PREFIX — OK).
# npm-шаги ОБЯЗАНЫ: caller env минус PREFIX (фермы сборки текут PREFIX=... который
# молча перенаправляет global install мимо /opt/node) + явный guest PATH +
# явный `npm --prefix /opt/node`. Рантайм node/dsh под env -i проверен — ему можно.
npm_guest_path() { echo "/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; }
