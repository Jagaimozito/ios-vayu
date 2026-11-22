# arm64e → arm64: running Apple's userland on a CPU without pointer authentication

iOS 27 (and macOS 27) ship their whole userland as **arm64e**: every binary and the dyld shared cache use
ARMv8.3 pointer authentication (PAC) instructions. The OnePlus 7 Pro's Kryo 485 (Cortex-A76 + A55) is ARMv8.2
and has no FEAT_PAuth. The "hint-space" PAC instructions (`PACIASP`, `AUTIBSP`, `XPACLRI`, …) simply run as NOPs
on it, but every other PAC instruction is undefined and would crash the process.

The port handles this in two layers: the code on disk is rewritten once (**lowering**), and the kernel
emulates whatever still reaches the CPU at run time.

## Why a rewrite is safe

Without PAC hardware nothing is ever signed. So every PAC instruction can be replaced by the plain instruction
that has the same effect on an ordinary pointer:

| arm64e instruction | becomes |
| --- | --- |
| `PACIA`, `PACDB`, `AUTIA`, `XPACI`, … (sign, authenticate, strip) | `NOP`: the pointer stays as it is |
| `BRAA`/`BRAB` (and `…Z`) | `BR Xn` |
| `BLRAA`/`BLRAB` (and `…Z`) | `BLR Xn` |
| `RETAA`/`RETAB` | `RET` |
| `PACGA Xd, …` (generic MAC) | `MOVZ Xd, #0`: every signer and verifier gets the same value |
| `LDRAA`/`LDRAB` (signed 10-bit offset ×8, optional pre-index) | `LDR` (unsigned offset), `LDUR` (negative offset) or `LDR` pre-index, when the offset fits one of them |

Each one is a one-word replacement, so no code moves, nothing is relocated and branch targets stay valid.
Encodings that have no exact one-word equivalent are **refused and reported**, never approximated:
`ERETAA`/`ERETAB` (they can't appear in userland), or an `LDRAA` whose offset fits no ordinary load.

## The lowering pass (on disk, once per iOS build)

- **Every Mach-O in the root and the cryptexes:** all code sections are scanned. Each changed page gets a fresh
  CodeDirectory hash, so the binary's own code signature still matches its contents (the port's kernel trusts
  ad-hoc cdhashes).
- **The dyld shared cache:** the same pass runs image by image over all subcaches, and the page hashes are
  refreshed.
- **Stub islands in the shared cache:** some subcaches contain only `ldr x16, [x17]; braa x16, x17` stubs that
  belong to no image. A separate pass rewrites them to `br x16`.
- **Our own userland:** the GPU driver bundle, Turnip and the like get the same pass.

iOS 27.2 (24B119) numbers:

| Part | PAC instructions lowered | Refused |
| --- | --- | --- |
| OS root (3,545 of 3,744 Mach-Os changed) | 11,178,604 | 0 |
| SystemOS + AppOS cryptexes | 177,252 | 0 |
| System dyld cache (4,772 images, 81 subcaches) | 34,305,298 + 10,310 stub-island branches | 0 |
| DriverKit dyld cache (66 images) | 191,811 | 0 |

A second census afterwards finds 0 PAC instructions left. The one exception is a single `LDRAB` form in
`libsystem_m` whose offset fits no plain load, and the kernel handles that one.

The lowered files are written as overlay tars on top of Apple's original volumes. `tools/mkios27root-mac.sh`
lays them over the originals when it builds the root image. Apple's files are never committed: they stay in the
git-ignored `research/` folder, along with the lowering scripts that work on them.

## The kernel fallback (at run time)

The rewrite only covers code that exists on disk. Code generated at run time, like JavaScriptCore's JIT, still
emits PAC instructions, and so does the odd instruction the lowering refused. The kernel's undefined-instruction
handler (`osfmk/arm64/sleh.c`, diff `xnu/ios27/xnu12377-pac-emul.diff`) recognises them and emulates them with
the same rules as the table above, then continues the thread. The same handler also emulates a few other
ARMv8.4+ instructions that iOS 27 uses: `LDAPUR`/`STLUR`, `CFINV`/`RMIF`/`SETF`, `SB`, and `DIT`. It does the
loads and stores atomically (`xnu/ios27/xnu12377-emul-atomic.diff`).

## The kernel itself

The kernel is built from source as plain **arm64** (`-arch arm64 -march=armv8.2-a+crypto` for the SWEET
machine config), so it contains no PAC at all. `tools/mkmacos27kernel.sh` refuses to produce an arm64e kernel.
