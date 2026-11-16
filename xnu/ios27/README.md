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

GPU / Metal driver (`adrenometal-*.diff` are against `UniXNU/drivers/AdrenoMetal`):
- `adrenometal-resopts.diff` - pass only defined MTLResourceOptions bits (heap refusals for 0x600200).
- `adrenometal-recovery-exit.diff` - end a process whose VkDevice was recovered (it froze backboardd).
- `xnu12377-gpu-census.diff` - list every GPU pool holder when an allocation is refused.

The other `xnu12377-*.diff` files are earlier iOS 27 fixes (PAC emulation, data-protection emulation in VFS,
RENAME_SWAP/purgeable on HFS, disk0 nub, canvas size, syscall tracing, Apple80211 scan/join layouts, and others);
`NOTES.md` describes each.
