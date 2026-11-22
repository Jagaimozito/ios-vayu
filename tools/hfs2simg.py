#!/usr/bin/env python3
"""hfs2simg.py RAW.img OUT.simg [--limit BLOCKS] - Android sparse image of a raw HFS+ volume image for fastboot.

2026-11-20: the ios27-root-80g.simg made with a generic converter marked every all-zero 4 KiB block "don't care",
including blocks the filesystem uses (zero pages inside dyld, catalog and allocation-bitmap nodes). fastboot skips
"don't care", so those blocks kept the OLD system's data on the phone: dyld and the dyld cache were corrupted and
launchd crashed. Here the HFS+ allocation bitmap decides: used blocks are always written (RAW, or FILL 0 when they
are zeros), only free blocks are "don't care". Python 3 only, no other packages.
"""
import struct, sys

RAW, FILL, DONTCARE = 0xCAC1, 0xCAC2, 0xCAC3
BS = 4096


def bitmap(f):
    f.seek(1024); vh = f.read(512)
    assert vh[:2] in (b'H+', b'HX'), 'not an HFS+ volume'
    bs, total = struct.unpack_from('>II', vh, 40)
    assert bs == BS, 'allocation block size %d, expected 4096' % bs
    size, = struct.unpack_from('>Q', vh, 112)
    ext = [struct.unpack_from('>II', vh, 112 + 16 + 8 * i) for i in range(8)]
    bm = b''
    for st, cnt in ext:
        if cnt and len(bm) < size:
            f.seek(st * BS); bm += f.read(cnt * BS)
    assert len(bm) >= size, 'allocation file has extents beyond the volume header (not supported)'
    return total, bm[:size]


def used_runs(total, bm):
    """(start, end) runs of allocated blocks, from the bitmap bytes."""
    runs = []; i = 0; nbytes = (total + 7) // 8
    while i < nbytes:
        b = bm[i]
        if b == 0:
            j = i
            while j < nbytes and bm[j] == 0: j += 1
            i = j; continue
        if b == 0xff:
            j = i
            while j < nbytes and bm[j] == 0xff: j += 1
            s, e = i * 8, min(j * 8, total)
            if runs and runs[-1][1] == s: runs[-1][1] = e
            else: runs.append([s, e])
            i = j; continue
        for k in range(8):
            blk = i * 8 + k
            if blk < total and (b >> (7 - k)) & 1:
                if runs and runs[-1][1] == blk: runs[-1][1] = blk + 1
                else: runs.append([blk, blk + 1])
        i += 1
    return runs


def main():
    a = sys.argv[1:]
    limit = None
    if '--limit' in a:
        k = a.index('--limit'); limit = int(a[k + 1]); del a[k:k + 2]
    src, dst = a
    f = open(src, 'rb')
    total, bm = bitmap(f)
    if limit: total = min(total, limit)
    runs = [[s, min(e, total)] for s, e in used_runs(total, bm) if s < total]
    out = open(dst, 'wb')
    out.write(b'\0' * 28)
    nchunks = 0; pos = 0; nraw = nfill = 0
    def chunk(t, n, data=b''):
        nonlocal nchunks
        out.write(struct.pack('<HHII', t, 0, n, 12 + len(data))); out.write(data); nchunks += 1
    zero = bytes(BS)
    for s, e in runs:
        if s > pos: chunk(DONTCARE, s - pos)
        b = s
        while b < e:
            n = min(e - b, 2048)          # read up to 8 MiB at a time
            f.seek(b * BS); data = f.read(n * BS)
            assert len(data) == n * BS, 'short read at block %d' % b
            k = 0
            while k < n:                   # split into zero / non-zero sub-runs
                z = data[k * BS:(k + 1) * BS] == zero
                j = k + 1
                while j < n and (data[j * BS:(j + 1) * BS] == zero) == z: j += 1
                if z: chunk(FILL, j - k, b'\0\0\0\0'); nfill += j - k
                else: chunk(RAW, j - k, data[k * BS:j * BS]); nraw += j - k
                k = j
            b += n
        pos = e
        sys.stderr.write('\r%5.1f%%' % (100.0 * pos / total))
    if pos < total: chunk(DONTCARE, total - pos)
    out.seek(0)
    out.write(struct.pack('<IHHHHIIII', 0xED26FF3A, 1, 0, 28, 12, BS, total, nchunks, 0))
    out.close()
    sys.stderr.write('\n')
    print('%s: %d blocks, %d used (%d data, %d zero-filled), %d chunks' % (dst, total, nraw + nfill, nraw, nfill, nchunks))


if __name__ == '__main__':
    main()
