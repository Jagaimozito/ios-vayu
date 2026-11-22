#!/usr/bin/env python3
"""Narrowly tolerate stale CMS-to-CodeDirectory binding in macOS 27.2.

This targets only the lowered system dyld shared-cache arm64e subcache .01
from build 26B123. The three entry branches route through a platform check:
  * kCMSSignerInvalidSignature (status 3) is accepted only for CodeDirectory
    platform 27 (macOS); other CMS signer statuses still fail.
  * both CMS CodeDirectory hash-agility mismatch paths are skipped only for
    CodeDirectory platform 27; all other paths remain unchanged.

The CMS trust object is still evaluated by the original code after these
checks, and caller-supplied requirements are still evaluated. CodeDirectory
page/resource validation is not changed. The small ARM64 trampolines occupy
verified NOP padding that is skipped by an unconditional branch.

The optional --extend mode applies on top of the first patch and handles the
earlier CMSDecoderCopySignerStatus OSStatus return: only exact -67061 on a
platform-27 CodeDirectory continues to normal validation. Other OSStatus
errors and non-platform-27 -67061 retain their original failure behavior.

The cache file has the .01 mapping base 0x180400000 and file offset zero.
The script updates the affected CodeDirectory page hashes in place, preserving
hard links. It does not regenerate Apple's CMS blob.

Usage:
  tools/patch-macos27-security-cms.py PATH_TO_DYLD_SHARED_CACHE_ARM64E.01
  tools/patch-macos27-security-cms.py PATH_TO_DYLD_SHARED_CACHE_ARM64E.01 --restore
  tools/patch-macos27-security-cms.py PATCHED_01 --extend
  tools/patch-macos27-security-cms.py PATCHED_02 --extend --restore
"""
from __future__ import annotations

import argparse
import hashlib
import mmap
import os
import struct
import sys
from pathlib import Path

CACHE_MAGIC = b"dyld_v1  arm64e"
CACHE_BASE = 0x180400000
SIGNATURE_OFFSET_FIELD = 0x28
CODEDIRECTORY_MAGIC = 0xFADE0C02
SUPERBLOB_MAGIC = 0xFADE0CC0
HASHES = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}

# 26B123 image addresses. Security::CodeSigning::SecStaticCode::validateDirectory
# calls verifySignature at 0x18516a278; its platform CodeDirectory accessor is
# 0x1851692a4 (argument 1 requests the current/primary CodeDirectory).
SECURITY_STATUS_BRANCH = 0x18516A700
HASH_AGILITY_COUNT_BRANCH = 0x18516A7A4
HASH_AGILITY_LIST_BRANCH = 0x18516A8B0
CODEDIRECTORY_ACCESSOR = 0x1851692A4
STATUS_CONTINUE = 0x18516A704
STATUS_FAILURE = 0x18516B2BC
HASH_COUNT_CONTINUE = 0x18516A7A8
HASH_COUNT_FAILURE = 0x18516B500
HASH_LIST_CONTINUE = 0x18516A8B4
HASH_LIST_FAILURE = 0x18516B454

# The CMSDecoderCopySignerStatus OSStatus error path in validateDirectory.
# A nonzero return branches here before the out signer-status is examined.
API_ERROR_HANDLER = 0x18516B36C
API_SIGNATURE_FAILURE = 0x18516B360
API_ERROR_SUCCESS = 0x18516A704
CMS_SIGNATURE_FAILED = -67061
EXTEND_BASE_SHA256 = "004c09cf74e2722027e50f3facd24e56561a69e5d20ae71a53cd09b75ae2b29c"

# These are unreachable NOP pads: the instruction immediately before each
# pad is an unconditional branch over it. All expected NOP bytes are checked.
CAVE_SECURITY = 0x184BCDDC4       # 15 words
CAVE_HASH_COUNT = 0x184BBB35C     # 9 words
CAVE_HASH_LIST = 0x186DE705C      # 9 words
CAVE_API_ERROR = 0x188000D24      # 7 words, skipped NOP pad
CAVE_API_FALLBACK = 0x188000D14  # 3 NOPs after a ret; fallback tail-call
NOP = 0xD503201F


class PatchError(Exception):
    pass


def sign_extend(value: int, bits: int) -> int:
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def branch(pc: int, target: int, link: bool = False) -> int:
    delta = target - pc
    if delta & 3 or not -(1 << 27) <= delta < (1 << 27):
        raise PatchError(f"branch out of range/alignment: {pc:#x} -> {target:#x}")
    return (0x94000000 if link else 0x14000000) | ((delta >> 2) & 0x03FFFFFF)


def branch_cond(pc: int, target: int, cond: int) -> int:
    delta = target - pc
    if delta & 3 or not -(1 << 20) <= delta < (1 << 20):
        raise PatchError(f"conditional branch out of range/alignment: {pc:#x} -> {target:#x}")
    return 0x54000000 | (((delta >> 2) & 0x7FFFF) << 5) | cond


def cbz_w0(pc: int, target: int) -> int:
    delta = target - pc
    if delta & 3 or not -(1 << 20) <= delta < (1 << 20):
        raise PatchError(f"CBZ branch out of range/alignment: {pc:#x} -> {target:#x}")
    return 0x34000000 | (((delta >> 2) & 0x7FFFF) << 5)


def tbz_w27_bit0(pc: int, target: int) -> int:
    delta = target - pc
    if delta & 3 or not -(1 << 15) <= delta < (1 << 15):
        raise PatchError(f"TBZ branch out of range/alignment: {pc:#x} -> {target:#x}")
    return 0x36000000 | (((delta >> 2) & 0x3FFF) << 5) | 27


def word_bytes(words: list[int]) -> bytes:
    return b"".join(struct.pack("<I", word) for word in words)


def plans() -> list[tuple[int, bytes, str]]:
    """Return exact (cache VA, replacement bytes, description) plan."""
    # Platform test: codeDirectory(self, primary=1), then test its platform byte
    # at CodeDirectory offset 38 against macOS 27's platform value 27.
    sec = CAVE_SECURITY
    checker = [
        0xAA1303E0,                                 # mov x0, x19
        0x52800021,                                 # mov w1, #1
        branch(sec + 8, CODEDIRECTORY_ACCESSOR, True),
        0x39409808,                                 # ldrb w8, [x0, #38]
        0x71006D1F,                                 # cmp w8, #27
        0x1A9F17E0,                                 # cset w0, eq
        0xD65F03C0,                                 # ret
    ]

    # Entered for every signer status. Valid status 1 follows the original
    # success path. Status 3 is the only invalid result eligible for the gate.
    # Other statuses still take the original failure path.
    status = sec + len(checker) * 4
    # Build explicit flow. Status 1: continue. Status 3 + platform 27: continue.
    # Everything else: fail. The failure trampoline is in the second cave.
    status_words = [
        0x7100041F,                                 # cmp w8, #1
        branch_cond(status + 4, status + 12, 1),    # b.ne status3 check
        branch(status + 8, STATUS_CONTINUE),
        0x71000C1F,                                 # cmp w8, #3
        branch_cond(status + 16, CAVE_HASH_COUNT + 28, 1),  # b.ne fail
        branch(status + 20, sec, True),             # bl platform test
        cbz_w0(status + 24, CAVE_HASH_COUNT + 28),  # cbz w0, fail
        branch(status + 28, STATUS_CONTINUE),
    ]

    # Count-mismatch dispatcher. It preserves the original compare flags:
    # equal count resumes the untouched loop; a mismatch passes the gate.
    c2 = CAVE_HASH_COUNT
    count_stub = [
        branch_cond(c2, c2 + 8, 0),                  # b.eq original equal-count path
        branch(c2 + 4, c2 + 12),
        branch(c2 + 8, HASH_COUNT_CONTINUE),
        branch(c2 + 12, sec, True),
        cbz_w0(c2 + 16, c2 + 24),
        branch(c2 + 20, HASH_LIST_CONTINUE),
        branch(c2 + 24, HASH_COUNT_FAILURE),
        branch(c2 + 28, STATUS_FAILURE),            # shared status failure path
        NOP,
    ]

    # List-mismatch dispatcher. Original w27 bit zero represents a match.
    c3 = CAVE_HASH_LIST
    list_stub = [
        tbz_w27_bit0(c3, c3 + 8),                   # no match -> platform gate
        branch(c3 + 4, HASH_LIST_CONTINUE),
        branch(c3 + 8, sec, True),
        cbz_w0(c3 + 12, c3 + 20),
        branch(c3 + 16, HASH_LIST_CONTINUE),
        branch(c3 + 20, HASH_LIST_FAILURE),
        NOP, NOP, NOP,
    ]

    patch_specs = [
        (SECURITY_STATUS_BRANCH, branch(SECURITY_STATUS_BRANCH, status),
         "CMS signer-status gate (status 3 only, CodeDirectory platform 27)"),
        (HASH_AGILITY_COUNT_BRANCH, branch(HASH_AGILITY_COUNT_BRANCH, c2),
         "CMS hash-agility array-count mismatch gate"),
        (HASH_AGILITY_LIST_BRANCH, branch(HASH_AGILITY_LIST_BRANCH, c3),
         "CMS hash-agility CodeDirectory-list mismatch gate"),
        (sec, word_bytes(checker + status_words), "platform-gated CMS dispatch trampoline"),
        (c2, word_bytes(count_stub), "hash-agility count trampoline and shared error trampoline"),
        (c3, word_bytes(list_stub), "hash-agility list trampoline"),
    ]
    return [(va, struct.pack("<I", value) if isinstance(value, int) else value, desc)
            for va, value, desc in patch_specs]


def extension_plans() -> list[tuple[int, bytes, str]]:
    """Patch the API-return error path on top of the original .01 patch."""
    # The original b36c call logs/throws the API's OSStatus, then returns via
    # b370. We redirect that handler to a gate. Nonmatching errors tail-call
    # the same helper with LR restored to b370; -67061 is tolerated only when
    # the CodeDirectory platform check used by patch 1 returns true.
    stub = [
        0x529F4168,                                        # movz w8, #0xfa0b
        0x72BFFFC8,                                        # movk w8, #0xfffe, lsl #16
        0x6B08001F,                                        # cmp w0, w8
        branch_cond(CAVE_API_ERROR + 12, CAVE_API_FALLBACK, 1),  # b.ne fallback
        branch(CAVE_API_ERROR + 16, CAVE_SECURITY, True),  # bl platform checker
        cbz_w0(CAVE_API_ERROR + 20, CAVE_API_FALLBACK + 8),# cbz w0, non-platform error
        branch(CAVE_API_ERROR + 24, API_ERROR_SUCCESS),    # continue normal validation
    ]
    fallback = [
        branch(CAVE_API_FALLBACK, 0x18528FAF4, True),      # call original generic throw/log helper
        branch(CAVE_API_FALLBACK + 4, 0x18516B920),        # original common return path
        branch(CAVE_API_FALLBACK + 8, API_SIGNATURE_FAILURE), # restore exact -67061 failure
    ]
    patch_specs = [
        (API_ERROR_HANDLER, branch(API_ERROR_HANDLER, CAVE_API_ERROR),
         "CMSDecoderCopySignerStatus error-handler gate (-67061 only, platform 27 only)"),
        (CAVE_API_ERROR, word_bytes(stub), "CMS OSStatus gate trampoline"),
        (CAVE_API_FALLBACK, word_bytes(fallback), "generic and non-platform CMS error fallbacks"),
    ]
    return [(va, struct.pack("<I", data) if isinstance(data, int) else data, desc)
            for va, data, desc in patch_specs]


def affected_hash_updates(mm: mmap.mmap, patches: list[tuple[int, bytes, str]], size: int):
    sig_off, sig_size = struct.unpack_from("<QQ", mm, 0x28)
    if not sig_off or sig_off + sig_size > size:
        raise PatchError("dyld cache has invalid code-signature range")
    sb = sig_off
    magic, sb_len, count = struct.unpack_from(">III", mm, sb)
    if magic != SUPERBLOB_MAGIC or sb_len < 12 + count * 8 or sb_len > sig_size:
        raise PatchError("invalid Code Signing SuperBlob")

    per_cd = []
    for idx in range(count):
        slot_type, rel = struct.unpack_from(">II", mm, sb + 12 + idx * 8)
        cd = sb + rel
        if cd + 4 > sb + sb_len:
            raise PatchError("blob header outside SuperBlob")
        if struct.unpack_from(">I", mm, cd)[0] != CODEDIRECTORY_MAGIC:
            continue
        if cd + 40 > sb + sb_len:
            raise PatchError("CodeDirectory header outside SuperBlob")
        cd_len = struct.unpack_from(">I", mm, cd + 4)[0]
        if cd_len < 40 or cd + cd_len > sb + sb_len:
            raise PatchError("invalid CodeDirectory length")
        hash_off, _ident, _special, n_code, code_limit = struct.unpack_from(">IIIII", mm, cd + 16)
        hash_size, hash_type, _platform, page_shift = mm[cd + 36:cd + 40]
        if hash_type not in HASHES or not hash_size or page_shift > 30:
            raise PatchError(f"unsupported CodeDirectory hash parameters in slot {slot_type:#x}")
        page_size = 1 << page_shift
        if code_limit > sig_off or n_code < (code_limit + page_size - 1) // page_size:
            raise PatchError("CodeDirectory code-limit/page count is inconsistent")
        pages = sorted({(va - CACHE_BASE) // page_size for va, _new, _desc in patches})
        hashes = []
        for page in pages:
            start = page * page_size
            end = min(start + page_size, code_limit)
            if start >= code_limit or page >= n_code:
                continue
            image = bytearray(mm[start:end])
            for va, new, _desc in patches:
                file_off = va - CACHE_BASE
                if start <= file_off and file_off + len(new) <= end:
                    image[file_off - start:file_off - start + len(new)] = new
                elif start < file_off + len(new) and file_off < end:
                    raise PatchError("patch crosses a CodeDirectory page boundary")
            digest = hashlib.new(HASHES[hash_type], image).digest()[:hash_size]
            slot = cd + hash_off + page * hash_size
            if slot + hash_size > cd + cd_len:
                raise PatchError("CodeDirectory hash slot exceeds directory")
            hashes.append((slot, digest, page, page_size, HASHES[hash_type], start, end))
        if hashes:
            per_cd.append((slot_type, hashes))
    if not per_cd:
        raise PatchError("no CodeDirectory page hashes cover the patch sites")
    return per_cd


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path, help="lowered dyld_shared_cache_arm64e.01 subcache")
    parser.add_argument("--restore", action="store_true", help="restore all checked original bytes")
    parser.add_argument("--extend", action="store_true", help="apply/restore the second CMS OSStatus gate on top of patch 1")
    args = parser.parse_args()
    if args.restore and not args.extend:
        # Backward-compatible patch-1 restore mode.
        pass
    path = args.file
    if not path.is_file():
        parser.error(f"file not found: {path}")
    if path.stat().st_size < 0x1000:
        parser.error("input is too small to be a dyld subcache")

    patches = plans()
    f = None
    mm = None
    try:
        f = path.open("r+b")
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE)
        if mm[:len(CACHE_MAGIC)] != CACHE_MAGIC:
            raise PatchError(f"wrong cache magic: {mm[:len(CACHE_MAGIC)]!r}")
        if args.extend:
            extension = extension_plans()
            if args.restore:
                writes = [
                    (API_ERROR_HANDLER, _original_for_extension(API_ERROR_HANDLER), "restore CMS error handler"),
                    (CAVE_API_ERROR, _original_for_extension(CAVE_API_ERROR), "restore CMS OSStatus trampoline"),
                    (CAVE_API_FALLBACK, _original_for_extension(CAVE_API_FALLBACK), "restore CMS error fallback"),
                ]
                expected = {va: data for va, data, _desc in extension}
            else:
                before_hash = hashlib.sha256(mm[:]).hexdigest()
                if before_hash != EXTEND_BASE_SHA256:
                    raise PatchError(
                        f"--extend requires the current patch-1 .01 base SHA-256 {EXTEND_BASE_SHA256}; "
                        f"got {before_hash}; NOT writing"
                    )
                writes = extension
                expected = {va: _original_for_extension(va) for va, _data, _desc in extension}
        elif args.restore:
            old_new = [(va, data, desc) for va, data, desc in patches]
            targets = [(va, struct.pack("<I", NOP) * (len(data) // 4) if va in (CAVE_SECURITY, CAVE_HASH_COUNT, CAVE_HASH_LIST)
                        else _original_for_va(va), desc) for va, data, desc in old_new]
            expected = {va: data for va, data, _desc in patches}
            writes = [(va, target, desc) for (va, _new, desc), (_va2, target, _desc2) in zip(patches, targets)]
        else:
            writes = patches
            expected = {va: (struct.pack("<I", NOP) * (len(data) // 4) if va in (CAVE_SECURITY, CAVE_HASH_COUNT, CAVE_HASH_LIST)
                             else _original_for_va(va)) for va, data, _desc in writes}

        for va, new, desc in writes:
            off = va - CACHE_BASE
            if off < 0 or off + len(new) > len(mm):
                raise PatchError(f"{desc}: VA {va:#x} is outside .01's file-backed mapping")
            got = bytes(mm[off:off + len(new)])
            want = expected[va]
            if got != want:
                state = "patched" if args.restore else "original"
                raise PatchError(f"{desc}: at VA {va:#x}, got {got.hex()}, expected {state} bytes {want.hex()}; NOT writing")

        hash_updates = affected_hash_updates(mm, writes, len(mm))
        before = hashlib.sha256(mm[:]).hexdigest()
        for va, new, _desc in writes:
            off = va - CACHE_BASE
            mm[off:off + len(new)] = new
        for _slot_type, updates in hash_updates:
            for slot, digest, _page, _page_size, _alg, _start, _end in updates:
                mm[slot:slot + len(digest)] = digest
        mm.flush()
        f.flush()
        os.fsync(f.fileno())

        for va, new, desc in writes:
            off = va - CACHE_BASE
            if bytes(mm[off:off + len(new)]) != new:
                raise PatchError(f"post-write verification failed: {desc}")
        for slot_type, updates in hash_updates:
            for slot, digest, page, _page_size, alg, start, end in updates:
                actual = hashlib.new(alg, mm[start:end]).digest()[:len(digest)]
                if actual != digest or bytes(mm[slot:slot + len(digest)]) != digest:
                    raise PatchError(f"post-write CodeDirectory verification failed in slot {slot_type:#x}, page {page}")
        after = hashlib.sha256(mm[:]).hexdigest()
        action = "restored extension" if args.extend and args.restore else "extended" if args.extend else "restored" if args.restore else "patched"
        print(f"{action} in place: {path}")
        print(f"input SHA-256:  {before}")
        print(f"output SHA-256: {after}")
        for va, data, desc in writes:
            print(f"  VA {va:#x} / file offset {va - CACHE_BASE:#x}: {desc} ({len(data)} bytes)")
        for slot_type, updates in hash_updates:
            pages = ", ".join(str(update[2]) for update in updates)
            print(f"  CodeDirectory slot {slot_type:#x}: refreshed {len(updates)} page hashes (pages {pages})")
        print("  Apple CMS blob is unchanged; signer chain and requirements still run.")
        return 0
    except (OSError, ValueError, struct.error, PatchError) as exc:
        print(f"patch-macos27-security-cms: {exc}", file=sys.stderr)
        return 1
    finally:
        if mm is not None:
            mm.close()
        if f is not None:
            f.close()


def _original_for_va(va: int) -> bytes:
    originals = {
        SECURITY_STATUS_BRANCH: bytes.fromhex("e15d0054"),
        HASH_AGILITY_COUNT_BRANCH: bytes.fromhex("e16a0054"),
        HASH_AGILITY_LIST_BRANCH: bytes.fromhex("3b5d0036"),
    }
    if va in originals:
        return originals[va]
    if va == CAVE_SECURITY:
        return bytes.fromhex("1f2003d5") * 15
    if va == CAVE_HASH_COUNT:
        return bytes.fromhex("1f2003d5") * 9
    if va == CAVE_HASH_LIST:
        return bytes.fromhex("1f2003d5") * 9
    raise PatchError(f"no original-byte guard for VA {va:#x}")


def _original_for_extension(va: int) -> bytes:
    originals = {
        API_ERROR_HANDLER: bytes.fromhex("e2910494"),  # bl 0x18528faf4
        CAVE_API_ERROR: bytes.fromhex("1f2003d5") * 7,
        CAVE_API_FALLBACK: bytes.fromhex("1f2003d5") * 3,
    }
    try:
        return originals[va]
    except KeyError as exc:
        raise PatchError(f"no patch-1-byte guard for extension VA {va:#x}") from exc


if __name__ == "__main__":
    raise SystemExit(main())
