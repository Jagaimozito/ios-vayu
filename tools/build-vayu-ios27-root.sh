#!/usr/bin/env bash
# Build the lowered arm64e -> arm64 iOS 27.2.1 (24B156, iPhone12,1) case-sensitive
# journaled HFS+ root image and Android sparse image for POCO X3 Pro (vayu, Kryo 485 ARMv8.2-A)
# inside WSL2 Linux using /mnt/e/ios-vayu-work.
#
# Usage (inside WSL2):
#   sudo OVERLAY_DIR=/path/to/overlay bash tools/build-vayu-ios27-root.sh
#
# Apple IPSW/DMG artifacts and output images stay strictly in /mnt/e/ios-vayu-work (never in git).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="${WORK_DIR:-/mnt/e/ios-vayu-work}"
IN="$W/inputs"
SK="$W/scion-kernel"
T27="$SK/tools/ios27"
PIPE="$T27/fullroot/pipeline"
OVERLAY="${OVERLAY_DIR:-$W/overlay}"
SIZE_GB="${SIZE_GB:-24}"
RAW_IMG="$W/ios27-root.img"
SIMG="$W/ios27-root.simg"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo OVERLAY_DIR=$OVERLAY bash $0" >&2
  exit 2
fi

for f in os.dmg systemos.dmg appos.dmg; do
  [[ -f "$IN/$f" ]] || { echo "Missing $IN/$f" >&2; exit 1; }
done
[[ -d "$SK/tools/ios27" ]] || { echo "Missing $SK/tools/ios27" >&2; exit 1; }
[[ -f "$OVERLAY/usr/lib/s.dylib" ]] || { echo "Missing compositor $OVERLAY/usr/lib/s.dylib" >&2; exit 1; }

if ! python3 -c "import numpy" 2>/dev/null; then
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-numpy >/dev/null
fi

MNT_BASE="/tmp/vayu-ios27-mnt"
mkdir -p "$MNT_BASE"/{os,sysos,appos,root}
LOOP_DEV=""

cleanup() {
  set +e
  for m in "$MNT_BASE/root" "$MNT_BASE/appos" "$MNT_BASE/sysos" "$MNT_BASE/os"; do
    mountpoint -q "$m" && umount "$m"
  done
  [[ -n "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV" 2>/dev/null
  rm -f "$MNT_BASE"/*.dmg
}
trap cleanup EXIT

mount_apfs() {
  local dmg="$1" name="$2"
  ln -sf "$dmg" "$MNT_BASE/$name.dmg"
  mountpoint -q "$MNT_BASE/$name" || apfs-fuse "$MNT_BASE/$name.dmg" "$MNT_BASE/$name"
}

echo "=== [1/7] Mounting OS, SystemOS, and AppOS APFS images via apfs-fuse ==="
mount_apfs "$IN/os.dmg" os
mount_apfs "$IN/systemos.dmg" sysos
mount_apfs "$IN/appos.dmg" appos

OS_ROOT="$MNT_BASE/os/root"
SYS_ROOT="$MNT_BASE/sysos/root"
APP_ROOT="$MNT_BASE/appos/root"
STOCK_DSC_DIR="$SYS_ROOT/System/Library/Caches/com.apple.dyld"
[[ -f "$STOCK_DSC_DIR/dyld_shared_cache_arm64e" ]] || { echo "No dyld_shared_cache_arm64e in $STOCK_DSC_DIR" >&2; exit 1; }

CACHE_OUT="$W/cache-arm64"
if [[ ! -f "$CACHE_OUT/.done" ]]; then
  echo "=== [2/7] Copying and lowering iOS 27.2.1 (24B156) dyld shared cache for Kryo 485 (ARMv8.2-A) ==="
  rm -rf "$CACHE_OUT"
  mkdir -p "$CACHE_OUT"
  cp -p "$STOCK_DSC_DIR"/dyld_shared_cache_arm64e* "$CACHE_OUT/"
  CACHE_M="$CACHE_OUT/dyld_shared_cache_arm64e"
  CC_SKIP=(libcorecrypto_noasm libcorecrypto_trace)

  echo "  -> 2a: a64e-rewrite (in-place PAC -> plain arm64)"
  python3 -I "$T27/a64e/a64e-rewrite.py" cache "$CACHE_M" --skip "${CC_SKIP[@]}" --log "$W/a64e-cache.log"
  echo "  -> 2b: stubscan --fix (subcache stub islands)"
  python3 -I "$PIPE/cache/stubscan.py" "$CACHE_M" --fix
  echo "  -> 2c: a64e-rewrite2 (PACGA & LDRAx writeback)"
  python3 -I "$T27/speed/a64e-rewrite2.py" cache "$CACHE_M" --skip "${CC_SKIP[@]}"
  echo "  -> 2d: cachepatch (5 verified 24B156 shared-cache fixes)"
  while read -r va exp new rest; do
    [[ "$va" == \#* || -z "$va" ]] && continue
    python3 -I "$T27/speed/cachepatch.py" "$CACHE_OUT" "$va" "$exp" "$new"
  done < "$T27/s9/patches-24B156.txt"
  echo "  -> 2e: fips-seal (recompute & verify libcorecrypto FIPS HMAC)"
  python3 -I "$T27/a64e/fips-seal.py" reseal "$CACHE_M" --ref "$STOCK_DSC_DIR/dyld_shared_cache_arm64e"
  python3 -I "$T27/a64e/fips-seal.py" check "$CACHE_M" --ref "$STOCK_DSC_DIR/dyld_shared_cache_arm64e"
  touch "$CACHE_OUT/.done"
else
  echo "=== [2/7] Reusing already-lowered dyld shared cache in $CACHE_OUT ==="
fi

echo "=== [3/7] Formatting ${SIZE_GB}G case-sensitive journaled HFS+ volume at $RAW_IMG ==="
rm -f "$RAW_IMG" "$SIMG"
truncate -s "${SIZE_GB}G" "$RAW_IMG"
mkfs.hfsplus -s -J -v iOSRoot27 "$RAW_IMG"
LOOP_DEV=$(losetup -f --show "$RAW_IMG")
mount -t hfsplus -o force "$LOOP_DEV" "$MNT_BASE/root"
R="$MNT_BASE/root"

echo "=== [4/7] Staging OS, SystemOS (with lowered cache), and AppOS into HFS+ ==="
rsync -aH --numeric-ids --exclude='/private/var/staged_system_apps/*' "$OS_ROOT/" "$R/"
mkdir -p "$R/private/preboot/Cryptexes/OS" "$R/private/preboot/Cryptexes/App"
rsync -aH --numeric-ids --exclude='/System/Library/Caches/com.apple.dyld/*' "$SYS_ROOT/" "$R/private/preboot/Cryptexes/OS/"
rsync -aH --numeric-ids "$APP_ROOT/" "$R/private/preboot/Cryptexes/App/"

CDST="$R/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld"
mkdir -p "$CDST" "$R/System/Library/Caches/com.apple.dyld"
for f in "$CACHE_OUT"/dyld_shared_cache_arm64e*; do
  cp -p "$f" "$CDST/"
  chown 0:0 "$CDST/${f##*/}"
  ln -f "$CDST/${f##*/}" "$R/System/Library/Caches/com.apple.dyld/${f##*/}"
done

echo "  -> Hard-linking Cryptex counterparts into / ..."
for c in OS App; do
  src_base="$R/private/preboot/Cryptexes/$c"
  while IFS= read -r -d '' file; do
    rel="${file#"$src_base"/}"
    [[ "$rel" == System/Library/Caches/com.apple.dyld/* ]] && continue
    target="$R/$rel"
    [[ -e "$target" || -L "$target" ]] && continue
    mkdir -p "${target%/*}"
    if [[ -L "$file" ]]; then
      cp -P "$file" "$target"
    else
      ln "$file" "$target"
    fi
  done < <(find "$src_base" ! -type d -print0)
done

# Install essential stock apps from staged_system_apps (skip bulky optional ones if desired to keep image fast)
if [[ -d "$OS_ROOT/private/var/staged_system_apps" ]]; then
  for bundle in "$OS_ROOT/private/var/staged_system_apps"/*.app; do
    [[ -d "$bundle" ]] || continue
    name="${bundle##*/}"
    rsync -aH --numeric-ids "$bundle" "$R/Applications/"
    chown -R 0:0 "$R/Applications/$name"
    rm -rf "$R/System/Library/AppPlaceholders/$name"
  done
fi

echo "=== [5/7] Lowering standalone arm64e Mach-O binaries on HFS+ ==="
python3 -I "$PIPE/root/macho-rewrite.py" "$T27/a64e/a64e-rewrite.py" "$R"

echo "=== [6/7] Applying launchd, FIPS, preferences, keybag, userland compositor, and vayu firmware ==="
# Patch launchd Boot.fips -N and disable sysstatuscheck reboot
python3 "$REPO/tools/launchd-fips-noverify.py" "$R/sbin/launchd" /tmp/vayu-launchd.new --no-reboot-task sysstatuscheck
cat /tmp/vayu-launchd.new > "$R/sbin/launchd"
rm -f /tmp/vayu-launchd.new

# Prune unsupported hardware/crash-loop daemons and drop _PanicOnCrash
python3 "$T27/fullroot/steps.d/edit-launchd.py" "$R" "$T27/fullroot/lists" --set bp --hogs

# Disable MessagesBlastDoorService.xpc crash-loop
XPC_DIR="$R/System/Library/PrivateFrameworks/MessagesBlastDoorSupport.framework/XPCServices"
if [[ -d "$XPC_DIR/MessagesBlastDoorService.xpc" ]]; then
  mv "$XPC_DIR/MessagesBlastDoorService.xpc" "$XPC_DIR/MessagesBlastDoorService.xpc.disabled"
fi

# Preferences: skip Setup (purplebuddy), disable AFBC/deep framebuffer, disable SpringBoard watchdogs
python3 "$T27/fullroot/steps.d/edit-prefs.py" "$R"
PREF_DIR="$R/private/var/mobile/Library/Preferences"
install -d -o 501 -g 501 -m 0755 "$PREF_DIR"
for f in com.apple.purplebuddy.plist com.apple.purplebuddy.notbackedup.plist com.apple.backboardd.plist .GlobalPreferences.plist; do
  install -o 501 -g 501 -m 0600 "$REPO/tools/ios27root/$f" "$PREF_DIR/$f"
done
install -d -o 0 -g 0 -m 0755 "$R/private/var/preferences/SystemConfiguration"
install -o 0 -g 0 -m 0644 "$REPO/tools/ios27root/preferences.plist" "$R/private/var/preferences/SystemConfiguration/preferences.plist"

# logd directories & systembag.kb
DB_DIR="$R/private/var/db"
install -d -o 272 -g 272 -m 0751 "$DB_DIR/diagnostics"
install -d -o 272 -g 272 -m 0755 "$DB_DIR/uuidtext" "$DB_DIR/diagnostics/timesync"
for d in diagnostics uuidtext diagnostics/timesync; do
  install -o 272 -g 272 -m 0644 /dev/null "$DB_DIR/$d/.migrated"
done
install -d -o 0 -g 0 -m 0700 "$R/private/var/keybags"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' \
  > "$R/private/var/keybags/systembag.kb"
chown 0:0 "$R/private/var/keybags/systembag.kb"
chmod 0600 "$R/private/var/keybags/systembag.kb"

# Install userland compositor overlay (sbca.dylib, s.dylib, m.dylib, libsbgl.dylib, libOSMesa.8.dylib, Turnip, cc_fips_test, tools)
[[ -e "$R/usr/libexec/cc_fips_test.orig" ]] || cp -p "$R/usr/libexec/cc_fips_test" "$R/usr/libexec/cc_fips_test.orig"
while IFS= read -r f; do
  f="${f#./}"
  mkdir -p "$R/$(dirname "$f")"
  cp -p "$OVERLAY/$f" "$R/$f"
  chown 0:0 "$R/$f"
done < <(cd "$OVERLAY" && find . -type f ! -name MANIFEST.sha256 | sort)
chmod 0755 "$R/usr/lib/sbca.dylib" "$R/usr/lib/s.dylib" "$R/usr/local/starbite/lib"/*.dylib "$R/usr/libexec/cc_fips_test"
[[ -f "$R/usr/lib/m.dylib" ]] && chmod 0755 "$R/usr/lib/m.dylib"
[[ -d "$R/private/var/local/bin" ]] && chmod 0755 "$R/private/var/local/bin"/* || true
install -d -m 0777 "$R/private/var/local" "$R/private/var/local/oslog" "$R/private/var/local/m2v-cache" "$R/private/var/tmp"
chmod 0755 "$R/private/var/local"

# Stage POCO X3 Pro (vayu) vendor firmware (Adreno 640 + Novatek NT36675 touch + WLAN/BT)
install -d -o 0 -g 0 -m 0755 "$R/fw" "$R/usr/standalone/firmware/sweet"
if [[ -d "$REPO/fw-vayu/gpu" ]]; then
  cp -f "$REPO/fw-vayu/gpu"/* "$R/fw/" 2>/dev/null || true
  cp -f "$REPO/fw-vayu/gpu"/* "$R/usr/standalone/firmware/sweet/" 2>/dev/null || true
fi
find "$REPO/fw-vayu" -type f -name '*novatek*' -exec cp -f {} "$R/fw/" \; 2>/dev/null || true
chown -R 0:0 "$R/fw" "$R/usr/standalone/firmware/sweet"

sync
df -h "$R"

echo "=== [7/7] Unmounting, verifying HFS+ catalog (fsck.hfsplus), and building sparse image ==="
umount "$R"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

fsck.hfsplus -f -y "$RAW_IMG" | grep -v 'Illegal name' || true
fsck.hfsplus -f -n "$RAW_IMG"

# Free cache-arm64 copy before creating sparse image if E: free space is below 18 GB
FREE_KB=$(df -k "$W" | awk 'NR==2 {print $4}')
if (( FREE_KB < 18 * 1024 * 1024 )); then
  echo "Freeing temporary $CACHE_OUT to keep E: headroom..."
  rm -rf "$CACHE_OUT"
fi

python3 "$REPO/tools/hfs2simg.py" "$RAW_IMG" "$SIMG"
ls -lh "$RAW_IMG" "$SIMG"
sha256sum "$SIMG" | tee "$SIMG.sha256"
echo "=== VAYU iOS 27.2.1 ROOTFS READY: $SIMG ==="
