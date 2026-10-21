#!/usr/bin/env python3
"""Summarize observed GPU faults; never infer a shader root from a waiting queue."""
import argparse,json,pathlib,re,datetime
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--profile',required=True);p.add_argument('--pid',required=True,type=int);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args();assert re.fullmatch('[a-z0-9-]{1,64}',a.profile)
out=a.output.resolve();assert out.is_relative_to(root/'evidence');trace=root/'evidence'/a.profile/'msl'
faults=sorted([(f,json.loads(f.read_text())) for f in trace.glob(f'trace-gpu-timeout-{a.pid}-*.json')],key=lambda item:item[1]['time']);assert faults,'No GPU failure recorded'
result={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'gamePID':a.pid,'faultCount':len(faults),'exactShaderRootProven':False,'observations':[]}
for file,d in faults:
 dep=d['dependencies'];pending=d.get('pendingQueueDependencies',[]);waits=[]
 for e in dep.get('events',[]):
  if e['operation']!='wait':continue
  producers=[{'submission':r['submission'],'queueFamily':r['queueFamily'],'createdTime':r['createdTime'],'phases':r['phases'],'workCount':r.get('workCount',0),'workEvents':r.get('workEvents',[]),'events':r.get('events',[])} for r in pending if any(s['operation']=='signal' and s['event']==e['event'] and s['requestedValue']>=e['requestedValue'] for s in r.get('events',[]))]
  waits.append({'wait':e,'pendingPotentialProducers':producers,'observedSatisfied':isinstance(e.get('valueAtObservation'),int) and e['valueAtObservation']>=e['requestedValue']})
 result['observations'].append({'file':file.name,'queueFamily':d['queueFamily'],'failureTime':d['time'],'error':d['error'],'perEncoderWorkTraceEnabledAtFailure':d.get('perEncoderWorkTraceEnabled'),'dependency':dep,'encoders':d['encoders'],'waitAnalysis':waits})
out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'output':str(out),'faults':len(faults),'workCounts':[d['dependencies'].get('workCount',0) for _,d in faults],'exactShaderRootProven':False}))
