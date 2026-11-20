#!/bin/zsh
# sweet-mgfix: re-apply the MobileGestalt answers this phone needs, whenever MobileGestalt's cache is new (fresh root,
# or a rebuild after a device-tree change drops hand-set answers). Boot job com.sweet.mgfix (tools/mkios27root-mac.sh).
# 2026-11-20. Changes take effect for processes that read them later; after the very first boot of a fresh root,
# reboot once (as for the IMEI).
#   WifiVendor USI                 BlueTool picks the Bluetooth chip's boot script by it (else no Bluetooth)
#   HasBaseband, cellular-data, telephony, CellularTelephonyCapability   cellular stack, Cellular settings row
#   DeviceSupportsHaptics, DeviceSupportsClosedLoopHaptics, ringer-switch
#   ArtworkTraits/ArtworkDeviceSubType 1792, ArtworkDeviceScaleFactor 2   the @2x (828x1792) layout, no rdar bar
cache=/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
mark=/var/local/mgfix.done
mg=/var/local/bin/mgtool
for i in {1..120}; do [ -f $cache ] && break; sleep 1; done
[ -f $cache ] || { echo "$(date) no MobileGestalt cache after 120 s"; exit 0; }
if [ -f $mark ] && [ ! $cache -nt $mark ]; then echo "$(date) cache unchanged, nothing to do"; exit 0; fi
sleep 5	# let MobileGestalt finish writing a new cache
$mg setstr WifiVendor USI
for k in HasBaseband cellular-data telephony CellularTelephonyCapability DeviceSupportsHaptics \
	DeviceSupportsClosedLoopHaptics ringer-switch; do $mg setbool $k true; done
$mg setint ArtworkTraits/ArtworkDeviceSubType 1792
$mg setint ArtworkTraits/ArtworkDeviceScaleFactor 2
touch $mark
echo "$(date) MobileGestalt answers applied (reboot once if this was the first boot of a fresh root)"
