#!/usr/bin/env python3
"""mkmenuboot.py - one boot image for boot_b with the boot menu, iOS 27 and (later) macOS 27:

  python3 tools/mkmenuboot.py STOCK_boot.img SHIM.Image IOS27_boot.img [MACOS27_boot.img] OUT.img

2026-11-20: replaces tools/mktripleboot.py after the partition split (iOS 16 removed). IOS27_boot.img /
MACOS27_boot.img are ordinary boot images as tools/guac-mkboot.sh makes them (iOS 27: ufsroot=ios27;
macOS 27: ufsroot=macos). Their ramdisks are the SWEETXNU payloads (kernel + ADT + boot-args); they go
into one ramdisk, iOS 27 first, each starting on a 4 KiB boundary (shim/loader.c payload_at). The menu
(shim/shim.c) shows iOS 27 / macOS 27 / Android; macOS 27 is dimmed when its payload is absent. ABL
leaves about 50 MiB for the ramdisk above the DTB, less the shim's own size (3.5 MB with the menu
pictures): the image is refused past 46 MiB. Writes nothing to
the phone.
"""
import os, struct, subprocess, sys, tempfile

HDR = "<8s10I16s512s32s1024sIQIIQ"
RAMDISK_ROOM = 46 * 1024 * 1024  # ~50 MiB, less the menu pictures in the shim (3.3 MB, shim/art.S)


def ramdisk_of(path):
    b = open(path, "rb").read()
    if b[:8] != b"ANDROID!":
        sys.exit(f"{path}: not an Android boot image")
    f = struct.unpack_from(HDR, b, 0)
    ksz, rsz, page = f[1], f[3], f[8]
    off = page * (1 + (ksz + page - 1) // page)
    rd = b[off:off + rsz]
    if rd[:8] != b"SWEETXNU":
        sys.exit(f"{path}: its ramdisk is not a SWEETXNU payload")
    cmd = rd[0x48:0x48 + 608].split(b"\0")[0].decode(errors="replace")
    return rd, cmd


def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    stock, shim = sys.argv[1:3]
    out = sys.argv[-1]
    imgs = sys.argv[3:-1]
    names = ["iOS 27", "macOS 27"][:len(imgs)]
    wants = ["ufsroot=ios27 ", "ufsroot=macos "]
    pays = []
    for name, path, want in zip(names, imgs, wants):
        p, c = ramdisk_of(path)
        if want not in c + " ":
            print(f"warning: {name} payload boot-args have no '{want.strip()}': {c[:120]}...", file=sys.stderr)
        pays.append((name, p, c))
    blob = b""
    for _, p, _ in pays:
        blob += b"\0" * (-len(blob) % 4096) + p
    if len(blob) > RAMDISK_ROOM:
        sys.exit(f"payloads are {len(blob)} B, more than the {RAMDISK_ROOM} B ABL leaves for the ramdisk")
    with tempfile.NamedTemporaryFile(delete=False, suffix=".bin") as t:
        t.write(blob)
        tmp = t.name
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        subprocess.check_call([sys.executable, os.path.join(here, "mkguacboot.py"), stock, shim, out, "--ramdisk", tmp])
    finally:
        os.unlink(tmp)
    print(f"payloads: " + ", ".join(f"{n} {len(p)} B" for n, p, _ in pays) + f"; ramdisk {len(blob)} B of {RAMDISK_ROOM}; image {os.path.getsize(out)} B")
    for n, _, c in pays:
        print(f"{n} args:", c)


if __name__ == "__main__":
    main()
