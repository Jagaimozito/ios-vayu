# macOS 27 on the OnePlus 7 Pro (guacamole)

macOS 27.2 (build 26B123) running on a OnePlus 7 Pro (Snapdragon 855 / SM8150, Adreno 640, 8 GB RAM), on the same
XNU 12377 kernel tree and Sweet* drivers as the iOS 27 port. This is the `macos27` branch. The iOS 27 port (and its
README) is on the `ios27` branch; iOS 16 is retired on `ios16`.
Plan and history: [`docs/macos27.md`](docs/macos27.md); day-to-day notes: [`NOTES.md`](NOTES.md).

Apple artifacts (IPSW, filesystems, kernelcaches, dyld caches, crash reports, dumps) never go into git: they live in
`research/macos27/` and `outputs/`, which are git-ignored.

## Status (2026-11-22)

| | |
|---|---|
| Boot | Boot menu (iOS 27 / macOS 27 / Android, volume keys or touch) -> SWEET kernel -> HFS+ root on the `macos` partition |
| Login | Login window and autologin; desktop with Dock, menu bar, Finder, System Settings, Safari |
| Display | 1560x720 landscape (the 1440x3120 panel rotated and halved, `sweetfb_rot` / `sweetfb_div`) |
| GPU | Metal through the NativeAdrenoMetal plugin (Turnip/Vulkan underneath); Core Image, icons, wallpaper |
| Input | Touchscreen as a trackpad, with haptic clicks; on-screen Accessibility Keyboard; text over SSH (`kern.sweet_hid_type`) |
| Wi-Fi | `wland` (own WLAN firmware driver), DHCP; apps have DNS through `netsvc` |
| Storage | Root disk is `disk0` to Disk Arbitration; Finder, About This Mac and Disk Utility's view work |
| Brightness / Night Shift | Control Center slider -> panel brightness; Night Shift -> display colour stage (`sweet-displayd`) |
| About This Mac | "OnePlus 7 Pro", "Qualcomm Snapdragon 855", 5 GB memory |
| UFS health | `sysctl kern.sweet_ufs_health` (pre-EOL, life-time estimate A/B) |

Not working (yet): USB devices and video out, Bluetooth, audio, keychain unlock (legacy keychains), speech plug-ins
(crash loop), Software Update. APFS is a possible future step (see "Later").

## Trackpad (the touchscreen)

| Gesture | Does |
|---|---|
| One finger slide | Moves the pointer (relative, like a trackpad) |
| Tap | Click |
| Tap, then touch again and slide | Drag |
| Two fingers slide | Scroll |
| Two-finger tap | Right click |
| Three fingers down and slide | Drag (move windows by the title bar, select text) |

Each click and drag start gives a haptic tick. Tune while running:
`sysctl -w kern.sweet_pad_haptic_gain=N` (0 off .. 128) and `sysctl -w kern.sweet_pad_haptic_wave=W`
(2 light, 5 medium, 10 buzz, 20 heavy). Default: wave 10, gain 128. Boot-arg `sweetpad=0` returns to "pointer under
the finger"; `sweetpadhaptic=N` sets the gain at boot.

## Build and flash (on the Mac)

From a `macos27` checkout (here the worktree `work/macos27-wt`, whose `work`, `outputs` and `dtb` link to the main
checkout's):

```
cd ~/Documents/Codex/2026-11-06/ok/work/ios-sweet-latest/work/macos27-wt
bash tools/mkmacos27kernel.sh
grep -c sweet_pad_haptic_gain work/xnu-12377/BUILD/obj-macos27-sweet/DEVELOPMENT_ARM64_SWEET/kernel.development.sweet   # must be >= 1
bash tools/mkmacos27boot.sh outputs/guacamole-ios27a-xfrot-ios27part.img
grep -c -- ' -v' outputs/guacamole-menu-ios27-macos27-macos-boot-args.txt                                               # must be 0
```

Phone off, hold Volume Up + Power for fastboot:

```
fastboot flash boot_b outputs/guacamole-menu-ios27-macos27.img
fastboot reboot
```

Pick macOS. After every flash, clear logind's first-run marker (HFS+ does not empty /var/run) and reboot once:

```
ssh guacmac 'rm -f /var/run/com.apple.logind.didRunThisBoot; sync; reboot'
```

The boot-menu shim (with touch) is built in the Linux workspace with `aarch64-linux-gnu-gcc` (see `shim/build.sh`);
the Mac has no ARM64 Linux cross compiler. `tools/mkmacos27boot.sh` takes `shim/out/Image`.

Userland helpers for macOS (`wland`, `sweet-displayd`): `sh userland/build-macos.sh`; on a running phone,
`tools/macos27-displayd-install.sh` installs the `sweet-displayd` job. The root image's extras
(Wi-Fi job, `netsvc`, the `hfs.util` wrapper, `sweet-displayd`, launchd overrides): `tools/macos27-extras.sh`.

## What macOS needed (summary)

- **Kernel** (`xnu/macos27/0001`..`0018`): HID stand-ins and keyboard identity, IOAccelerator/IOSurface names,
  framebuffer formats and plane pitch, console mute, landscape and scaling, touch-as-trackpad, user SIMD emulation
  (SHA3/SHA512/FHM/FRINTTS), cryptexd grafts, the root disk as `disk0` with an IOMedia/IOBlockStorageDevice stand-in
  for Disk Arbitration, UFS health.
- **Root**: `hfs.util` wrapper (macOS 27 reports a mounted HFS volume as an I/O failure), `fskitd` disabled
  (storagekitd waited on it forever and the login screen waited on storagekitd), `clocksyncd`, `bluetoothd`,
  `AppSSODaemon` disabled, `netsvc` (DNS), `sweet-displayd`, launchd job cache entries.
- **dyld shared cache** (`dsc.01`): code-signing patch, and LaunchServices `LinkBinding::resolveBinding` must not
  abort when the startup volume resolves to itself (`tools/patch-macos27-ls-linkbinding.py`; tested and installed
  on the phone with `tools/macos27-dsc-ls-install.sh`, which also prints where the new cache lies on disk so it can be
  restored offline from TWRP; the generated restore script is `outputs/twrp-restore-dsc01.sh`, not in git).
- **Boot image**: `/product` name "OnePlus 7 Pro" and `product-soc-name` "Qualcomm Snapdragon 855"; model stays
  `iPhone15,2` (a Mac identity is a separate, deliberate step).

## Rules for this branch

- macOS changes are committed to `macos27` only, never to `ios27`.
- Partitions are flashed with fastboot; recovery steps for a macOS that does not come up use TWRP (adb), never SSH.
- Root-image files are installed as `.new` and moved into place; originals are kept.

## Later

- APFS (one container for iOS and macOS volumes): first a test of loading an Apple kext into this kernel.
- USB keyboard/mouse (DWC3 host + HID), and DisplayPort over USB-C at 1920x1080 with the panel off, if Android
  shows the port can carry video.
- A Mac identity (`Mac17,5`) once the system is stable.
