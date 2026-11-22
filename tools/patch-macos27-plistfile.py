#!/usr/bin/env python3
"""Guard PlistFile's SecureToken unlock-record list against a NULL context.

The supported macOS 27 test root is a single HFS+ volume with no SEP/APFS
Preboot SecureToken context. In 26B123, the internal list helper returns NULL
for a NULL context, but the exported query wrappers lock the context first.
The exported list wrapper's frame-setup instruction is replaced by a CBZ:
NULL branches to its existing epilogue with x0 still NULL; a non-NULL context
continues through the original lock/list/unlock code unchanged.

The patch is deliberately limited to the ARM64E list helper. It does not alter
token creation/binding or other PlistFile behavior. Run it on the original
PlistFile before PAC lowering.

Usage:
  tools/patch-macos27-plistfile.py FILE       # patch in place
  tools/patch-macos27-plistfile.py --restore FILE

The original instructions are checked exactly before either operation. The
embedded CodeDirectory page hashes for each changed slice are then refreshed;
entitlements and other signature blobs are preserved.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import tempfile
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFebabf
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
CPU_SUBTYPE_ARM64E_X1 = 12
CPU_SUBTYPE_MASK = 0x00FFFFFF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_SYMTAB = 0x02
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02

HASHES = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}
LIST_SYMBOL = "_securetoken_helpers_list_unlockrecords"
ORIGINAL_GUARD_SITE = bytes.fromhex("fd430091")  # add x29, sp, #0x10
EPILOGUE_OFFSET = 0x30  # ldp x29, x30, [sp, #0x10]
PAC_PROLOGUES = {
    bytes.fromhex("7f2303d5"),  # pacibsp
    bytes.fromhex("fea7c1da"),  # arm64e.x1 pacibsp form in this build
}


class PatchError(Exception):
    pass


def macho_slices(data: bytearray) -> list[tuple[int, int, int, str]]:
    """Return (file offset, size, subtype, label) for ARM64E slice(s)."""
    if len(data) >= 4 and struct.unpack_from(">I", data, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64):
        magic = struct.unpack_from(">I", data, 0)[0]
        nfat = struct.unpack_from(">I", data, 4)[0]
        is64 = magic == FAT_MAGIC_64
        ent_size = 32 if is64 else 20
        out = []
        for i in range(nfat):
            p = 8 + i * ent_size
            cputype, subtype = struct.unpack_from(">ii", data, p)
            if is64:
                off, size = struct.unpack_from(">QQ", data, p + 8)
            else:
                off, size = struct.unpack_from(">II", data, p + 8)
            cpu_subtype = subtype & CPU_SUBTYPE_MASK
            if cputype == CPU_TYPE_ARM64 and cpu_subtype in (CPU_SUBTYPE_ARM64E, CPU_SUBTYPE_ARM64E_X1):
                out.append((off, size, subtype, f"fat-slice-{i}-arm64e-subtype-0x{subtype & 0xffffffff:08x}"))
        if not out:
            raise PatchError("universal Mach-O has no ARM64E slice")
        return out

    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        raise PatchError("input is not a supported 64-bit Mach-O")
    cputype, subtype = struct.unpack_from("<ii", data, 4)
    if cputype != CPU_TYPE_ARM64 or (subtype & CPU_SUBTYPE_MASK) not in (CPU_SUBTYPE_ARM64E, CPU_SUBTYPE_ARM64E_X1):
        raise PatchError("thin Mach-O is not ARM64E")
    return [(0, len(data), subtype, "thin-arm64e")]


def macho_metadata(buf: bytearray, base: int, size: int) -> tuple[dict[str, int], list[tuple[int, int, int]], tuple[int, int]]:
    """Return symbol values, segments, and signature (offset,size) for a thin Mach-O."""
    if struct.unpack_from("<I", buf, base)[0] != MH_MAGIC_64:
        raise PatchError("ARM64E fat member is not MH_MAGIC_64")
    ncmds = struct.unpack_from("<I", buf, base + 16)[0]
    p = base + 32
    symtab = None
    sig = None
    segments: list[tuple[int, int, int]] = []  # vmaddr, fileoff, filesize
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, p)
        if cmdsize < 8 or p + cmdsize > base + size:
            raise PatchError("malformed Mach-O load command")
        if cmd == LC_SEGMENT_64:
            vmaddr, _vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", buf, p + 24)
            segments.append((vmaddr, fileoff, filesize))
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", buf, p + 8)
            symtab = (base + symoff, nsyms, base + stroff, strsize)
        elif cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack_from("<II", buf, p + 8)
            sig = (dataoff, datasize)
        p += cmdsize
    if symtab is None or sig is None:
        raise PatchError("missing LC_SYMTAB or LC_CODE_SIGNATURE")

    symoff, nsyms, stroff, strsize = symtab
    symbols: dict[str, int] = {}
    for i in range(nsyms):
        strx, n_type, _sect, _desc, value = struct.unpack_from("<IBBHQ", buf, symoff + i * 16)
        if strx >= strsize or not (n_type & 0x0E):  # N_SECT symbols only
            continue
        end = buf.find(b"\0", stroff + strx, stroff + strsize)
        if end < 0:
            continue
        name = bytes(buf[stroff + strx:end]).decode("ascii", errors="ignore")
        if name == LIST_SYMBOL:
            if name in symbols and symbols[name] != value:
                raise PatchError(f"duplicate symbol {name}")
            symbols[name] = value
    return symbols, segments, sig


def vm_to_fileoff(vmaddr: int, segments: list[tuple[int, int, int]]) -> int:
    for seg_vmaddr, fileoff, filesize in segments:
        if seg_vmaddr <= vmaddr < seg_vmaddr + filesize:
            return fileoff + vmaddr - seg_vmaddr
    raise PatchError(f"symbol VM address 0x{vmaddr:x} has no file-backed segment")


def refresh_code_directory(buf: bytearray, base: int, sig: tuple[int, int]) -> int:
    sigoff, sigsize = sig
    sigbase = base + sigoff
    if buf[sigbase:sigbase + 4] != struct.pack(">I", CSMAGIC_EMBEDDED_SIGNATURE):
        raise PatchError("embedded signature has unexpected magic")
    nblobs = struct.unpack_from(">I", buf, sigbase + 8)[0]
    changed_pages = 0
    for i in range(nblobs):
        _slot, off = struct.unpack_from(">II", buf, sigbase + 12 + i * 8)
        cd = sigbase + off
        if cd + 40 > sigbase + sigsize or buf[cd:cd + 4] != struct.pack(">I", CSMAGIC_CODEDIRECTORY):
            continue
        hash_off, _ident_off, _special, ncode, code_limit = struct.unpack_from(">IIIII", buf, cd + 16)
        hash_size, hash_type, _platform, page_exp = struct.unpack_from(">BBBB", buf, cd + 36)
        if hash_type not in HASHES or page_exp > 30 or hash_size == 0:
            raise PatchError(f"unsupported CodeDirectory hash type/page size ({hash_type}/{page_exp})")
        page_size = 1 << page_exp
        if code_limit > sigoff or ncode > (code_limit + page_size - 1) // page_size:
            raise PatchError("CodeDirectory codeLimit/page count is inconsistent")
        for page in range(ncode):
            start = page * page_size
            end = min(start + page_size, code_limit)
            digest = hashlib.new(HASHES[hash_type], bytes(buf[base + start:base + end])).digest()[:hash_size]
            slot = cd + hash_off + page * hash_size
            if buf[slot:slot + hash_size] != digest:
                buf[slot:slot + hash_size] = digest
                changed_pages += 1
    if changed_pages == 0:
        raise PatchError("no CodeDirectory page hashes changed; refusing to claim a signature refresh")
    return changed_pages


def verify_code_directory(buf: bytearray, base: int, sig: tuple[int, int]) -> None:
    sigoff, sigsize = sig
    sigbase = base + sigoff
    nblobs = struct.unpack_from(">I", buf, sigbase + 8)[0]
    for i in range(nblobs):
        _slot, off = struct.unpack_from(">II", buf, sigbase + 12 + i * 8)
        cd = sigbase + off
        if cd + 40 > sigbase + sigsize or buf[cd:cd + 4] != struct.pack(">I", CSMAGIC_CODEDIRECTORY):
            continue
        hash_off, _ident_off, _special, ncode, code_limit = struct.unpack_from(">IIIII", buf, cd + 16)
        hash_size, hash_type, _platform, page_exp = struct.unpack_from(">BBBB", buf, cd + 36)
        page_size = 1 << page_exp
        if hash_type not in HASHES:
            raise PatchError(f"unsupported CodeDirectory hash type {hash_type}")
        for page in range(ncode):
            start = page * page_size
            end = min(start + page_size, code_limit)
            digest = hashlib.new(HASHES[hash_type], bytes(buf[base + start:base + end])).digest()[:hash_size]
            slot = cd + hash_off + page * hash_size
            if buf[slot:slot + hash_size] != digest:
                raise PatchError(f"CodeDirectory page hash verification failed at page {page}")


def patch_slice(buf: bytearray, base: int, size: int, subtype: int, restore: bool) -> tuple[list[str], int]:
    symbols, segments, sig = macho_metadata(buf, base, size)
    if LIST_SYMBOL not in symbols:
        raise PatchError(f"ARM64E slice is missing expected symbol {LIST_SYMBOL}")
    fn_vm = symbols[LIST_SYMBOL]
    fn_off = vm_to_fileoff(fn_vm, segments)
    patch_off = base + fn_off + 12  # absolute file offset; replace only add x29, sp, #0x10
    epilogue_vm = fn_vm + EPILOGUE_OFFSET
    epilogue_off = base + vm_to_fileoff(epilogue_vm, segments)
    original = bytes(buf[patch_off:patch_off + 4])
    if restore:
        if original != bytes.fromhex("200100b4"):
            raise PatchError(f"{LIST_SYMBOL} guard at 0x{fn_vm + 12:x}: expected CBZ 200100b4, found {original.hex()}; NOT writing")
        new_bytes = ORIGINAL_GUARD_SITE
    else:
        if original != ORIGINAL_GUARD_SITE:
            raise PatchError(f"{LIST_SYMBOL} guard at 0x{fn_vm + 12:x}: expected original {ORIGINAL_GUARD_SITE.hex()}, found {original.hex()}; NOT writing")
        pac = bytes(buf[base + fn_off:base + fn_off + 4])
        if pac not in PAC_PROLOGUES:
            raise PatchError(f"{LIST_SYMBOL}: unexpected ARM64E entry PAC instruction {pac.hex()}")
        delta = epilogue_vm - (fn_vm + 12)
        if delta <= 0 or delta & 3 or not -(1 << 20) <= delta < (1 << 20):
            raise PatchError("guard branch target is out of range or unaligned")
        imm19 = (delta >> 2) & 0x7FFFF
        new_bytes = struct.pack("<I", 0xB4000000 | (imm19 << 5))  # cbz x0, epilogue
    if original == new_bytes:
        raise PatchError(f"{LIST_SYMBOL} is already in the requested state")
    buf[patch_off:patch_off + 4] = new_bytes
    pages = refresh_code_directory(buf, base, sig)
    verify_code_directory(buf, base, sig)
    report = [f"{LIST_SYMBOL}: slice+0x{fn_vm + 12:x}, file+0x{patch_off:x}: {original.hex()} -> {new_bytes.hex()}",
              f"guard branch target: slice+0x{epilogue_vm:x} (file+0x{epilogue_off:x})"]
    return report, pages


def atomic_replace(path: Path, data: bytes) -> None:
    st = path.stat()
    fd, tmpname = tempfile.mkstemp(prefix=path.name + ".", suffix=".new", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmpname, st.st_mode & 0o7777)
        os.replace(tmpname, path)
    except Exception:
        try:
            os.unlink(tmpname)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--restore", action="store_true", help="restore the checked original function prologues")
    parser.add_argument("file", type=Path)
    args = parser.parse_args()
    path = args.file
    if not path.is_file() or path.stat().st_size == 0:
        parser.error(f"missing/empty file: {path}")
    original_file = path.read_bytes()
    patched = bytearray(original_file)
    slices = macho_slices(patched)
    total_pages = 0
    lines = []
    for base, size, subtype, label in slices:
        if base + size > len(patched):
            raise PatchError(f"{label}: slice exceeds file size")
        report, pages = patch_slice(patched, base, size, subtype, args.restore)
        total_pages += pages
        lines.append(f"{label}: CodeDirectory page hashes refreshed: {pages}")
        lines.extend(report)
    if bytes(patched) == original_file:
        raise PatchError("result is byte-identical to input; refusing to write")
    atomic_replace(path, bytes(patched))
    action = "restored" if args.restore else "patched"
    print(f"{action} in place: {path}")
    for line in lines:
        print(line)
    print(f"input SHA-256:  {hashlib.sha256(original_file).hexdigest()}")
    print(f"output SHA-256: {hashlib.sha256(patched).hexdigest()}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PatchError as exc:
        print(f"patch-macos27-plistfile: {exc}", file=sys.stderr)
        raise SystemExit(1)
