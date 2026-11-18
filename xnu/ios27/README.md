# iOS 27.2 kernel and driver diffs

The iOS 27.2 kernel is built from `work/xnu-12377` (Apple's xnu-12377.121.6 plus the SWEET port), which is not
in this repository. These are the individual changes made to that tree during the iOS 27 bring-up, kept here so
they are not only in the ignored `research/` folder. Each was made with `diff -u` against a backup of the file
just before the change, so they apply in the order the work was done (see `NOTES.md`), not to a clean xnu tree.

Wi-Fi (known networks / auto-join, confirmed on the phone 2026-11-16):
- `xnu12377-wifi-quiet-link.diff` - `bsd/dev/flame_sta.c`: no link-lost report while a join, leave or power-off
  of ours runs; Wi-Fi off in Settings leaves the network.
- `xnu12377-wifi-assoc540.diff` - `bsd/kern/kern_event.c` (SWEET: kernel events larger than one mbuf go in a
  cluster) and `bsd/dev/redwood_apple80211.c` (ASSOC_DONE carries the 540-byte record iOS 27's IO80211 reads; all
  zero, so it asks request 21 for the join result). Its base already had the 8-byte payload attempt.

Timebase, audio and haptics (confirmed on the phone 2026-11-17: no audio cut-outs, haptics and Bluetooth audio
work):
- `xnu12377-tb24.diff` - iOS 27 user space hard-codes Apple's 24 MHz timebase (CoreAudio converts host time as
  x * 125 / 3, and so do ~90 other places in the audio libraries), while the SM8150's generic timer runs at
  19.2 MHz: the audio server ran its I/O cycles 25 % slow and dropped a piece every 65536 frames. The kernel now
  presents 24 MHz: `pexpert/arm/pe_identify_machine.c` reports 24 MHz, `osfmk/arm64/machine_routines.c` scales
  every counter read by 5/4 and timer programming by 4/5, user space takes the mach_absolute_time /
  mach_continuous_time traps (USER_TIMEBASE_NONE), and `osfmk/arm64/sleh.c` emulates any remaining EL0 read of
  the counter or CNTFRQ. Boot-arg `sweettb24=0` turns it off.

Display and responsiveness:
- `xnu12377-fb-yuv.diff` - `SweetFramebuffer.cpp`: iOS 27 hands decoded video to the display as its own
  '420v'/'420f' (NV12) layer, which the compositor skipped (black video with sound). Those layers are now
  converted to BGRA (BT.709) underneath the page, which is blended over them so the player controls show
  (boot-arg `sweetfbyuv=0`: off). Confirmed: video plays (Safari, YouTube, local files).
- `xnu12377-fb-hwscale.diff` - `SweetFramebuffer.cpp` + `serial_console.c`: the display's VIG pipes scale the
  828x1792 frame to the 1440x3120 panel with their QSEED3 scalers (bilinear) instead of a GPU stretch blit; the
  page-flip buffers hold the logical frame, the GPU copies 1:1 (5.9 MB a frame instead of 18 MB) and the display
  reads a third of the memory. A panic first restores the 1:1 setup so the panic screen shows. Boot-arg
  `sweetfbhwscale=0`: off. Confirmed on the phone (registers checked with `scanprobe`, picture fine).
- `xnu12377-fb-cpuflip.diff` - `SweetFramebuffer.cpp`: frames the GPU present cannot take (video layers, a
  translucent top layer, more than two layers) are composed by the CPU into the hidden buffer and flipped to, instead
  of being written into the buffer the panel is scanning (that brought the dash artifacts back).
- `xnu12377-avoid-little.diff` - `sched_clutch.c` (+ the count in `SweetFramebuffer.cpp`'s 5 s statistics): Clutch
  had no avoid-processor check, so a busy thread stayed on the A55 it landed on; now a thread whose quantum expires on
  a little core moves to an idle big one (as Edge does). Printing from the scheduler panicked the first version.
- `xnu12377-fb-pageflip.diff` - `SweetFramebuffer.cpp`: present into a second buffer and flip the display pipes
  (VIG0/VIG1 SRC0_ADDR) instead of writing over the buffer being scanned out (the dashed-line corruption).
- `xnu12377-fb-asyncflip.diff` - the flip completes from a timer instead of a blocking wait in the present.
- `xnu12377-surface-cache-clean.diff` - `SweetSurface.cpp`: clean the CPU cache of an IOSurface on a writing
  unlock (boot-arg `sweetsurfclean`).
- `xnu12377-big-first2.diff` - `osfmk/kern/processor.c` + `sweet_cpufreq.c`: prefer the big cores (cpu4-7).
- `xnu12377-emul-atomic.diff` - `sleh.c`: emulated LRCPC2 loads/stores use single-copy-atomic user accesses.

Memory:
- `xnu12377-ram5g-gpupool.diff` - `sweet_gpu.c`: the GPU pool moves to free ranges outside XNU's RAM, for
  5 GB of RAM for iOS (`tools/mkadt.py --ram5g`) with a ~2 GB GPU pool.

GPU / Metal driver (`adrenometal-*.diff` are against `UniXNU/drivers/AdrenoMetal`):
- `adrenometal-resopts.diff` - pass only defined MTLResourceOptions bits (heap refusals for 0x600200).
- `adrenometal-recovery-exit.diff` - end a process whose VkDevice was recovered (it froze backboardd).
- `adrenometal-late-store.diff` - render encoders take late store actions (`setColorStoreAction:atIndex:`,
  `setDepthStoreAction:`, `setStencilStoreAction:`; bridge `nmb_encoder_set_store_action`). Unity begins every pass
  with `MTLStoreActionUnknown` and names the action before `endEncoding`; the calls were swallowed, the pass was
  lowered as DontCare and nothing reached the drawable (Subway Surfers all black). Also prints each blended
  attachment's blend in `dump-cb` output. Confirmed: Subway Surfers renders and plays.
- `adrenometal-dump-cb.diff` - boot-arg `dump-cb=NAME:FIRST[:COUNT]`: `NATIVE_METAL_DUMP_CB` for the processes whose
  name starts with NAME, their stderr into `/private/var/tmp/NativeAdrenoMetal.trace/dump-NAME-PID.log` (passes,
  draws, bindings and a brightness grid of each attachment read back after the command buffer).

Boot-args: `thid_should_crash=0` (an existing xnu tunable) lets apps set non-identity-protected exception ports.
Apps run as platform binaries on this port, so the iOS 18+ rule for platform tasks killed any app whose crash
reporter (Crashlytics, Google ads) registers a Mach exception handler (EXC_GUARD, kGUARD_EXC_EXCEPTION_BEHAVIOR_ENFORCE):
Subway Surfers died at 90 % loading.
- `xnu12377-gpu-census.diff` - list every GPU pool holder when an allocation is refused.

The other `xnu12377-*.diff` files are earlier iOS 27 fixes (PAC emulation, data-protection emulation in VFS,
RENAME_SWAP/purgeable on HFS, disk0 nub, canvas size, syscall tracing, Apple80211 scan/join layouts, and others);
`NOTES.md` describes each.
