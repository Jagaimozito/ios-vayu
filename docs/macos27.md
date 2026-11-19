# macOS 27 on OnePlus 7 Pro (guacamole): plan

Branch `macos27`, started 2026-11-19 from `ios27` (rebased onto 9f37afc). It shares the iOS 27 work: the XNU 12377 kernel tree
and its Sweet* drivers, the triple-boot selector, `wland` (Wi-Fi, modem, GPS), the shim and the tools. Nothing here
runs yet; this file is the plan and the place to record what is learned.

## Target

| | |
|---|---|
| OS | macOS 27.2 (build 26B123) |
| IPSW | the Mac17,5 (MacBook Neo) restore image for 26B123 |
| Why that model | A-series-class SoC (closest to the iPhone 14 Pro/D73 identity the iOS 27 port already presents) and the smallest set of Mac-only hardware |
| Phone | OnePlus 7 Pro, SM8150 / Adreno 640, 8 GB RAM, 1440x3120 panel |

The IPSW, extracted filesystems, kernelcaches and every other Apple artifact stay out of git: put them under
`research/macos27/` (git-ignored, like `research/ios27.2/`).

## Storage

Planned split (see the repartition notes in `NOTES.md`): Android `userdata` keeps 64 GiB; iOS 27 and macOS 27 get
about 81 GiB each. Repartitioning is destructive: it is done only after a confirmed backup, and never touches the
bootloaders, recovery, modem or persist partitions.

## Phases

1. **Unpack and survey.** Pull the 26B123 IPSW, extract the system volume and the kernelcache; list the kexts,
   daemons and launchd jobs the Mac17,5 image expects; diff against iOS 27.2 (24B119) to see what the iOS 27 kernel
   already answers and what is new (e.g. WindowServer, loginwindow, the Mac platform/power daemons).
2. **Device tree.** A `mkadt.py` profile for the Mac17,5 identity (model, compatible, chip id, `target-type`),
   reusing the phone's hardware nodes from the iOS 27 device tree.
3. **Kernel.** Same XNU tree, macOS configuration; carry the Sweet* drivers over (framebuffer flip, 24 MHz
   timebase, SweetABP only if anything on the Mac image wants a baseband, passcode/keystore stand-ins).
4. **Root image.** A `tools/mkmacos27root-mac.sh` in the style of `mkios27root-mac.sh`: system volume plus our
   launchd jobs and daemons.
5. **Boot.** A fourth entry in the boot selector, or a replacement for the iOS 26 slot; first goal is a verbose
   boot to a shell over USB networking or SSH.
6. **Display and input.** WindowServer on the Metal bridge (NativeAdrenoMetal / metal2vulkan); the panel is portrait
   and Mac UI expects landscape, so rotation is decided here. Touch as a pointer; Bluetooth keyboard and mouse.

## Open questions

- Which Mac-only services block the boot (SMC, AOP/ACPI-like power daemons, the Secure Enclave paths that iOS 27
  covers with SweetACM/SweetKeyStore)?
- Does WindowServer accept the Metal bridge as-is, or does it need Mac-specific GPU families?
- Is 8 GB with a 2 GB GPU pool enough for macOS 27's minimum?

## Log

- 2026-11-19: branch created; plan written.
