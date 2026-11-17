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
- `xnu12377-gpu-census.diff` - list every GPU pool holder when an allocation is refused.

The other `xnu12377-*.diff` files are earlier iOS 27 fixes (PAC emulation, data-protection emulation in VFS,
RENAME_SWAP/purgeable on HFS, disk0 nub, canvas size, syscall tracing, Apple80211 scan/join layouts, and others);
`NOTES.md` describes each.
