#!/usr/bin/env python3
"""Rank observed GPU counter intervals, without treating them as shader root causes."""
import argparse,json,math,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--trace-directory',type=Path,required=True);p.add_argument('--pid',type=int,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();src=a.trace_directory.resolve();out=a.output.resolve();assert src.is_relative_to(ROOT/'evidence') and src.is_dir();assert out.is_relative_to(ROOT/'evidence') and not out.exists();assert a.pid>0
records=[]
for pattern in [f'trace-gpu-timestamps-{a.pid}-*.json',f'trace-gpu-timeout-{a.pid}-*.json']:
 for file in src.glob(pattern):
  d=json.loads(file.read_text());dep=d.get('dependencies',d);counter=dep.get('gpuTimestamps',{});records.append((file,d,dep,counter))
intervals=[];faults=[];resolved=0;unresolved=0;empty=0
for file,d,dep,counter in records:
 if not counter.get('enabled'):continue
 if counter.get('CPUResolveSucceeded'):resolved+=1
 elif counter.get('samples'):unresolved+=1
 else:empty+=1
 samples=counter.get('samples',[])
 if file.name.startswith('trace-gpu-timeout-'):
  faults.append({'file':file.name,'submission':dep.get('submission'),'nativeErrorCode':d.get('errorCode'),'CPUResolveSucceeded':counter.get('CPUResolveSucceeded'),'samples':samples})
 for first,last in zip(samples,samples[1:]):
  if first.get('kind') not in ['graphics-pipeline','compute-pipeline','helper-graphics-pipeline']:continue
  if first.get('encoder')!=last.get('encoder') or not first.get('valid') or not last.get('valid'):continue
  start,end=first.get('timestamp',0),last.get('timestamp',0)
  if start<=0 or end<start:continue
  intervals.append({'label':first['label'],'kind':first['kind'],'ticks':end-start,'submission':dep.get('submission'),'file':file.name,'firstIndex':first['index'],'nextIndex':last['index']})
labels={}
for row in intervals:labels.setdefault(row['label'],[]).append(row)
ranked=[]
for label,rows in labels.items():
 ticks=sorted(r['ticks'] for r in rows);ranked.append({'label':label,'count':len(rows),'totalTimestampTicks':sum(ticks),'medianTimestampTicks':statistics.median(ticks),'p95TimestampTicks':ticks[math.ceil(len(ticks)*.95)-1],'maxTimestampTicks':ticks[-1],'largestIntervalEvidence':max(rows,key=lambda r:r['ticks'])})
ranked.sort(key=lambda x:x['maxTimestampTicks'],reverse=True)
result={'gameOrProbePID':a.pid,'nativeCounterRecords':resolved+unresolved+empty,'emptyCounterRecords':empty,'CPUResolvedRecords':resolved,'unresolvedRecords':unresolved,'validSameEncoderIntervals':len(intervals),'ranking':ranked,'faultRecords':faults,'intervalsAreNotExclusiveShaderExecutionTimes':True,'withBarrier':False,'exactShaderRootProven':False,'gamePlayableProven':False}
out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['ranking','faultRecords']}|{'topIntervals':ranked[:5]}))
