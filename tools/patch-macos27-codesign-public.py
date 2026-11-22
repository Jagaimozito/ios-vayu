#!/usr/bin/env python3
"""Patch only public Security.framework validation entry points in macOS 27.2.

The input must be the lowered-original arm64e dyld subcache .01 for build
26B123. Entry bytes and the full input SHA-256 are checked before writing.
Affected CodeDirectory page hashes are recalculated; Apple's CMS blob remains
unchanged. --restore accepts only this script's exact output and restores the
original bytes and their matching page hashes.

Usage:
  tools/patch-macos27-codesign-public.py PATH_TO_dyld_shared_cache_arm64e.01
  tools/patch-macos27-codesign-public.py PATH_TO_dyld_shared_cache_arm64e.01 --restore
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
LOWERED_ORIGINAL_SHA256 = "76860d29a3bf679b9015909d588ee6906bb100525c9992d3ddd53bbc8ee38af7"
PATCHED_SHA256 = "058aca5b552180f523016110f8b178e0e71f7baaf400bab15bcf510ac0227eec"
CODEDIRECTORY_MAGIC = 0xFADE0C02
SUPERBLOB_MAGIC = 0xFADE0CC0
HASHES = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}

SUCCESS = bytes.fromhex("00008052c0035fd6")  # mov w0, #0; ret
# WithErrors APIs take CFErrorRef * in x3. Null-check, clear, then succeed.
SUCCESS_CLEAR_X3 = bytes.fromhex("430040b47f0000f900008052c0035fd6")

# Exact lowered-original instruction bytes from the 26B123 .01 subcache.
# This list intentionally contains only the six requested public functions.
PATCHES = [
    ("SecStaticCodeCheckValidity", 0x18516342C,
     bytes.fromhex("030080d201000014"), SUCCESS,
     "public wrapper; returns errSecSuccess"),
    ("SecStaticCodeCheckValidityWithErrors", 0x185163434,
     bytes.fromhex("7f2303d5ffc301d1fa6702a9f85f03a9"), SUCCESS_CLEAR_X3,
     "clears CFErrorRef * x3, returns errSecSuccess"),
    ("SecCodeCheckValidity", 0x18515DD5C,
     bytes.fromhex("030080d201000014"), SUCCESS,
     "public wrapper; returns errSecSuccess"),
    ("SecCodeCheckValidityWithErrors", 0x18515DD64,
     bytes.fromhex("7f2303d5ff4301d1f85f01a9f65702a9"), SUCCESS_CLEAR_X3,
     "clears CFErrorRef * x3, returns errSecSuccess"),
    ("SecTaskValidateForRequirement", 0x185192230,
     bytes.fromhex("7f2303d5ff0301d1f65701a9"), SUCCESS,
     "returns errSecSuccess; no CFErrorRef * output"),
    ("SecRequirementEvaluate", 0x185160DF4,
     bytes.fromhex("7f2303d5ffc303d1"), SUCCESS,
     "returns errSecSuccess; x3 is evaluation context, not CFErrorRef *"),
]


class PatchError(Exception):
    pass


def page_hash_updates(mm: mmap.mmap, writes: list[tuple], size: int):
    sig_off, sig_size = struct.unpack_from("<QQ", mm, 0x28)
    if not sig_off or sig_off + sig_size > size:
        raise PatchError("dyld cache has invalid code-signature range")
    magic, sb_len, count = struct.unpack_from(">III", mm, sig_off)
    if magic != SUPERBLOB_MAGIC or sb_len < 12 + count * 8 or sb_len > sig_size:
        raise PatchError("invalid Code Signing SuperBlob")

    result = []
    for idx in range(count):
        slot_type, rel = struct.unpack_from(">II", mm, sig_off + 12 + idx * 8)
        cd = sig_off + rel
        if cd + 4 > sig_off + sb_len:
            raise PatchError("CodeDirectory blob header outside SuperBlob")
        if struct.unpack_from(">I", mm, cd)[0] != CODEDIRECTORY_MAGIC:
            continue
        if cd + 40 > sig_off + sb_len:
            raise PatchError("CodeDirectory header outside SuperBlob")
        cd_len = struct.unpack_from(">I", mm, cd + 4)[0]
        if cd_len < 40 or cd + cd_len > sig_off + sb_len:
            raise PatchError("invalid CodeDirectory length")
        hash_off, _ident, _special, n_code, code_limit = struct.unpack_from(">IIIII", mm, cd + 16)
        hash_size, hash_type, _platform, page_shift = mm[cd + 36:cd + 40]
        if hash_type not in HASHES or not hash_size or page_shift > 30:
            raise PatchError(f"unsupported CodeDirectory hash parameters in slot {slot_type:#x}")
        page_size = 1 << page_shift
        if code_limit > sig_off or n_code < (code_limit + page_size - 1) // page_size:
            raise PatchError("CodeDirectory code-limit/page count is inconsistent")
        pages = sorted({(va - CACHE_BASE) // page_size for _name, va, _old, _new, _note in writes})
        updates = []
        for page in pages:
            start = page * page_size
            end = min(start + page_size, code_limit)
            if start >= code_limit or page >= n_code:
                continue
            image = bytearray(mm[start:end])
            for _name, va, _old, new, _note in writes:
                off = va - CACHE_BASE
                if start <= off and off + len(new) <= end:
                    image[off - start:off - start + len(new)] = new
                elif start < off + len(new) and off < end:
                    raise PatchError(f"patch at {va:#x} crosses a CodeDirectory page boundary")
            digest = hashlib.new(HASHES[hash_type], image).digest()[:hash_size]
            slot = cd + hash_off + page * hash_size
            if slot + hash_size > cd + cd_len:
                raise PatchError("CodeDirectory page-hash slot exceeds directory")
            updates.append((slot, digest, page, HASHES[hash_type], start, end))
        if updates:
            result.append((slot_type, updates))
    if not result:
        raise PatchError("no CodeDirectory page hashes cover the patch sites")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", type=Path, help="lowered-original dyld_shared_cache_arm64e.01")
    parser.add_argument("--restore", action="store_true", help="restore verified original instructions")
    args = parser.parse_args()
    path = args.file
    if not path.is_file():
        parser.error(f"file not found: {path}")
    if path.stat().st_size < 0x1000:
        parser.error("input is too small to be a dyld subcache")

    f = None
    mm = None
    try:
        f = path.open("r+b")
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE)
        if mm[:len(CACHE_MAGIC)] != CACHE_MAGIC:
            raise PatchError(f"wrong dyld cache magic: {mm[:len(CACHE_MAGIC)]!r}")
        before = hashlib.sha256(mm[:]).hexdigest()
        if args.restore:
            if PATCHED_SHA256 == "TO_BE_FILLED" or before != PATCHED_SHA256:
                raise PatchError(f"--restore requires exact patched SHA-256 {PATCHED_SHA256}; got {before}; NOT writing")
            writes = [(name, va, new, old, note) for name, va, old, new, note in PATCHES]
            expected = {va: new for _name, va, _old, new, _note in PATCHES}
        else:
            if before != LOWERED_ORIGINAL_SHA256:
                raise PatchError(f"requires lowered original SHA-256 {LOWERED_ORIGINAL_SHA256}; got {before}; NOT writing")
            writes = PATCHES
            expected = {va: old for _name, va, old, _new, _note in PATCHES}

        for name, va, old, _new, _note in writes:
            off = va - CACHE_BASE
            if off < 0 or off + len(old) > len(mm):
                raise PatchError(f"{name}: VA {va:#x} is outside .01's file-backed mapping")
            got = bytes(mm[off:off + len(old)])
            if got != expected[va]:
                raise PatchError(f"{name}: at VA {va:#x}, got {got.hex()}, expected {expected[va].hex()}; NOT writing")

        hash_updates = page_hash_updates(mm, writes, len(mm))
        for _name, va, _old, new, _note in writes:
            off = va - CACHE_BASE
            mm[off:off + len(new)] = new
        for _slot_type, updates in hash_updates:
            for slot, digest, _page, _alg, _start, _end in updates:
                mm[slot:slot + len(digest)] = digest
        mm.flush()
        f.flush()
        os.fsync(f.fileno())

        for name, va, _old, new, _note in writes:
            off = va - CACHE_BASE
            if bytes(mm[off:off + len(new)]) != new:
                raise PatchError(f"post-write instruction verification failed: {name}")
        for slot_type, updates in hash_updates:
            for slot, digest, page, alg, start, end in updates:
                actual = hashlib.new(alg, mm[start:end]).digest()[:len(digest)]
                if actual != digest or bytes(mm[slot:slot + len(digest)]) != digest:
                    raise PatchError(f"CodeDirectory verification failed in slot {slot_type:#x}, page {page}")

        after = hashlib.sha256(mm[:]).hexdigest()
        print(f"{'restored' if args.restore else 'patched'} in place: {path}")
        print(f"input SHA-256:  {before}")
        print(f"output SHA-256: {after}")
        for name, va, old, new, note in writes:
            print(f"  {name}: VA {va:#x}, {old.hex()} -> {new.hex()} ({note})")
        for slot_type, updates in hash_updates:
            pages = ", ".join(str(item[2]) for item in updates)
            print(f"  CodeDirectory slot {slot_type:#x}: refreshed {len(updates)} page hashes (pages {pages})")
        print("  No internal C++ validation methods were modified; Apple CMS data is unchanged.")
        return 0
    except (OSError, ValueError, struct.error, PatchError) as exc:
        print(f"patch-macos27-codesign-public: {exc}", file=sys.stderr)
        return 1
    finally:
        if mm is not None:
            mm.close()
        if f is not None:
            f.close()


if __name__ == "__main__":
    raise SystemExit(main())
