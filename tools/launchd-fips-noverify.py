#!/usr/bin/env python3
"""launchd-fips-noverify.py IN OUT [--no-reboot-task NAME]... [--tolerant] : give launchd's embedded Boot task "fips"
(/usr/libexec/cc_fips_test) the -N option; --no-reboot-task removes RebootOnSuccess from Boot task NAME.

iOS 27.2: Boot.sysstatuscheck has RebootOnSuccess (and LimitLoadFromBootModes rem). On iOS 26 sysstatuscheck exited 1
here; on 27.2 launchd aborted (SIGABRT, initproc exited) right after "(sysstatuscheck) Doing boot task" with no
non-zero EXIT line for it, i.e. it most likely succeeded and launchd's reboot request failed. Without
RebootOnSuccess the task still runs and its result is ignored (it is AllowCrash, not RequireSuccess).


Lowering rewrites corecrypto's code, so cc_fips_test's FIPS integrity HMAC no longer matches and, with RequireSuccess,
launchd stops the boot. -N skips only the integrity check; the POST self-tests still run (iOS 26: 2026-11-13 01:50,
research/ios26/fips-fix). The plist lives in /sbin/launchd's __TEXT,__config section: it is rewritten without the
whitespace between tags, padded with newlines to its old length, and the CodeDirectory page hashes are refreshed.
Thin or fat (every arm64/arm64e slice). Prints the old and new Boot.fips entries."""
import sys, struct, plistlib, re, hashlib, os

ALGO = {1: 'sha1', 2: 'sha256', 3: 'sha256', 4: 'sha384'}


def sections(b):
    ncmds = struct.unpack_from('<I', b, 16)[0]
    p, sig = 32, None
    secs = {}
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', b, p)
        if cmd == 0x19:
            for k in range(struct.unpack_from('<I', b, p + 64)[0]):
                so = p + 72 + 80 * k
                name = b[so:so + 16].rstrip(b'\0').decode()
                size, off = struct.unpack_from('<QI', b, so + 40)
                secs[name] = (off, size)
        elif cmd == 0x1d:
            sig = struct.unpack_from('<II', b, p + 8)
        p += cs
    return secs, sig


def refresh(b, sig):
    so = sig[0]
    if b[so:so + 4] != b'\xfa\xde\x0c\xc0':
        sys.exit('no embedded signature')
    n = 0
    for i in range(struct.unpack_from('>I', b, so + 8)[0]):
        btype, boff = struct.unpack_from('>II', b, so + 12 + 8 * i)
        cd = so + boff
        if b[cd:cd + 4] != b'\xfa\xde\x0c\x02':
            continue
        hash_off, _, _, ncode, limit = struct.unpack_from('>IIIII', b, cd + 16)
        hsize, htype, page = b[cd + 36], b[cd + 37], 1 << b[cd + 39]
        for pg in range(ncode):
            h = hashlib.new(ALGO[htype], bytes(b[pg * page:min(pg * page + page, limit)])).digest()[:hsize]
            slot = cd + hash_off + pg * hsize
            if b[slot:slot + hsize] != h:
                b[slot:slot + hsize] = h
                n += 1
    return n


args = sys.argv[1:]
noreboot = [args[i + 1] for i, a in enumerate(args) if a == '--no-reboot-task']
args = [a for i, a in enumerate(args) if a != '--no-reboot-task' and (i == 0 or args[i - 1] != '--no-reboot-task')]
# --tolerant (macOS bring-up, 2026-11-20): every Boot task gets AllowCrash and loses RequireSuccess, so a task that
# crashes or fails is logged and the boot goes on, instead of launchd panicking the kernel (init_featureflags exited on
# SIGABRT, no AllowCrash -> panic). Meant until there is a shell to see why each one fails.
tolerant = '--tolerant' in args
args = [a for a in args if a != '--tolerant']
def patch_slice(b):
    secs, sig = sections(b)
    if '__config' not in secs or not sig:
        sys.exit('no __config section or no signature')
    off, size = secs['__config']
    raw = bytes(b[off:off + size])
    body = raw.rstrip(b'\0')
    pl = plistlib.loads(body)
    fips = pl.get('Boot', {}).get('fips')
    if fips is None:
        sys.exit('no Boot.fips entry')
    print('old Boot.fips:', fips)
    pargs = list(fips.get('ProgramArguments') or [os.path.basename(fips['Program'])])
    if "-N" not in pargs:
        pargs.append("-N")
    fips["ProgramArguments"] = pargs
    print('new Boot.fips:', fips)
    if tolerant:
        changed = []
        for name, task in pl['Boot'].items():
            if task.pop('RequireSuccess', None) or not task.get('AllowCrash'):
                changed.append(name)
            task['AllowCrash'] = True
        print('tolerant: AllowCrash, no RequireSuccess:', len(changed), 'Boot tasks')
    for name in noreboot:
        task = pl['Boot'].get(name)
        if task is None:
            sys.exit(f'no Boot.{name}')
        print(f'Boot.{name}: RebootOnSuccess', task.pop('RebootOnSuccess', None), '-> removed:', task)
    xml = plistlib.dumps(pl, fmt=plistlib.FMT_XML, sort_keys=False)
    xml = re.sub(rb'>\s+<', b'><', xml)
    xml = xml.replace(b'?><!DOCTYPE', b'?>\n<!DOCTYPE').replace(b'.dtd"><plist', b'.dtd">\n<plist')
    room = len(body) - len(xml)
    if room < 0:
        sys.exit(f'compacted plist is {-room} bytes too long')
    tail = b'</plist>\n'
    assert xml.endswith(tail)
    new = xml[:-len(tail)] + b'\n' * room + tail
    new += raw[len(body):]                     # trailing NULs as before
    assert len(new) == size and plistlib.loads(new.rstrip(b'\0')) == pl
    b[off:off + size] = new
    print('page hashes refreshed:', refresh(b, sig))


# 2026-11-20: macOS 27's /sbin/launchd is fat (two arm64e slices, each with its own __config and signature): every
# arm64/arm64e slice is patched the same way.
whole = bytearray(open(args[0], 'rb').read())
magic = struct.unpack_from('>I', whole)[0]
if magic in (0xcafebabe, 0xcafebabf):
    wide = magic == 0xcafebabf
    for i in range(struct.unpack_from('>I', whole, 4)[0]):
        if wide:
            cputype, sub, off, size = struct.unpack_from('>iiQQ', whole, 8 + 32 * i)
        else:
            cputype, sub, off, size = struct.unpack_from('>iiII', whole, 8 + 20 * i)
        if cputype != 0x0100000c:
            continue
        print(f'slice {i}: cpusubtype {sub & 0xffffffff:#x} at {off}')
        sl = bytearray(whole[off:off + size])
        patch_slice(sl)
        whole[off:off + size] = sl
elif struct.unpack_from('<I', whole)[0] == 0xfeedfacf:
    patch_slice(whole)
else:
    sys.exit('not a 64-bit Mach-O or fat file')
open(args[1], 'wb').write(whole)
