#!/usr/bin/env python3
"""Observe an existing game window; optionally refresh its unchanged border."""
from pathlib import Path
import argparse, datetime, json, os, subprocess

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--refresh', action='store_true')
parser.add_argument('--show', action='store_true')
parser.add_argument('--once', action='store_true')
args=parser.parse_args()
support=Path.home()/'Library/Application Support/YYBIntelLauncher'
contents=support/'.runtime/wine-engine.app/Contents'
out=ROOT/'evidence/window-controls-20261020'
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','WINE','YYB_','VK_','VKD3D_','DXVK_','MVK_'))}
env.update(WINEPREFIX=str(Path.home()/'Library/Application Support/com.tencent.yybmac.wine.engine/wine'),
 YYB_NTDLL_PATH=str(contents/'SharedSupport/wine/lib/wine/x86_64-unix/ntdll.so'),
 YYB_WINESERVER_HOST_APP=str(support/'WineServerHost.app'),WINESERVER=str(support/'wineserver-wrapper'),
 WINELOADER=str(support/'wine-loader'),WINEDLLPATH=str(contents/'SharedSupport/wine/lib/wine'),
 GFX_BACKEND_PATH=str(contents/'Frameworks/render/dxvk/wine'),
 DYLD_LIBRARY_PATH=str(ROOT/'build/winemac-lockfix-leaf-select')+':/private/tmp/mvk-guard-proxy-select',
 DYLD_FALLBACK_LIBRARY_PATH=str(contents/'Frameworks'),WINEDEBUG='-all')
command=[str(support/'wine-loader'),str(out/'window_controls_probe.exe')]
if args.show:command.append('--show')
elif args.refresh:command.append('--refresh')
elif args.once:command.append('--once')
with (out/f'{stamp}-stdout.log').open('w') as stdout,(out/f'{stamp}-stderr.log').open('w') as stderr:
 process=subprocess.run(command,cwd=out,env=env,stdout=stdout,stderr=stderr,timeout=40)
print(json.dumps({'exitCode':process.returncode,'refreshRequested':args.refresh,'output':str(out/f'{stamp}-stdout.log')}))
print((out/f'{stamp}-stdout.log').read_text())
