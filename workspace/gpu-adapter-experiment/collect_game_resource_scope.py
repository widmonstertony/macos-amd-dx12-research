#!/usr/bin/env python3
"""Read only exact Steam game public diagnostic counters from rotated logs."""
from pathlib import Path
import subprocess,re,json,datetime,sys
project=Path(__file__).resolve().parent.parent
expected=r"Z:\Documents\GitHub\gptk-intel-research-20261011\SteamClient\steamapps\common\StellarBlade\SB\Binaries\Win64\SB-Win64-Shipping.exe"
rows=subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines()
pids=[int(x.strip().split(None,1)[0]) for x in rows if x.strip().split(None,1)[-1]==expected]
if len(pids)!=1:print(json.dumps({'exactGameProcesses':pids,'state':'No unique actual game'}));sys.exit(2)
pid=pids[0];logdir=Path('/Users/tonytan/Library/Logs/com.tencent.yybmac.wine.engine/com.tencent.yybmac.wine.engine/log_wine_engine');raw=[]
for f in logdir.glob('yyb_wine.2026-10-13.log*'):
 for line in f.read_text(errors='replace').splitlines():
  if any(f'{kind} pid={pid} ' in line for kind in ['RESOURCE_SCOPE','PIPELINE_STATE','PIPELINE_FAILURE']):raw.append(line)
  elif line.startswith('PIPELINE_FAILURE_JSON '):
   try:
    if json.loads(line.removeprefix('PIPELINE_FAILURE_JSON ')).get('pid')==pid:raw.append(line)
   except (ValueError,TypeError):pass
raw=list(dict.fromkeys(raw));timed=sorted([x for x in raw if 'monotonicNs=' in x and not x.startswith('PIPELINE_FAILURE_JSON ')],key=lambda x:int(re.search(r'monotonicNs=(\d+)',x).group(1)))
def parse(x):return {k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',x)}
scopes=[parse(x) for x in timed if 'RESOURCE_SCOPE pid=' in x];pipelines=[parse(x) for x in timed if 'PIPELINE_STATE pid=' in x]
out={'time':datetime.datetime.now().isoformat(),'pid':pid,'scopeSamples':len(scopes),'latestScope':scopes[-1] if scopes else None,'pipelineSamples':len(pipelines),'latestPipeline':pipelines[-1] if pipelines else None,'failureRecords':[x for x in raw if 'PIPELINE_FAILURE' in x],'failureDetails':[json.loads(x.removeprefix('PIPELINE_FAILURE_JSON ')) for x in raw if x.startswith('PIPELINE_FAILURE_JSON ')],'scope':'Membership counts may overlap and are snapshots; not actual shader features/GPU outputs/FPS. Synchronous pipeline failures only; async not covered.'}
base=project/('yyb-game-resource-scope-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'));base.with_suffix('.json').write_text(json.dumps(out,indent=2)+'\n');base.with_suffix('.log').write_text('\n'.join(raw)+'\n');print(json.dumps(out,indent=2))
