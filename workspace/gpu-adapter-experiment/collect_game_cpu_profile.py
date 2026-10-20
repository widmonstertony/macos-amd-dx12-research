#!/usr/bin/env python3
"""Read-only PID-scoped graphics counter collector; no process-memory/auth data."""
from pathlib import Path
import subprocess,re,json,datetime,sys
project=Path(__file__).resolve().parent.parent
expected=r"Z:\Documents\GitHub\gptk-intel-research-20261011\SteamClient\steamapps\common\StellarBlade\SB\Binaries\Win64\SB-Win64-Shipping.exe"
rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True,errors='replace').splitlines()
pids=[int(l.strip().split(None,1)[0]) for l in rows if l.strip().split(None,1)[-1]==expected]
if len(pids)!=1: print(json.dumps({'exactGameProcesses':pids,'state':'No unique game process'}));sys.exit(2)
pid=pids[0]
logdir=Path('/Users/tonytan/Library/Logs/com.tencent.yybmac.wine.engine/com.tencent.yybmac.wine.engine/log_wine_engine')
raw=[]
for f in logdir.glob('yyb_wine.2026-10-13.log*'):
    for line in f.read_text(errors='replace').splitlines():
        if f'SR_PERF pid={pid} ' in line:raw.append(line)
raw=sorted(set(raw),key=lambda x:int(re.search(r'monotonicNs=(\d+)',x).group(1)))
data=[{k:float(v) for k,v in re.findall(r'(\w+)=([\d.]+)',line)} for line in raw]
out={'time':datetime.datetime.now().isoformat(),'pid':pid,'samples':len(data),'process':subprocess.check_output(['ps','-p',str(pid),'-o','pid=,%cpu=,rss=,etime='],text=True).strip(),'scope':'CPU cumulative deltas, present requests, completed GPU CBs; NOT actual game FPS or per-game GPU utilization'}
if len(data)>1:
    b=data[-1];a=next((r for r in reversed(data[:-1]) if b['monotonicNs']-r['monotonicNs']>=30e9),data[0]);seconds=(b['monotonicNs']-a['monotonicNs'])/1e9
    out['windowSeconds']=seconds;out['latest']=b
    out['ratesPerSecond']={k:(b[k]-a[k])/seconds for k in b if k not in ['pid','monotonicNs','liveAllocations']}
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
base=project/f'yyb-game-profile-{pid}-{stamp}'
base.with_suffix('.log').write_text('\n'.join(raw)+'\n')
base.with_suffix('.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(out,indent=2))
