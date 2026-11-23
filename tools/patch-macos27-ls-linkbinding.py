#!/usr/bin/env python3
"""Make LaunchServices self-resolving volume bindings non-fatal in macOS 27.2.

The target is LinkBinding::resolveBinding in dyld_shared_cache_arm64e.01,
26B123.  The self case releases the extra Binding reference, clears
LinkBinding::fBinding, and then releases the URL.  The ordinary case releases
only the URL, as before.

Usage: tools/patch-macos27-ls-linkbinding.py CACHE [--restore]

The cache is updated in place, atomically.  Keep a copy before patching;
--restore reverses only these four instructions and refreshes their CodeDirectory
page hashes again.  Other patches in the cache are preserved.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
from pathlib import Path

CACHE_BASE = 0x180400000
TARGET_VA = 0x185C82B30
TARGET_OFF = TARGET_VA - CACHE_BASE

# B30..B3C.  Original: cmp; b.eq assert; mov x0,x20; b BE4.
ORIGINAL = bytes.fromhex("1f0013eb 40070054 e00314aa 2a000014")
# mov x21,x20; cmp x0,x19; b.eq BD0; b BE0.
PATCHED = bytes.fromhex("f50314aa 1f0013eb c0040054 29000014")

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
HASH_TYPES = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}


def refresh_code_directory_pages(data: bytearray, start: int, end: int) -> int:
    """Refresh CodeDirectory hashes for changed bytes in a dyld cache file."""
    if len(data) < 0x38:
        raise ValueError("cache header is truncated")
    sig_off, sig_size = struct.unpack_from("<QQ", data, 0x28)
    if sig_off <= 0 or sig_size <= 12 or sig_off + sig_size > len(data):
        raise ValueError("invalid dyld cache code-signature range")
    if start < 0 or end <= start or end > sig_off:
        raise ValueError("patch is outside the signed cache data")

    magic, blob_len, count = struct.unpack_from(">III", data, sig_off)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE or blob_len > sig_size or blob_len < 12:
        raise ValueError("invalid embedded-signature superblob")
    changed = 0
    found_cd = False
    for i in range(count):
        slot_type, blob_off = struct.unpack_from(">II", data, sig_off + 12 + i * 8)
        if blob_off + 8 > blob_len:
            raise ValueError("signature blob index is out of range")
        cd = sig_off + blob_off
        cd_magic, cd_len = struct.unpack_from(">II", data, cd)
        if cd_magic != CSMAGIC_CODEDIRECTORY:
            continue
        found_cd = True
        if cd_len < 44 or blob_off + cd_len > blob_len:
            raise ValueError("invalid CodeDirectory length")
        hash_off, ident_off, n_special, n_code, code_limit = struct.unpack_from(">IIIII", data, cd + 16)
        hash_size, hash_type, _platform, page_exp = struct.unpack_from(">BBBB", data, cd + 36)
        if hash_type not in HASH_TYPES or not hash_size or page_exp > 30:
            raise ValueError("unsupported CodeDirectory hash parameters")
        page_size = 1 << page_exp
        # CodeLimit64 is present in version >= 0x20300 and supersedes codeLimit.
        version = struct.unpack_from(">I", data, cd + 8)[0]
        if version >= 0x20300 and cd_len >= 64:
            code_limit64 = struct.unpack_from(">Q", data, cd + 56)[0]
            if code_limit64:
                code_limit = code_limit64
        if code_limit > sig_off:
            raise ValueError("CodeDirectory covers bytes beyond the signed cache data")
        first_page = start // page_size
        last_page = (end - 1) // page_size
        if last_page >= n_code or first_page * page_size >= code_limit:
            raise ValueError("changed range is outside CodeDirectory code slots")
        for page_index in range(first_page, last_page + 1):
            page_start = page_index * page_size
            page_end = min(page_start + page_size, code_limit)
            digest = hashlib.new(HASH_TYPES[hash_type], data[page_start:page_end]).digest()[:hash_size]
            hash_slot = cd + hash_off + page_index * hash_size
            if hash_slot + hash_size > cd + cd_len:
                raise ValueError("CodeDirectory page hash slot is out of range")
            if data[hash_slot:hash_slot + hash_size] != digest:
                data[hash_slot:hash_slot + hash_size] = digest
                changed += 1
    if not found_cd:
        raise ValueError("no CodeDirectory found in cache signature")
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    parser.add_argument("--restore", action="store_true", help="restore the verified original instructions")
    args = parser.parse_args()
    path = args.cache
    if not path.is_file():
        parser.error(f"not a file: {path}")
    data = bytearray(path.read_bytes())
    if not data.startswith(b"dyld_v1  arm64e"):
        raise SystemExit("not an arm64e dyld shared cache; NOT writing")
    if len(data) < 0xE8 or struct.unpack_from("<Q", data, 0xE0)[0] != CACHE_BASE:
        raise SystemExit("not the expected .01 cache mapping; NOT writing")
    if len(data) <= TARGET_OFF + len(ORIGINAL):
        raise SystemExit("cache is too small for target; NOT writing")

    expected, replacement = (PATCHED, ORIGINAL) if args.restore else (ORIGINAL, PATCHED)
    actual = bytes(data[TARGET_OFF:TARGET_OFF + len(expected)])
    if actual != expected:
        print(f"unexpected target bytes at file offset 0x{TARGET_OFF:x}: {actual.hex(' ')}; NOT writing", file=sys.stderr)
        return 1

    before_sha = hashlib.sha256(data).hexdigest()
    data[TARGET_OFF:TARGET_OFF + len(replacement)] = replacement
    pages = refresh_code_directory_pages(data, TARGET_OFF, TARGET_OFF + len(replacement))
    if bytes(data[TARGET_OFF:TARGET_OFF + len(replacement)]) != replacement:
        raise SystemExit("post-patch instruction verification failed; NOT writing")
    mode = path.stat().st_mode & 0o777
    tmp = path.with_name(path.name + ".new")
    if tmp.exists():
        raise SystemExit(f"staging file already exists: {tmp}; NOT writing")
    tmp.write_bytes(data)
    os.chmod(tmp, mode)
    if tmp.stat().st_size != path.stat().st_size or tmp.read_bytes() != data:
        tmp.unlink(missing_ok=True)
        raise SystemExit("staging verification failed; NOT publishing")
    tmp.replace(path)
    print(f"{'restored' if args.restore else 'patched'}: {path}")
    print(f"cache base: 0x{CACHE_BASE:x}; target VA: 0x{TARGET_VA:x}; file offset: 0x{TARGET_OFF:x}")
    print(f"instructions: {expected.hex(' ')} -> {replacement.hex(' ')}")
    print(f"CodeDirectory page hashes refreshed: {pages}")
    print(f"input SHA-256:  {before_sha}")
    print(f"output SHA-256: {hashlib.sha256(data).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
