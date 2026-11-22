#!/usr/bin/env python3
"""Disable QuartzCore's virtualized-framebuffer format branch in macOS 27.2.

Accepts either the raw dyld_shared_cache_arm64e.03 file or the overlay tar that
contains it. The tar mode patches that member's payload in place, preserving
the tar layout. Both modes verify the exact expected instruction and update
the affected CodeDirectory page hashes, matching the project's lowered-cache
signing workflow (the Apple CMS signature itself is not regenerated).

The 26B123 mapping is QuartzCore IOMFBDisplay::framebuffer_pixel_format:
  VA 0x18e0a42b0 / subcache file offset 0x5ca42b0
  original: 08 06 00 37  (tbnz w8, #0, ...)
  patched:  1f 20 03 d5  (nop)

Usage:
  patch-macos27-framebuffer-format.py PATH_TO_CACHE
  patch-macos27-framebuffer-format.py OVERLAY.tar --member ./System/Library/dyld/dyld_shared_cache_arm64e.03
  patch-macos27-framebuffer-format.py PATH --restore [--member MEMBER]
"""
import argparse
import hashlib
import mmap
import os
import struct
import sys
import tarfile

CACHE_NAME = "dyld_shared_cache_arm64e.03"
CACHE_MAGIC = b"dyld_v1  arm64e"
PATCH_OFFSET = 0x5CA42B0
ORIGINAL = bytes.fromhex("08060037")
REPLACEMENT = bytes.fromhex("1f2003d5")


def cache_region(path, member_name):
    """Return (file, mmap, base, size, label), mapping raw cache or tar member."""
    if member_name is None:
        if os.path.basename(path) != CACHE_NAME:
            raise ValueError(f"raw cache filename must be {CACHE_NAME}")
        f = open(path, "r+b")
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE)
        return f, mm, 0, len(mm), path

    with tarfile.open(path, "r:") as tf:
        member = tf.getmember(member_name)
        if not member.isfile() or member.name.rsplit("/", 1)[-1] != CACHE_NAME:
            raise ValueError(f"tar member must be a regular {CACHE_NAME} file")
        base, size = member.offset_data, member.size
    f = open(path, "r+b")
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE)
    return f, mm, base, size, f"{path}:{member_name}"


def parse_signature(mm, base, size, patch_offset, replacement):
    """Plan CodeDirectory page-hash updates; do not mutate until all validate."""
    if size < 0x60 or mm[base:base + len(CACHE_MAGIC)] != CACHE_MAGIC:
        raise ValueError("not an arm64e dyld shared cache")
    sig_off, sig_size = struct.unpack_from("<QQ", mm, base + 0x28)
    if not sig_off or sig_off + sig_size > size:
        raise ValueError("shared cache has an invalid code-signature range")
    sb = base + sig_off
    magic, sb_len, count = struct.unpack_from(">III", mm, sb)
    if magic != 0xFADE0CC0 or sb_len > sig_size or sb_len < 12 + 8 * count:
        raise ValueError("invalid code-signature SuperBlob")

    updates, found = [], 0
    for i in range(count):
        slot_type, rel = struct.unpack_from(">II", mm, sb + 12 + i * 8)
        cd = sb + rel
        if cd < sb or cd + 4 > sb + sb_len:
            raise ValueError("CodeDirectory index is outside SuperBlob")
        cd_magic = struct.unpack_from(">I", mm, cd)[0]
        if cd_magic != 0xFADE0C02:
            continue
        if cd + 8 > sb + sb_len:
            raise ValueError("truncated CodeDirectory header")
        cd_len = struct.unpack_from(">I", mm, cd + 4)[0]
        if cd_len < 40 or cd + cd_len > sb + sb_len:
            raise ValueError("invalid CodeDirectory length")
        hash_off, ident_off, n_special, n_code, code_limit = struct.unpack_from(">IIIII", mm, cd + 16)
        hash_size, hash_type, _platform, page_shift = mm[cd + 36:cd + 40]
        if hash_type not in (1, 2, 3, 4) or not hash_size or page_shift > 30:
            raise ValueError(f"unsupported CodeDirectory hash parameters in slot {slot_type:#x}")
        page_size = 1 << page_shift
        if patch_offset >= code_limit:
            continue
        page_index = patch_offset // page_size
        if page_index >= n_code:
            raise ValueError("patch instruction is outside CodeDirectory code slots")
        page_start = page_index * page_size
        page_end = min(page_start + page_size, code_limit)
        alg = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}[hash_type]
        page_bytes = bytearray(mm[base + page_start:base + page_end])
        in_page = patch_offset - page_start
        page_bytes[in_page:in_page + len(replacement)] = replacement
        digest = hashlib.new(alg, page_bytes).digest()[:hash_size]
        slot = cd + hash_off + page_index * hash_size
        if slot + hash_size > cd + cd_len:
            raise ValueError("CodeDirectory hash slot exceeds its directory")
        updates.append((slot, digest, slot_type, page_index, page_size, alg, page_start, page_end))
        found += 1
    if not found:
        raise ValueError("no supported CodeDirectory covers the patch offset")
    return updates


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("path", help="raw subcache or lowered overlay tar")
    ap.add_argument("--member", help="tar member path when path is an overlay archive")
    ap.add_argument("--restore", action="store_true", help="restore the original conditional branch")
    args = ap.parse_args()
    expected, value = (REPLACEMENT, ORIGINAL) if args.restore else (ORIGINAL, REPLACEMENT)
    f = mm = None
    try:
        f, mm, base, size, label = cache_region(args.path, args.member)
        if PATCH_OFFSET + 4 > size:
            raise ValueError("cache member is too short for the target offset")
        magic = mm[base:base + len(CACHE_MAGIC)]
        if magic != CACHE_MAGIC:
            raise ValueError(f"cache magic mismatch: {magic!r}")
        got = mm[base + PATCH_OFFSET:base + PATCH_OFFSET + 4]
        if got == value:
            print(f"already {'restored' if args.restore else 'patched'}: {label}")
            return 0
        if got != expected:
            raise ValueError(f"refusing: offset {PATCH_OFFSET:#x} has {got.hex()}, expected {expected.hex()}")
        sig_updates = parse_signature(mm, base, size, PATCH_OFFSET, value)

        # Patch executable text first, then refresh every CodeDirectory page
        # slot covering it. The patch and all hash changes are fixed-size writes.
        mm[base + PATCH_OFFSET:base + PATCH_OFFSET + 4] = value
        for slot, digest, slot_type, page_index, page_size, _alg, _page_start, _page_end in sig_updates:
            mm[slot:slot + len(digest)] = digest
        mm.flush()
        f.flush()

        check = mm[base + PATCH_OFFSET:base + PATCH_OFFSET + 4]
        if check != value:
            raise ValueError("post-write instruction verification failed")
        for slot, digest, _slot_type, _page_index, _page_size, alg, page_start, page_end in sig_updates:
            actual = hashlib.new(alg, mm[base + page_start:base + page_end]).digest()[:len(digest)]
            if mm[slot:slot + len(digest)] != digest or actual != digest:
                raise ValueError("post-write CodeDirectory hash verification failed")
        action = "restored" if args.restore else "patched"
        print(f"{action}: {label}")
        print(f"  offset 0x{PATCH_OFFSET:x}: {expected.hex()} -> {value.hex()}")
        print(f"  refreshed {len(sig_updates)} CodeDirectory page hash(es)")
        for _slot, _digest, slot_type, page_index, page_size, _alg, _page_start, _page_end in sig_updates:
            print(f"    slot {slot_type:#x}, page {page_index} ({page_size} bytes)")
        print("  note: the Apple CMS signature is not regenerated")
        return 0
    except (OSError, ValueError, KeyError, tarfile.TarError, struct.error) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    finally:
        if mm is not None:
            mm.close()
        if f is not None:
            f.close()


if __name__ == "__main__":
    raise SystemExit(main())
