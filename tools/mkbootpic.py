#!/usr/bin/env python3
"""
mkbootpic: the boot menu's boot picture (shown, centred on black, from choosing iOS / macOS until the system draws),
made from an image file you give it. Writes shim/out/bootpic.bin (shim/out is git-ignored; the picture never goes
into git). 2026-11-22.

  tools/mkbootpic.py IMAGE [--scale N] [--invert]
                                           --invert: light and dark swapped (an iBoot logo file stores a dark logo
                                           on a light surround; --invert gives a white logo on black)
                                           IMAGE: a PNG (8-bit, non-interlaced) or an iBoot image file (.im4p
                                           holding an 'iBootIm' lzss image, grey or argb), e.g. a logo file from
                                           your own firmware (unzip -p FIRMWARE.ipsw Firmware/all_flash/NAME.im4p)
  ... --kernel XNU_DIR                      also write XNU_DIR/osfmk/console/sweet_bootpic_data.c, so the kernel
                                           draws the same picture while it starts (osfmk/console/sweet_bootpic.c)
  tools/mkbootpic.py --none                no picture: the shim shows the chosen OS's menu picture as before
Output: 'SWBP', u16 width, u16 height (already scaled), then RGB bytes blended onto black.
"""
import struct, sys, zlib, os

def lzss(src, outlen):
    N, F, TH = 4096, 18, 2
    buf = bytearray(b'\x20' * N); r = N - F; out = bytearray(); i = 0; flags = 0
    while i < len(src) and len(out) < outlen:
        flags >>= 1
        if not flags & 0x100:
            flags = src[i] | 0xff00; i += 1
        if flags & 1:
            c = src[i]; i += 1; out.append(c); buf[r] = c; r = (r + 1) & (N - 1)
        else:
            if i + 1 >= len(src):
                break
            a, b = src[i], src[i + 1]; i += 2
            pos = a | ((b & 0xf0) << 4)
            for k in range((b & 0x0f) + TH + 1):
                c = buf[(pos + k) & (N - 1)]; out.append(c); buf[r] = c; r = (r + 1) & (N - 1)
    return bytes(out)

def from_iboot(d):
    o = d.find(b'iBootIm\0')
    comp, fmt = d[o + 12:o + 16][::-1], d[o + 16:o + 20][::-1]
    w, h = struct.unpack_from('<HH', d, o + 20)
    if comp != b'lzss' or fmt not in (b'grey', b'argb'):
        sys.exit(f'unsupported iBoot image: {comp} {fmt}')
    bpp = 2 if fmt == b'grey' else 4
    px = lzss(d[o + 0x40:], w * h * bpp)
    rgba = []
    for p in range(w * h):
        if fmt == b'grey':
            g, a = px[2 * p], px[2 * p + 1]; rgba.append((g, g, g, a))
        else:   # stored b, g, r, a
            b_, g_, r_, a = px[4 * p:4 * p + 4]; rgba.append((r_, g_, b_, a))
    return w, h, rgba

def from_png(d):
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit('not a PNG or iBoot image')
    i = 8; idat = b''; w = h = 0
    while i < len(d):
        n, t = struct.unpack_from('>I4s', d, i); c = d[i + 8:i + 8 + n]; i += 12 + n
        if t == b'IHDR':
            w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', c)
            if depth != 8 or inter or ctype not in (0, 2, 4, 6):
                sys.exit('PNG must be 8-bit, non-interlaced, grey/RGB(A)')
        elif t == b'IDAT':
            idat += c
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]; raw = zlib.decompress(idat); stride = w * ch
    rows = []; prev = bytearray(stride); p = 0
    for y in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0; b = prev[x]; c = prev[x - ch] if x >= ch else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    rgba = []
    for line in rows:
        for x in range(w):
            q = line[x * ch:x * ch + ch]
            rgba.append((q[0], q[0], q[0], 255) if ch == 1 else (q[0], q[0], q[0], q[1]) if ch == 2 else
                        (q[0], q[1], q[2], 255) if ch == 3 else tuple(q))
    return w, h, rgba

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, '..', 'shim', 'out', 'bootpic.bin')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    if sys.argv[1:] == ['--none']:
        open(out, 'wb').write(b'SWBP' + struct.pack('<HH', 0, 0)); print(out, 'no picture'); return
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    scale = int(sys.argv[sys.argv.index('--scale') + 1]) if '--scale' in sys.argv else 0
    invert = '--invert' in sys.argv
    d = open(sys.argv[1], 'rb').read()
    w, h, rgba = from_iboot(d) if b'iBootIm\0' in d[:4096] else from_png(d)
    if not scale:   # about a fifth of the 1440-pixel panel width, at least 1
        scale = max(1, 288 // w) if w else 1
    W, H = w * scale, h * scale
    if W > 1440 or H > 3120:
        sys.exit(f'{W}x{H} does not fit the panel')
    px = bytearray()
    for Y in range(H):
        for X in range(W):
            r, g, b, a = rgba[(Y // scale) * w + X // scale]
            r, g, b = r * a // 255, g * a // 255, b * a // 255
            if invert:		# after the alpha: an iBoot logo is an opaque light surround with a see-through logo
                r, g, b = 255 - r, 255 - g, 255 - b
            px += bytes((r, g, b))
    blob = b'SWBP' + struct.pack('<HH', W, H) + px
    open(out, 'wb').write(blob)
    print(f'{out}: {w}x{h} x{scale} -> {W}x{H}, {len(px)} bytes')
    if '--kernel' in sys.argv:
        kdir = sys.argv[sys.argv.index('--kernel') + 1]
        kout = os.path.join(kdir, 'osfmk', 'console', 'sweet_bootpic_data.c')
        with open(kout, 'w') as f:
            f.write('/* generated by tools/mkbootpic.py --kernel from the boot menu picture; not in any repository */\n')
            f.write('const unsigned char sweet_bootpic_data[%d] = {\n' % len(blob))
            for i in range(0, len(blob), 24):
                f.write('\t' + ', '.join('0x%02x' % c for c in blob[i:i + 24]) + ',\n')
            f.write('};\nconst unsigned int sweet_bootpic_size = %d;\n' % len(blob))
        print(kout, len(blob), 'bytes')

main()
