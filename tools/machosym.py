import struct,sys,bisect,subprocess
path=sys.argv[1]
f=open(path,'rb'); data=f.read()
magic,cpu,sub,ftype,ncmds,size,flags,res=struct.unpack_from('<IiiIIIII',data,0)
assert magic==0xfeedfacf, hex(magic)
off=32; syms=[]
for _ in range(ncmds):
    cmd,cmdsize=struct.unpack_from('<II',data,off)
    if cmd==0x2:  # LC_SYMTAB
        symoff,nsyms,stroff,strsize=struct.unpack_from('<IIII',data,off+8)
        for i in range(nsyms):
            n_strx,n_type,n_sect,n_desc,n_value=struct.unpack_from('<IBBhQ',data,symoff+i*16)
            if n_type & 0xe0: continue  # stab
            if (n_type & 0x0e)!=0x0e or n_value==0: continue  # N_SECT only
            end=data.index(b'\0',stroff+n_strx)
            syms.append((n_value,data[stroff+n_strx:end].decode('utf8','replace')))
    off+=cmdsize
syms.sort(); vals=[v for v,_ in syms]
names=[]
for line in sys.stdin:
    p=line.split()
    if not p or not p[0].startswith('0x'): continue
    a=int(p[0],16); i=bisect.bisect_right(vals,a)-1
    names.append((p, syms[i][1] if i>=0 else '?', a-(syms[i][0] if i>=0 else 0)))
dem=subprocess.run(['c++filt'],input='\n'.join(n for _,n,_ in names),capture_output=True,text=True).stdout.split('\n') if names else []
for (p,n,d),dn in zip(names,dem):
    print(p[1].rjust(4), (dn or n)[:150], '+%#x'%d)
