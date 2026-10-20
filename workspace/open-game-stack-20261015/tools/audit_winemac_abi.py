#!/usr/bin/env python3
"""Compare named public source driver slots to installed immutable Mach-O data."""
from pathlib import Path
import hashlib,json,re,struct,subprocess
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'vendor/cx26-reference/sources/wine'
OUT=ROOT/'evidence/winemac-compat-20261019'
MODULE=Path.home()/'Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/SharedSupport/wine/lib/wine/x86_64-unix/winemac.so'
source=(SRC/'dlls/winemac.drv/gdi.c').read_text()
table=source.split('static const struct user_driver_funcs macdrv_funcs =',1)[1].split('\n};',1)[0]
header=(SRC/'include/wine/gdi_driver.h').read_text().split('struct user_driver_funcs\n{',1)[1].split('\n};',1)[0]
fields=set(re.findall(r'\(\*(p\w+)\)',header))
assignments={k:v for k,v in re.findall(r'\.(p\w+)\s*=\s*(\w+)',table) if k in fields}
c='#include "config.h"\n#include <stdio.h>\n#include <stddef.h>\n#include "wine/gdi_driver.h"\nint main(void){\n'
c+='printf("VERSION %u SIZE %zu CLIENT %zu\\n",WINE_GDI_DRIVER_VERSION,sizeof(struct user_driver_funcs),sizeof(struct client_surface));\n'
for field in assignments:
    c+=f'printf("{field} %zu\\n",offsetof(struct user_driver_funcs,{field}));\n'
c+='return 0;}\n'
(OUT/'cx26-layout.c').write_text(c)
subprocess.run(['clang','-D__WINESRC__','-DWINE_UNIX_LIB','-I',str(ROOT.parent/'wine-11.16-tls-build/include'),'-I',str(SRC/'include'),str(OUT/'cx26-layout.c'),'-o',str(OUT/'cx26-layout')],check=True)
layout=subprocess.check_output([str(OUT/'cx26-layout')],text=True)
(OUT/'cx26-layout.txt').write_text(layout)
symbols={};locations={}
for line in subprocess.check_output(['nm','-an',str(MODULE)],text=True).splitlines():
    parts=line.split()
    if len(parts)!=3: continue
    try: address=int(parts[0],16)
    except ValueError: continue
    symbols[address]=parts[2];locations[parts[2]]=address
data=MODULE.read_bytes();segments=[];off=32
for _ in range(struct.unpack_from('<I',data,16)[0]):
    cmd,size=struct.unpack_from('<II',data,off)
    if cmd==0x19: segments.append(struct.unpack_from('<QQQQ',data,off+24))
    off+=size
def read_pointer(address):
    for vm,_,fo,fs in segments:
        if vm<=address and address+8<=vm+fs:
            return struct.unpack_from('<Q',data,fo+address-vm)[0]
    raise ValueError(hex(address))
slots=[]
for line in layout.splitlines()[1:]:
    name,offset=line.split();offset=int(offset)
    pointer=read_pointer(locations['_macdrv_funcs']+offset)
    actual=symbols.get(pointer);expected='_'+assignments[name]
    slots.append({'field':name,'offset':offset,'sourceTarget':expected,'installedTarget':actual,'matches':actual==expected})
result={'module':str(MODULE),'moduleSHA256':hashlib.sha256(data).hexdigest(),'publicSource':'https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz','layout':layout.splitlines()[0],'slots':slots,'namedSlotsMatch':all(x['matches'] for x in slots),'limitations':['Matching slot addresses and versions do not prove all private structure layouts or semantics match.','Tencent optional native UI hooks remain NULL in the isolated source driver.','No installed module was modified.']}
(OUT/'abi-audit.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'layout':result['layout'],'namedSlots':len(slots),'namedSlotsMatch':result['namedSlotsMatch'],'mismatches':[x for x in slots if not x['matches']]}))
