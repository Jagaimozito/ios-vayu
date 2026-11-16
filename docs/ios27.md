# iOS 27.2 on OnePlus 7 Pro (guacamole)

**Status snapshot: 2026-11-16.** This is an experimental port of the iOS 27.2 (24B119) userland for iPhone15,2 / D73AP to the OnePlus 7 Pro (SM8150, Adreno 640). The device tree presents the D73/iPhone 14 Pro identity while the kernel and drivers adapt the hardware to Guacamole. This status separates confirmed behavior from features that only build or have been observed inconsistently.

## Confirmed working

- **Boot and system UI:** iOS 27.2 reaches the lock screen and SpringBoard when selected from the triple-boot shim. Use the triple-boot image workflow; standalone iOS images are not known to boot on this setup.
- **Touch and navigation:** touch input works well enough to use Settings, launch apps, and navigate the UI.
- **System apps:** the rebuilt root image places staged system apps in `/Applications`, avoiding the iOS installer's APFS-only staging path on this HFS+ root. Filza was installed separately and the user confirmed it opens.
- **Brightness and Night Shift:** the user confirmed both the brightness slider and Night Shift work through `sweet-displayd` and the D73 backlight properties.
- **Haptics, partially:** keyboard haptics and ringtone haptics work. The motor also buzzed during an actuator/init test.
- **Network access, intermittently:** Wi-Fi can associate with an access point, and SSH has worked over the resulting network connection.

## Partial or unreliable

- **Metal and GPU rendering:** the NativeAdrenoMetal/Turnip path has initialized in some boots and can render parts of the UI. Rendering is not dependable: Subway Surfers has shown a black screen shortly after launch, and earlier runs flickered or froze. GPU hangs have also required recovery work. Do not treat Metal app compatibility as complete.
- **Wi-Fi:** association has succeeded, but iOS may report “failed to join” even when connected. DHCP, link stability, saved-password behavior, and automatic reconnection have not been consistently verified. SSH can drop during a reconnect.
- **Audio:** a test tone was heard once, but game audio was absent in the latest report. Built-in speaker playback is therefore not reliable; microphone input has not been confirmed.
- **Haptics:** Settings switches and long-press/app-icon feedback still do not work, despite keyboard and ringtone patterns working.
- **Performance:** the UI has felt slow and sometimes unusable. A profiler capture showed `PerfPowerServices` near 100% CPU and `wland` using CPU, but the cause and current contribution have not been established.
- **Device identity:** the generated device tree uses the iPhone 14 Pro/D73 identity. That does not mean every identity-dependent feature or app behaves as on a real iPhone 14 Pro.

## Not working or not implemented

- **Bluetooth:** the Settings toggle has been unstable (including becoming greyed out); usable Bluetooth connections have not been confirmed. The current investigation points to BlueTool/controller profile and service matching, not a finished Bluetooth port.
- **Full 8 GB RAM use:** iOS currently reports about 4.24 GB managed (`hw.memsize=4239392768`) despite 8 GB installed. Safely adding the other DRAM ranges while preserving GPU reservations remains unresolved.
- **Cellular calls/data, camera, GPS, NFC, and most onboard sensors:** no working end-to-end port has been demonstrated.
- **Complete iOS haptic coverage:** system UI and CoreHaptics patterns remain incomplete, as described above.

## Build and boot notes

- The current kernel source is the separate `work/xnu-12377` Git repository. Metal plugin work is in the separate `work/UniXNU` repository; neither is included in commits to this repository unless separately committed and pushed.
- The iOS 27.2 root image is built by `tools/mkios27root-mac.sh`. The existing data partition is named `ios26`, so the iOS 27 boot arguments commonly use `ufsroot=ios26`; the name is a partition label, not the OS version.
- Boot the combined selector/triple-boot image and choose iOS 27. Avoid treating a standalone wrapper image as bootable unless a specific build has been confirmed on the phone.
- `NOTES.md` is the detailed engineering log. Its entries include experiments and hypotheses; a build or source-level change alone is not evidence of runtime success.

## Reporting status changes

When updating this page, label a feature **working** only after a runtime check on the phone. Keep build success, static analysis, and a user-visible runtime result distinct. Include the date and the exact image or configuration for important changes.
