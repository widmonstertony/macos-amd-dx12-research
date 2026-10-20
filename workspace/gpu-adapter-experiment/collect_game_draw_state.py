#!/usr/bin/env python3
"""Exact game PID and own public API telemetry only; no memory/account reads."""
from pathlib import Path
import subprocess,re,json,datetime,sys
project=Path(__file__).resolve().parent.parent
expected=r"Z:\Documents\GitHub\gptk-intel-research-20261011\SteamClient\steamapps\common\StellarBlade\SB\Binaries\Win64\SB-Win64-Shipping.exe"
rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True,errors='replace').splitlines()
pids=[int(l.strip().split(None,1)[0]) for l in rows if l.strip().split(None,1)[-1]==expected]
if len(pids)!=1:print(json.dumps({'exactGameProcesses':pids}));sys.exit(2)
pid=pids[0];records=[]
for file in Path('/Users/tonytan/Library/Logs/com.tencent.yybmac.wine.engine/com.tencent.yybmac.wine.engine/log_wine_engine').glob('yyb_wine.2026-10-13.log*'):
 for line in file.read_text(errors='replace').splitlines():
  if f'DRAW_STATE pid={pid} ' in line:records.append(line)
records=sorted(set(records),key=lambda x:int(re.search(r'monotonicNs=(\d+)',x)[1]))
values=[{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',l)} for l in records]
result={'time':datetime.datetime.now().isoformat(),'pid':pid,'scope':'Exact native indexed draw parameters/entered-returned counters, not GPU output or game FPS','samples':len(values),'latest':values[-1] if values else None}
if values:
 result['maximumEnteredReturnGap']=max(v['calls']-v['returns'] for v in values)
 result['sampledIndexBufferBoundsViolations']=sum(v['indexType'] not in [0,1] or v['offset']+v['count']*(2 if v['indexType']==0 else 4)>v['bufferLength'] for v in values)
p=project/('yyb-game-draw-state-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));p.with_suffix('.log').write_text('\n'.join(records)+'\n');p.with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
