#!/usr/bin/env python3
"""
set-payload-args: copy a boot image (single or combined menu image) with words removed from / added to the boot-args of
the SWEETXNU payload whose args contain ufsroot=NAME. Kernel, ADT and everything else unchanged. 2026-11-22.
  tools/set-payload-args.py IN.img OUT.img ROOT [-word ...] [+word ...]
  e.g. tools/set-payload-args.py outputs/menu.img outputs/menu-quiet.img ios27 -debug=0xc -serial=3
"""
import re, sys
if len(sys.argv) < 5:
    sys.exit(__doc__)
src, dst, root = sys.argv[1:4]
ops = sys.argv[4:]
b = bytearray(open(src, 'rb').read())
done = 0; i = 0
while True:
    j = b.find(b'SWEETXNU', i)
    if j < 0:
        break
    i = j + 8
    off = j + 0x48
    raw = bytes(b[off:off + 608]).split(b'\0')[0]
    if ('ufsroot=%s' % root).encode() not in raw.split():
        continue
    words = raw.decode().split()
    for op in ops:
        w = op[1:]
        if op[0] == '-':
            if w not in words:
                sys.exit(f'{w} is not in the {root} args')
            words.remove(w)
        elif op[0] == '+':
            words.append(w)
        else:
            sys.exit('each change is -word or +word')
    new = ' '.join(words).encode()
    if len(new) > 607:
        sys.exit(f'args too long: {len(new)}')
    b[off:off + 608] = new + b'\0' * (608 - len(new))
    print(f'{root} args ({len(new)} chars): {new.decode()}')
    done += 1
if done != 1:
    sys.exit(f'found {done} payloads for ufsroot={root} (want 1)')
open(dst, 'wb').write(b)
print('wrote', dst)
