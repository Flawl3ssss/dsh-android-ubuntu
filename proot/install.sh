#!/system/bin/sh
# install.sh — one-shot proot bootstrap on the Android device (or in CI with $APP_FILES set).
# Steps: extract proot libs from APK -> fetch+verify rootfs -> unpack ->
#        install pinned node -> npm install pinned dsh -> smoke test.
# Fails closed on any checksum mismatch. Idempotent: skips finished steps via stamp files.
# Env overrides: APP_FILES (default: script dir), APK_PATH, DISTRO_JSON.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
DISTRO_JSON="${DISTRO_JSON:-$HERE/distro.json}"
APP_FILES="${APP_FILES:-$HERE}"
APK_PATH="${APK_PATH:-}"

LIBDIR="$APP_FILES/proot/lib"
ROOTFS_CANDIDATE="$APP_FILES/proot/rootfs"
# A/B-ready: if update-guard's 'current' symlink exists, install into it; else ./rootfs
if [ -L "$APP_FILES/proot/current" ]; then ROOTFS="$(readlink -f "$APP_FILES/proot/current")"; else ROOTFS="$ROOTFS_CANDIDATE"; fi
STAMPS="$APP_FILES/proot/.stamps"

log() { echo "[install] $*"; }
die() { echo "[install] FATAL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

json() { # tiny json field extractor: json <dotted.path>
  python3 - "$DISTRO_JSON" "$1" <<'PYEOF'
import json,sys
doc=json.load(open(sys.argv[1]))
cur=doc
for p in sys.argv[2].split('.'):
    cur=cur[p]
print(cur if not isinstance(cur,(dict,list)) else json.dumps(cur))
PYEOF
}

mkdir -p "$LIBDIR" "$ROOTFS" "$STAMPS"

# ---- 1. proot loader libs (from APK, never /usr/bin/proot) ----
if [ ! -f "$STAMPS/libs.done" ]; then
  log "extracting proot libs from APK..."
  [ -n "$APK_PATH" ] || die "APK_PATH not set (path to the built APK containing lib/arm64-v8a/libproot.so)"
  [ -f "$APK_PATH" ] || die "APK not found: $APK_PATH"
  need unzip
  unzip -o -j "$APK_PATH" 'lib/arm64-v8a/libproot.so' 'lib/arm64-v8a/libtalloc.so' 'lib/arm64-v8a/libandroid-shmem.so' -d "$LIBDIR" \
    || die "unzip of proot libs failed"
  if command -v readelf >/dev/null 2>&1; then
    readelf -d "$LIBDIR/libproot.so" | grep -q 'libtalloc.so' || die "libproot.so does not link libtalloc.so — wrong file?"
    readelf -d "$LIBDIR/libproot.so" | grep -q 'libandroid-shmem.so' || die "libproot.so does not link libandroid-shmem.so — wrong file?"
  fi
  # smoke: run through the Android linker (the ONLY supported invocation)
  /system/bin/linker64 "$LIBDIR/libproot.so" --version >/dev/null 2>&1 \
    || die "linker64 libproot.so --version failed (broken loader bundle?)"
  date > "$STAMPS/libs.done"
  log "libs OK"
else
  log "libs: cached, skip"
fi

# ---- 2. rootfs download + verify + unpack ----
if [ ! -f "$STAMPS/rootfs.done" ]; then
  log "fetching rootfs..."
  need curl
  RF_URL="$(json rootfs.url)"; RF_SHA="$(json rootfs.sha256)"
  case "$RF_SHA" in FILL-IN*) die "distro.json rootfs.sha256 not filled — refuse to install unverified rootfs";; esac
  TMP_TARBALL="$APP_FILES/proot/rootfs.tar.xz"
  curl -fSL --retry 3 -o "$TMP_TARBALL" "$RF_URL" || die "rootfs download failed"
  echo "$RF_SHA  $TMP_TARBALL" | sha256sum -c - || die "rootfs CHECKSUM MISMATCH"
  need tar
  tar -xJf "$TMP_TARBALL" -C "$ROOTFS" || die "rootfs unpack failed"
  rm -f "$TMP_TARBALL"
  echo "dsh-android" > "$ROOTFS/etc/hostname" 2>/dev/null || true
  mkdir -p "$ROOTFS/phone/Download" "$ROOTFS/phone/DCIM" "$ROOTFS/dsh-home" "$ROOTFS/opt"
  date > "$STAMPS/rootfs.done"
  log "rootfs OK"
else
  log "rootfs: cached, skip"
fi

# ---- 3. node (pinned, verified) ----
if [ ! -f "$STAMPS/node.done" ]; then
  log "installing node..."
  NODE_URL="$(json node.tarball)"; NODE_SHA="$(json node.sha256)"
  case "$NODE_SHA" in FILL-IN*) die "distro.json node.sha256 not filled — refuse to install unverified node";; esac
  TMP_NODE="$APP_FILES/proot/node.tar.xz"
  curl -fSL --retry 3 -o "$TMP_NODE" "$NODE_URL" || die "node download failed"
  echo "$NODE_SHA  $TMP_NODE" | sha256sum -c - || die "node CHECKSUM MISMATCH"
  mkdir -p "$APP_FILES/proot/node-stage"
  tar -xJf "$TMP_NODE" -C "$APP_FILES/proot/node-stage" || die "node unpack failed"
  rm -f "$TMP_NODE"
  # rootfs is just a dir on host: copy straight into guest /opt/node
  rm -rf "$ROOTFS/opt/node"
  mv "$APP_FILES/proot/node-stage"/node-*-linux-arm64 "$ROOTFS/opt/node"
  rmdir "$APP_FILES/proot/node-stage" 2>/dev/null || true
  date > "$STAMPS/node.done"
  log "node OK"
else
  log "node: cached, skip"
fi

# ---- 4. dsh (pinned npm version, inside guest) ----
if [ ! -f "$STAMPS/dsh.done" ]; then
  log "installing dsh inside guest..."
  DSH_PKG="$(json dsh.npm_package)@$(json dsh.version)"
  # npm runs INSIDE proot so anything arch-sensitive targets the guest userland
  sh "$HERE/launch-dsh.sh" exec -- npm install -g "$DSH_PKG" \
    || die "guest npm install $DSH_PKG failed"
  date > "$STAMPS/dsh.done"
  log "dsh OK"
else
  log "dsh: cached, skip"
fi

log "install complete. Run: sh $HERE/launch-dsh.sh start"
