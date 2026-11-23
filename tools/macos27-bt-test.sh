#!/bin/sh
# macOS 27 Bluetooth bring-up, by hand (run on the phone as root). 2026-11-22.
#   macos27-bt-test.sh start    btbridge -p (pty at /dev/cu.BLTH), then bluetoothd from a copy of its job with
#                               BT_HCI_TRANSPORT=H4:POSIX. The job is enabled only to load it and disabled again at once, so
#                               a reboot comes back without bluetoothd (it used to hang the login screens).
#   macos27-bt-test.sh stop     bluetoothd and btbridge out
#   macos27-bt-test.sh status   processes, the pty link and the last lines of both logs
# BT_HCI_TRANSPORT is "transport:driver": H4 alone looks for a driver named H4 and fails ("HCI Driver H4 could not
# be matched"); POSIX is the serial-port driver (/dev/cu.BLTH). bluetoothd then waits for IOBluetoothHCIController
# (kernel 0019, SweetBluetooth.cpp). Needs /var/local/bin/btbridge (userland/out/macos/btbridge) and /var/local/fw/bt/crbtfw21.tlv + crnv21.bin.
JOB=/System/Library/LaunchDaemons/com.apple.bluetoothd.plist
T=/var/local/bt-test
case "$1" in
start)
	mkdir -p $T /etc/bluetool
	: > /etc/bluetool/SkipBluetoothFirmwareBoot   # btbridge boots the chip; BlueTool's Broadcom script is not wanted
	if ! pgrep -x btbridge >/dev/null; then
		nohup /var/local/bin/btbridge -p /dev/cu.BLTH > $T/btbridge.out 2>&1 &
		i=0
		while [ $i -lt 60 ] && [ ! -L /dev/cu.BLTH ]; do    # the firmware download alone takes ~22 s
			sleep 1; i=$((i + 1))
		done
	fi
	if [ ! -L /dev/cu.BLTH ]; then echo "btbridge did not make /dev/cu.BLTH:"; tail -20 $T/btbridge.out; exit 1; fi
	cp $JOB $T/com.apple.bluetoothd.plist
	/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:BT_HCI_TRANSPORT string H4:POSIX" $T/com.apple.bluetoothd.plist 2>/dev/null ||
		/usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:BT_HCI_TRANSPORT H4:POSIX" $T/com.apple.bluetoothd.plist
	/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $T/bluetoothd.err" $T/com.apple.bluetoothd.plist
	launchctl bootout system/com.apple.bluetoothd 2>/dev/null && sleep 1
	launchctl enable system/com.apple.bluetoothd
	launchctl bootstrap system $T/com.apple.bluetoothd.plist; echo "bootstrap: $?"
	launchctl disable system/com.apple.bluetoothd
	sleep 5; "$0" status ;;
stop)
	launchctl bootout system/com.apple.bluetoothd 2>/dev/null
	pkill -x btbridge; sleep 1; rm -f /dev/cu.BLTH; echo stopped ;;
status)
	ps ax -o pid,etime,command | grep -E "[b]luetoothd|[b]tbridge|[B]lueTool"
	ls -l /dev/cu.BLTH 2>&1
	launchctl print system/com.apple.bluetoothd 2>/dev/null | grep -E "state|pid|last exit|BT_HCI" 
	echo "== btbridge"; tail -25 $T/btbridge.out
	echo "== bluetoothd log"; log show --last 2m --predicate 'process == "bluetoothd"' --style compact 2>/dev/null |
		grep -i -E "transport|H4|UART|open|fatal|error|fail|controller|power" | tail -30 ;;
*) echo "usage: $0 start|stop|status"; exit 2 ;;
esac
