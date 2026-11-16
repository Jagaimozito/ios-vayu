# iOS 27.2 on OnePlus 7 Pro (guacamole)

This branch ports the **iOS 27.2 (24B119) userland for iPhone 14 Pro (iPhone15,2 / D73AP)** to the OnePlus 7 Pro (`guacamole`, Qualcomm SM8150 / Snapdragon 855, Adreno 640, 8 GB RAM). The device tree presents the D73 identity while the custom XNU kernel and userland drivers adapt the phone's hardware.

This is an experimental bring-up, not a daily-use phone OS. Many hardware features are incomplete, performance and graphics are unreliable, and the port disables or replaces parts of Apple's normal security and device stack. The iOS 16 port is maintained on a separate branch; this README describes the iOS 27 branch only.

## Current status

Status snapshot: **2026-11-16**. For detailed evidence, caveats, and engineering history, see [`docs/ios27.md`](docs/ios27.md) and [`NOTES.md`](NOTES.md).

### Working

- **Boot and system UI:** iOS 27.2 reaches the lock screen and SpringBoard when started through the triple-boot selector.
- **Shutdown and reboot:** shutdown and reboot work normally on iOS 27; rebooting through SSH has also been confirmed.
- **Touch and navigation:** touch input works for navigating the UI and launching apps.
- **System apps:** the rebuilt root image puts staged system apps in `/Applications`; Filza was separately installed and confirmed to open.
- **Brightness and Night Shift:** both were confirmed working by the user through the `sweet-displayd` daemon and D73 backlight properties.
- **Some haptics:** keyboard and ringtone haptics work; the actuator also buzzed during an initialization/test.
- **Basic network access:** Wi-Fi has associated with an access point, and SSH has worked while the network connection remained up.

### Partial or unreliable

- **Metal/GPU:** NativeAdrenoMetal and Turnip have initialized in some boots and can render parts of the UI. Subway Surfers has shown a black screen shortly after launch; earlier sessions flickered, froze, or triggered GPU recovery. App rendering is not reliable.
- **Wi-Fi:** association can succeed while iOS reports “failed to join.” DHCP, link stability, saving credentials, and automatic reconnection remain inconsistent; reconnecting can interrupt SSH.
- **Audio:** Settings sounds and keyboard clicks work. Game audio was absent in the latest report; microphone input is unconfirmed.
- **Haptics:** keyboard and ringtone patterns work; Settings switches and long-press/app-icon feedback do not.
- **Performance:** the UI has felt slow and at times unusable. One profiler capture showed `PerfPowerServices` near 100% CPU and `wland` also using CPU; the current cause is not established.
- **Identity:** the generated device tree uses the iPhone 14 Pro/D73 identity, but that does not guarantee all identity-dependent apps and services behave like they do on real iPhone hardware.

### Not working or not implemented

- **Bluetooth:** the Settings toggle has been unstable or greyed out; usable Bluetooth connections have not been confirmed. BlueTool/controller profile and device-tree service matching are still under investigation.
- **Full memory capacity:** iOS currently manages about 4.24 GB (`hw.memsize=4239392768`) of the phone's 8 GB. Safely adding the other DRAM ranges while preserving GPU reservations is unresolved.
- **Cellular calls/data, camera, GPS, NFC, and most onboard sensors:** no working end-to-end port has been demonstrated.
- Complete system-wide haptics and dependable game audio/graphics remain unfinished.

## Booting

Use the combined triple-boot image and select iOS 27 from the shim menu. **Do not assume a standalone iOS wrapper image will boot**; this setup requires the selector/triple-boot path.

The existing data partition is named `ios26`, so iOS 27 boot arguments commonly contain `ufsroot=ios26`. That is the partition label, not the OS version. See [`docs/dualboot.md`](docs/dualboot.md) for the image layout and selector workflow. The phone's Android installation and partition backups should be preserved when building or booting test images.

## Build and project layout

- **iOS 27 kernel:** source is the separate Git repository at `work/xnu-12377`. Kernel changes must be committed and pushed from that repository independently.
- **Metal plugin:** source/build work is in the separate Git repository at `work/UniXNU`; it is not included in commits to this repository.
- **Root filesystem:** `tools/mkios27root-mac.sh` builds the iOS 27.2 root image on macOS from the prepared IPSW contents.
- **Device tree and payload:** `tools/mkadt.py`, `tools/mkpayload.py`, and the shim build create the ADT and kernel payload used by the boot image.
- **Triple-boot image:** `tools/mktripleboot.py` combines the stock boot image, selector shim, iOS 16 payload, and iOS 27 payload. See `docs/dualboot.md` for required inputs.
- **Userland tools and drivers:** `userland/` contains Wi-Fi, Bluetooth, audio, display, haptics, GPU and diagnostic code.
- **Detailed status:** [`docs/ios27.md`](docs/ios27.md) tracks the current feature state; [`NOTES.md`](NOTES.md) records experiments, build artifacts, crashes and decisions. A source change or successful build does not by itself establish that a feature works at runtime.

## Security and artifacts

This port is for development on the owner's device. Code-signing, sandbox, and other security paths are modified or stubbed, so it should not be used for personal or sensitive data. iOS firmware, root images, device dumps, credentials, and generated build trees are not source-controlled; do not add them to Git.

## Credits

Built on Apple's open-source XNU and related releases, Qualcomm and OnePlus hardware documentation and kernel sources, [Mesa](https://mesa3d.org) Freedreno/Turnip, [HackiOS](https://github.com/oosexgang/hackios-xnu-kernel), [ios-topaz](https://github.com/MakrSas/ios-topaz), [ios-flame](https://github.com/NWylynko/ios-flame), [UniXNU](https://github.com/UniXNU/UniXNU), and [OtVaL228/ios-sweet](https://github.com/OtVaL228/ios-sweet). See source files and component READMEs for origins and licenses. iOS itself is Apple's and is not distributed here.
