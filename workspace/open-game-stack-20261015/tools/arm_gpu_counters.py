#!/usr/bin/env python3
"""Refresh a timed GPU-counter marker for one bounded, verified game capture."""
import argparse,datetime,json,os,re,shutil,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--launch-record',type=Path,required=True);p.add_argument('--profile',required=True);p.add_argument('--seconds',type=int,default=300);p.add_argument('--after-compute-records',type=int,default=0);a=p.parse_args();assert a.after_compute_records>=0;assert 10<=a.seconds<=600 and re.fullmatch('[a-z0-9-]{1,64}',a.profile)
source=a.launch_record.resolve();assert source.is_relative_to(root/'evidence');launch=json.loads(source.read_text());assert launch['verified'] and launch['normalLicensedSteamRequest'];games=[v for v in launch['observed'].values() if v.get('candidateMapped') and v.get('originalWriteDenied')];assert len(games)==1;pid=games[0]['pid'];folder=root/'evidence'/a.profile;marker=folder/'gpu-counter.arm';header=(folder/'game-trial-config.h').read_text();assert f'setenv("MVK_AMD_GPU_COUNTER_TRACE_ARM_PATH", "{marker}", 1)' in header
def identity():return subprocess.run(['ps','-p',str(pid),'-o','lstart=,comm='],capture_output=True,text=True).stdout.strip()
original=identity();assert 'SB-Win64-Shipping.exe' in original
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');out=folder/f'counter-arm-{stamp}.json';assert not out.exists();record={'gamePID':pid,'startUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'maximumSeconds':a.seconds,'refreshSeconds':10,'signalSent':False,'cacheDeleted':False,'refreshes':0,'minimumComputeRecords':a.after_compute_records};start=time.monotonic()
try:
 while time.monotonic()-start<a.seconds:
  if identity()!=original:record['finished']='game-exited-or-identity-changed';break
  if shutil.disk_usage(root).free<3*1024**3:record['finished']='disk-reserve-stop-capture';break
  if a.after_compute_records and record['refreshes']==0:
   observed=sum(1 for _ in (folder/'msl').glob(f'trace-compute-archive-{pid}-*.json'))
   if observed<a.after_compute_records:
    time.sleep(min(10,max(0,a.seconds-(time.monotonic()-start))));continue
   record['computeRecordsAtArming']=observed
  marker.touch();record['refreshes']+=1
  if record['refreshes']==1:print(json.dumps({'armed':True,'gamePID':pid,'maximumSeconds':a.seconds}),flush=True)
  time.sleep(min(10,max(0,a.seconds-(time.monotonic()-start))))
 else:record['finished']='bounded-capture-expired'
finally:
 if marker.exists():expired=time.time()-60;os.utime(marker,(expired,expired))
 record['endUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();out.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
