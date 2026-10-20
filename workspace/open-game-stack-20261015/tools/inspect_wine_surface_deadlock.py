#!/usr/bin/env python3
"""Read-only Wine mutex ownership inspection; never writes target memory."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser=argparse.ArgumentParser()
parser.add_argument('pid',type=int)
parser.add_argument('output',type=Path)
args=parser.parse_args()
name=subprocess.check_output(['ps','-p',str(args.pid),'-o','comm='],text=True).strip()
if not (name.endswith('SB-Win64-Shipping.exe') or name.endswith('d3d12_presentation_probe.exe')):
    raise SystemExit('Refusing unrelated process')
# Apple libpthread public types_internal.h: psynch m_tid at offset 24.
# Validate the mutex signature before interpreting any metadata.
code=r'''
import json,struct,lldb
t=lldb.debugger.GetSelectedTarget();p=t.GetProcess()
result={'pid':p.GetProcessID(),'readOnly':True,'locks':[],'waits':[]}
for name in ('retina_on', 'retina_enabled'):
    symbols=t.FindSymbols(name)
    if symbols.GetSize():
        address=symbols.GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
        error=lldb.SBError();data=p.ReadMemory(address,1,error)
        if error.Success() and len(data)==1: result[name]=bool(data[0])
counter=t.FindSymbols('get_surface_win_data.deferred_count')
if counter.GetSize():
    address=counter.GetContextAtIndex(0).GetSymbol().GetStartAddress().GetLoadAddress(t)
    error=lldb.SBError();data=p.ReadMemory(address,4,error)
    if error.Success() and len(data)==4:
        result['deferredSurfaceUpdateCount']=struct.unpack('<I',data)[0]
for name in ('win_data_mutex','surfaces_lock'):
    matches=t.FindSymbols(name)
    for i in range(matches.GetSize()):
        sym=matches.GetContextAtIndex(i).GetSymbol()
        address=sym.GetStartAddress().GetLoadAddress(t)
        error=lldb.SBError();data=p.ReadMemory(address,64,error)
        if not error.Success() or len(data)!=64: continue
        signature=struct.unpack_from('<Q',data)[0]
        if signature not in (0x4d555458,0x4d55545a): continue
        options=struct.unpack_from('<I',data,12)[0]
        owner=struct.unpack_from('<Q',data,24)[0]
        result['locks'].append({'name':name,'address':hex(address),'ownerNativeTID':owner,'recursiveDepth':options>>16})
addresses={int(x['address'],16):x for x in result['locks']}
for th in p:
    frame=th.GetFrameAtIndex(0)
    if '__psynch_mutexwait' not in (frame.GetFunctionName() or ''): continue
    value=frame.FindRegister('rdi').GetValueAsUnsigned()
    if value not in addresses: continue
    lock=addresses[value]
    result['waits'].append({'nativeTID':th.GetThreadID(),'threadName':th.GetName(),'waitingFor':lock['name'],'waitingForOwner':lock['ownerNativeTID']})
edges={x['nativeTID']:x['waitingForOwner'] for x in result['waits']}
result['twoThreadCycleConfirmed']=any(owner!=tid and edges.get(owner)==tid for tid,owner in edges.items())
print('WINE_SURFACE_LOCK_RESULT='+json.dumps(result))
'''
with tempfile.TemporaryDirectory(prefix='wine-lock-readonly-') as tmp:
    py=Path(tmp)/'inspect.py';py.write_text(code)
    commands=Path(tmp)/'commands'
    commands.write_text(f'script exec(open({str(py)!r}).read())\nprocess detach\nquit\n')
    # Batch command scripts perform no expressions in the inferior process.
    run=subprocess.run(['xcrun','lldb','-b','-p',str(args.pid),'-s',str(commands)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
    args.output.write_text(run.stdout)
    for line in run.stdout.splitlines():
        if line.startswith('WINE_SURFACE_LOCK_RESULT='): print(line)
    if run.returncode: raise SystemExit(run.returncode)
