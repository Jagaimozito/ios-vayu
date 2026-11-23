#!/bin/bash
# What the macOS 27 root needs beyond Apple's files, to be reached over Wi-Fi + SSH (2026-11-20). Applied to a mounted
# root: by tools/mkmacos27root-mac.sh while it builds the image, or by tools/macos27-patch-cdr.sh to an existing
# research/macos27/macos27-root.cdr.
#
#   tools/macos27-extras.sh ROOT          (ROOT = the mounted volume; needs sudo)
#
# Installs (local files only, never in git):
#   userland/out/macos/wland (userland/build-macos.sh)        -> /var/local/bin/wland; job /System/Library/LaunchDaemons/
#       com.sweet.wland.plist (+ launchd.plist cache) (wland up 0; its log in /var/local/wland.out; the DHCP lease line also on the console:
#       "SWEET WLAND: Wi-Fi up, ... ssh root@ADDRESS")
#   research/ios27.2/extras/fw/{modem,rmtfs}                   -> /var/local/fw (the modem's Wi-Fi firmware, EFS copies)
#   research/ios27.2/extras/wlan.conf                          -> /var/local/wlan.conf (0600)
#   research/ios27.2/extras/authorized_keys                    -> /var/root/.ssh/authorized_keys (root, key only)
#   research/macos27/ssh_host_keys/ (made once here, reused)   -> /etc/ssh/ssh_host_*: the same SSH identity every build
#   research/ios27.2/extras/fw/gpu                             -> /usr/standalone/firmware/sweet
#   com.sweet.diag: wland / address / cfprefsd status on the console every 30 s (bring-up)
#   macOS's own sshd (com.openssh.sshd) enabled through launchd's override database
#       (/var/db/com.apple.xpc.launchd/disabled.plist)
#   com.apple.clocksyncd disabled there (it blocks WindowServer: NOTES.md)
#   com.apple.bluetoothd disabled there (it blocks the Language Chooser: NOTES.md)
#   work/UniXNU/build/adreno-metal-plugin-macos27/NativeAdrenoMetal.bundle (METAL_BUNDLE) -> /System/Library/Extensions,
#       + NativeAdrenoMetal.publish
set -euo pipefail
R=${1:?usage: macos27-extras.sh ROOT}
REPO="$(cd "$(dirname "$0")/.." && pwd)"
X="$REPO/research/ios27.2/extras"
U="$REPO/userland/out/macos"
sudo test -d "$R/System/Library/CoreServices" || { echo "$R does not look like the macOS root" >&2; exit 1; }

# Wi-Fi
[ -x "$U/wland" ] || { echo "missing $U/wland: run sh userland/build-macos.sh first" >&2; exit 1; }
for d in modem rmtfs; do
	[ -d "$X/fw/$d" ] || { echo "missing $X/fw/$d (the phone's modem firmware, userland/wland/README.md)" >&2; exit 1; }
done
L="$R/private/var/local"
sudo install -d -o 0 -g 0 -m 0755 "$L" "$L/bin" "$L/fw"
sudo install -o 0 -g 0 -m 0755 "$U/wland" "$L/bin/wland"
# hfs.util wrapper: macOS 27's hfs.util -p reports FSUR_IO_FAIL for a mounted HFS volume (the kernel-mounted root),
# so Disk Arbitration never recognised disk0 as mounted; the wrapper passes that one case on as recognised.
H="$R/System/Library/Filesystems/hfs.fs/Contents/Resources"
if [ ! -e "$H/hfs.util.real" ]; then sudo mv "$H/hfs.util" "$H/hfs.util.real"; fi
sudo install -o 0 -g 0 -m 0755 "$REPO/userland/macos/hfs.util.sh" "$H/hfs.util"
# netsvc (macOS, scutil): wland publishes each DHCP lease to configd with it; without it apps had no DNS.
sudo install -o 0 -g 0 -m 0755 "$REPO/userland/macos/netsvc.sh" "$L/bin/netsvc"
for d in modem rmtfs; do
	sudo rm -rf "$L/fw/$d"
	sudo cp -R "$X/fw/$d" "$L/fw/$d"
done
sudo chown -R 0:0 "$L/fw"
if [ -f "$X/wlan.conf" ]; then
	sudo install -o 0 -g 0 -m 0600 "$X/wlan.conf" "$L/wlan.conf"
else
	echo "WARNING: no $X/wlan.conf: wland starts the radio but joins no network" >&2
fi
# Jobs go into /System/Library/LaunchDaemons AND launchd's job cache /System/Library/xpc/launchd.plist (end of this
# script): 2026-11-20, jobs only in /Library/LaunchDaemons never started (no "SWEET WLAND: starting" on the console).
sudo rm -f "$R/Library/LaunchDaemons/com.sweet.wland.plist" "$R/Library/LaunchDaemons/com.sweet.diag.plist"
J="$R/System/Library/LaunchDaemons/com.sweet.wland.plist"
# WLAND_NO_BRIDGE: macOS has no iOS wifid to drive /dev/wlan; wland joins wlan.conf itself and runs DHCP on a utun.
# 2026-11-20: through /bin/sh so the console says it started (the first macOS boot showed no sign of wland at all).
sudo python3 - "$J" <<'PYEOF'
import plistlib, sys
plistlib.dump({'Label': 'com.sweet.wland', 'ProgramArguments': ['/bin/sh', '-c',
               'echo "SWEET WLAND: starting (log /var/local/wland.out)" > /dev/console; '
               'export WLAND_NO_BRIDGE=1; exec /var/local/bin/wland up 0 >> /var/local/wland.out 2>&1'], 'RunAtLoad': True,
               'POSIXSpawnType': 'Interactive'}, open(sys.argv[1], 'wb'))
PYEOF
sudo chown 0:0 "$J"; sudo chmod 0644 "$J"
echo "wland: /var/local/bin/wland, firmware, job com.sweet.wland"

# GPU firmware for the kernel's Adreno driver (the macOS boot log: a640_gmu.bin, a630_sqe.fw, a640_zap.* missing).
if [ -d "$X/fw/gpu" ]; then
	sudo install -d -o 0 -g 0 -m 0755 "$R/usr/standalone/firmware/sweet"
	sudo cp -R "$X/fw/gpu/." "$R/usr/standalone/firmware/sweet/"
	sudo chown -R 0:0 "$R/usr/standalone/firmware/sweet"
	sudo find "$R/usr/standalone/firmware/sweet" -type f -exec chmod 0644 {} \;
	echo "GPU firmware -> /usr/standalone/firmware/sweet"
fi

# Bring-up diagnostics on the console, while there is no shell: every 30 s from 45 s after launch, the newest wland
# lines, the addresses, and cfprefsd's last exit as launchd saw it (it exits -2 in a loop).
D2="$R/System/Library/LaunchDaemons/com.sweet.diag.plist"
sudo install -m 0755 "$REPO/userland/macos/sweet-diag.sh" "$L/bin/sweet-diag.sh"
sudo chown 0:0 "$L/bin/sweet-diag.sh"; sudo chmod 0755 "$L/bin/sweet-diag.sh"
sudo python3 - "$D2" <<'PYEOF'
import plistlib, sys
plistlib.dump({'Label': 'com.sweet.diag', 'ProgramArguments': ['/bin/sh', '/var/local/bin/sweet-diag.sh'],
               'RunAtLoad': True, 'POSIXSpawnType': 'Interactive'}, open(sys.argv[1], 'wb'))
PYEOF
sudo chown 0:0 "$D2"; sudo chmod 0644 "$D2"
echo "diag: com.sweet.diag (console lines SWEET DIAG)"

# SSH: root by key only (macOS sshd default PermitRootLogin prohibit-password)
[ -f "$X/authorized_keys" ] || { echo "missing $X/authorized_keys" >&2; exit 1; }
sudo install -d -o 0 -g 0 -m 0750 "$R/private/var/root"
sudo install -d -o 0 -g 0 -m 0700 "$R/private/var/root/.ssh"
sudo install -o 0 -g 0 -m 0600 "$X/authorized_keys" "$R/private/var/root/.ssh/authorized_keys"
hk="$REPO/research/macos27/ssh_host_keys"
sudo install -d -o 0 -g 0 -m 0755 "$R/private/etc/ssh"
if ls "$hk"/ssh_host_*_key >/dev/null 2>&1; then
	sudo cp "$hk"/ssh_host_* "$R/private/etc/ssh/"
	echo "ssh host keys: reused from $hk"
else
	mkdir -p "$hk"
	for t in ed25519 ecdsa rsa; do ssh-keygen -q -t "$t" -N '' -C "guacamole-macos27" -f "$hk/ssh_host_${t}_key"; done
	chmod 0600 "$hk"/ssh_host_*_key
	sudo cp "$hk"/ssh_host_* "$R/private/etc/ssh/"
	echo "ssh host keys: made and saved to $hk"
fi
sudo chown 0:0 "$R/private/etc/ssh/"ssh_host_*
sudo chmod 0600 "$R/private/etc/ssh/"ssh_host_*_key
sudo chmod 0644 "$R/private/etc/ssh/"ssh_host_*.pub
sudo test -f "$R/System/Library/LaunchDaemons/ssh.plist" || sudo test -f "$R/System/Library/LaunchDaemons/com.openssh.sshd.plist" ||
	echo "WARNING: no sshd launchd plist found in /System/Library/LaunchDaemons" >&2
D="$R/private/var/db/com.apple.xpc.launchd"
sudo install -d -o 0 -g 0 -m 0755 "$D"
sudo python3 - "$D/disabled.plist" <<'PYEOF'
import os, plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb')) if os.path.exists(p) else {}
d['com.openssh.sshd'] = False
# clocksyncd waits forever for IOTimeSyncFamily's IOTimeSyncDaemonService (no such kext here) and never answers
# com.apple.timesync.expositor, so WindowServer hung in CAWindowServer init; with it off the lookup fails at once and
# CoreAnimation goes on without external display sync.
d['com.apple.clocksyncd'] = True
# bluetoothd: macOS Bluetooth is not brought up here and the daemon never answers; the Language Chooser (and Setup
# Assistant) waits forever in +[IOBluetoothHostController defaultController] before showing a window (black screen).
# With it off the lookups fail at once and the Language Chooser draws.
d['com.apple.bluetoothd'] = True
# AppSSODaemon aborts in PODaemonCoreProcess initForBaseSystem when its base-system string is NULL on this root.
d['com.apple.AppSSODaemon'] = True
# fskitd (FSKit) never answers storagekitd's question for the extension filesystems once Disk Arbitration knows the
# root (disk0): storagekitd waited forever, the login screen waited on it for the wallpaper's disk (only the cursor).
# With it off the question fails at once. FSKit only serves add-on filesystems (exFAT/FAT modules), not this HFS root.
d['com.apple.filesystems.fskitd'] = True
plistlib.dump(d, open(p, 'wb'))
print('launchd overrides:', d)
PYEOF
sudo chown 0:0 "$D/disabled.plist"; sudo chmod 0644 "$D/disabled.plist"
echo "sshd: enabled, root key installed"

# HFS+ does not recreate /var/run on each boot. Clear logind's first-run marker only once per kernel boot; the stamp
# prevents a launchd KeepAlive restart during the same boot from being mistaken for a fresh boot.
sudo install -o 0 -g 0 -m 0755 "$REPO/userland/macos/sweet-logind-start.sh" "$L/bin/sweet-logind-start.sh"
LOGIND="$R/System/Library/LaunchDaemons/com.apple.logind.plist"
sudo test -f "$LOGIND" || { echo "missing $LOGIND" >&2; exit 1; }
sudo python3 - "$LOGIND" <<'PYEOF'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
d['ProgramArguments'] = ['/bin/sh', '/var/local/bin/sweet-logind-start.sh']
with open(p, 'wb') as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
PYEOF
sudo chown 0:0 "$LOGIND"; sudo chmod 0644 "$LOGIND"
echo "logind: clears stale first-run marker once per boot"

# GPU: UniXNU's NativeAdrenoMetal plugin, macOS build (macOS bundle layout, Contents/MacOS with Turnip beside it), and the
# .publish marker (without it the plugin only runs its self-test and returns nil). The kernel names it in the
# accelerator's MetalPluginName; WindowServer aborts every 30 s while Metal has no device (NOTES.md).
MB=${METAL_BUNDLE:-$REPO/work/UniXNU/build/adreno-metal-plugin-macos27/NativeAdrenoMetal.bundle}
ext="$R/System/Library/Extensions"
if [ -f "$MB/Contents/MacOS/NativeAdrenoMetal" ] && [ -f "$MB/Contents/MacOS/libvulkan_freedreno.dylib" ]; then
	sudo rm -rf "$ext/NativeAdrenoMetal.bundle"
	sudo cp -R "$MB" "$ext/NativeAdrenoMetal.bundle"
	sudo chown -R 0:0 "$ext/NativeAdrenoMetal.bundle"
	sudo find "$ext/NativeAdrenoMetal.bundle" -type d -exec chmod 0755 {} \;
	sudo find "$ext/NativeAdrenoMetal.bundle" -type f -exec chmod 0644 {} \;
	sudo chmod 0755 "$ext/NativeAdrenoMetal.bundle/Contents/MacOS/NativeAdrenoMetal" \
		"$ext/NativeAdrenoMetal.bundle/Contents/MacOS/libvulkan_freedreno.dylib"
	sudo install -o 0 -g 0 -m 0644 /dev/null "$ext/NativeAdrenoMetal.publish"
	# The system shader cache the render server fills (UniXNU SharedShaderCache.h systemcache::kWriterPath): owner _windowserver
	# (88), mode 0755. UniXNU's kernel makes it at boot; here it is in the image (/private/var/tmp is not emptied at boot).
	# WindowServer's home is /var/empty, so without it the plugin has no cache directory of its own.
	sudo install -d -o 88 -g 0 -m 0755 "$R/private/var/tmp/NativeAdrenoMetal.cache"
	echo "GPU: NativeAdrenoMetal.bundle (macOS) from $MB ($(shasum -a 256 "$MB/Contents/MacOS/NativeAdrenoMetal" | cut -c1-16))"
else
	echo "WARNING: no macOS NativeAdrenoMetal bundle at $MB (set METAL_BUNDLE): WindowServer will have no Metal device" >&2
fi

# launchd's job cache: our two jobs added, sshd's Disabled cleared (macOS reads its jobs from this cache, as iOS does).
sudo python3 - "$R" <<'PYEOF'
import plistlib, sys
R = sys.argv[1]
p = R + '/System/Library/xpc/launchd.plist'
d = plistlib.load(open(p, 'rb'))
ld = d['LaunchDaemons']
for name in ('com.sweet.wland', 'com.sweet.diag'):
    key = '/System/Library/LaunchDaemons/%s.plist' % name
    ld[key] = plistlib.load(open(R + key, 'rb'))
logind_key = '/System/Library/LaunchDaemons/com.apple.logind.plist'
if logind_key in ld:
    ld[logind_key] = plistlib.load(open(R + logind_key, 'rb'))
else:
    print('WARNING: no com.apple.logind.plist in the launchd job cache')
ssh = ld.get('/System/Library/LaunchDaemons/ssh.plist')
if ssh is not None:
    ssh['Disabled'] = False
else:
    print('WARNING: no ssh.plist in the job cache')
data = plistlib.dumps(d, fmt=plistlib.FMT_BINARY)
with open(p, 'r+b') as f:	# in place: owner and mode stay
    f.write(data)
    f.truncate()
print('launchd.plist: com.sweet.wland, com.sweet.diag added; ssh enabled;', len(ld), 'jobs')
PYEOF
