#!/usr/bin/env python3
"""Summarize native presented timestamps only inside observed foreground periods."""
import argparse,json,pathlib,math
p=argparse.ArgumentParser();p.add_argument('--pid',type=int,required=True);p.add_argument('--activity',type=pathlib.Path,required=True);p.add_argument('--trace-directory',type=pathlib.Path,required=True);p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
rows=[json.loads(line) for line in a.activity.read_text().splitlines() if line.strip()]
assert rows and all(x['pid']==a.pid for x in rows)
start,end=rows[0]['time'],rows[-1]['time'];eligible=[]
for f in a.trace_directory.glob(f'trace-present-progress-{a.pid}-*.json'):
 d=json.loads(f.read_text());t=d.get('time',0);duration=d.get('nativeIntervalSeconds',0);n=d.get('nativeTimestampCallbacks',0)
 if n>1 and duration>0 and t<=end and t-duration>=start:
  observed=[x for x in rows if t-duration-1<=x['time']<=t+1]
  if observed and all(x['active'] and x['visible'] and x['frontmostPID']==a.pid for x in observed):eligible.append(d)
callbacks=sum(x['nativeTimestampCallbacks']-1 for x in eligible);duration=sum(x['nativeIntervalSeconds'] for x in eligible)
result={'gamePID':a.pid,'activitySamples':len(rows),'referenceRange':[start,end],'allForeground':all(x['alive'] and x['active'] and x['visible'] and x['frontmostPID']==a.pid for x in rows),'nativePresentationRecords':len(eligible),'nativePresentationFPS':callbacks/duration if duration else None,'timestampIntervals':callbacks,'nativeIntervalSeconds':duration,'largestNativeGapMilliseconds':max((x.get('largestNativeGapMilliseconds',0) for x in eligible),default=None),'observedWindowPointSizes':sorted({(x['pointWidth'],x['pointHeight']) for x in rows}),'FPSIsNotGamePlayabilityProof':True,'FSR3UpscalingValidated':False,'FSR3FrameGenerationValidated':False}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
