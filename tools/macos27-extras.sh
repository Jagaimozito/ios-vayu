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
plistlib.dump(d, open(p, 'wb'))
print('launchd overrides:', d)
PYEOF
sudo chown 0:0 "$D/disabled.plist"; sudo chmod 0644 "$D/disabled.plist"
echo "sshd: enabled, root key installed"

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
