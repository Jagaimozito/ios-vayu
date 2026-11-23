#!/bin/bash
# Install sweet-displayd as a launchd job on the running phone (binary already at /var/local/bin/sweet-displayd),
# also into launchd's job cache so it starts at every boot.  ssh guacmac 'bash -s' < tools/macos27-displayd-install.sh
set -e
J=/System/Library/LaunchDaemons/com.sweet.displayd.plist
cat > $J.new <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.sweet.displayd</string>
<key>ProgramArguments</key><array><string>/var/local/bin/sweet-displayd</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>
<key>StandardErrorPath</key><string>/var/local/sweet-displayd.log</string>
</dict></plist>
PL
chown 0:0 $J.new; chmod 644 $J.new; mv $J.new $J
C=/System/Library/xpc/launchd.plist
[ -e $C.pre-displayd ] || cat $C > $C.pre-displayd
plutil -convert xml1 -o /tmp/ld.xml $C
/usr/libexec/PlistBuddy -c "Delete :LaunchDaemons:$J" /tmp/ld.xml 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LaunchDaemons:$J dict" /tmp/ld.xml
/usr/libexec/PlistBuddy -c "Merge $J :LaunchDaemons:$J" /tmp/ld.xml
plutil -convert binary1 -o $C.new /tmp/ld.xml && chown 0:0 $C.new && chmod 644 $C.new && mv $C.new $C
launchctl bootstrap system $J 2>&1 || launchctl kickstart -k system/com.sweet.displayd
sleep 2; launchctl print system/com.sweet.displayd | grep -E 'state =|pid =' ; tail -5 /var/local/sweet-displayd.log
