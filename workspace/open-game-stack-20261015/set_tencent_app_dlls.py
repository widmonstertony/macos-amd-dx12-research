#!/usr/bin/env python3
"""Backed-up, per-executable Wine DLL preferences; never global/Sky settings."""
import argparse,datetime,json,os,pathlib,subprocess
p=pathlib.Path(__file__).resolve().parent;r=p.parent
ap=argparse.ArgumentParser();ap.add_argument('app',choices=['d3d12_probe.exe','d3d12_compute_probe.exe','d3d12_presentation_probe.exe','SB-Win64-Shipping.exe']);a=ap.parse_args()
support=pathlib.Path('/Users/tonytan/Library/Application Support/YYBIntelLauncher');c=support/'.runtime/wine-engine.app/Contents';prefix=pathlib.Path('/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine')
env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','WINE','YYB_','GFX_'))};env.update(WINEPREFIX=str(prefix),YYB_NTDLL_PATH=str(c/'SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so'),WINELOADER=str(support/'wine-loader'),WINESERVER=str(c/'MacOS/wineserver'),WINEDLLPATH=str(c/'SharedSupport/wine/lib/wine'),GFX_BACKEND_PATH=str(c/'Frameworks/render/dxvk/wine'),WINEDEBUG='-all')
cmd=['/usr/bin/sandbox-exec','-f',str(p/'tencent-normal-original-guard.sb'),'/usr/bin/env','DYLD_FALLBACK_LIBRARY_PATH='+str(c/'Frameworks'),str(support/'wine-loader'),str(c/'SharedSupport/wine/lib/wine/x86_64-windows/reg.exe')]
key='HKCU\\Software\\Wine\\AppDefaults\\'+a.app+'\\DllOverrides'
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');d=p/'evidence'/('tencent-app-dlls-'+a.app+'-'+stamp);d.mkdir()
record={'app':a.app,'key':key,'scope':'per executable only; not global or Sky','before':{},'after':{}}
for name in ['d3d12','d3d12core']:
    q=subprocess.run(cmd+['query',key,'/v',name],env=env,capture_output=True,text=True,timeout=20)
    record['before'][name]={'exitCode':q.returncode,'output':q.stdout}
    (d/'backup.json').write_text(json.dumps(record,indent=2)+'\n')
    v=subprocess.run(cmd+['add',key,'/v',name,'/t','REG_SZ','/d','native','/f'],env=env,capture_output=True,text=True,timeout=20)
    (d/(name+'-write.log')).write_text(v.stdout+v.stderr)
    if v.returncode:raise SystemExit('Per-app preference write failed; evidence '+str(d))
    q=subprocess.run(cmd+['query',key,'/v',name],env=env,capture_output=True,text=True,timeout=20)
    record['after'][name]={'exitCode':q.returncode,'output':q.stdout}
    if q.returncode or 'native' not in q.stdout:raise SystemExit('Per-app preference verification failed')
(d/'backup-and-result.json').write_text(json.dumps(record,indent=2)+'\n')
print('Verified native D3D12 preferences for '+a.app+' only; backup '+str(d))
