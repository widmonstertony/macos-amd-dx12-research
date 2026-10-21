#!/usr/bin/env python3
"""Bounded recording across loading and first attack; no input or GPU semantic changes."""
import argparse,pathlib,subprocess,time,json,os,datetime,signal,shutil
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--pid',type=int,required=True);p.add_argument('--profile',required=True);p.add_argument('--seconds',type=int,default=120);a=p.parse_args();assert 10<=a.seconds<=600
import re
assert re.fullmatch('[a-z0-9-]{1,64}',a.profile)
folder=root/'evidence'/a.profile;profile=json.loads((folder/'build.json').read_text())[-1];assert profile['armedWorkTrace']
def identity():return subprocess.run(['ps','-p',str(a.pid),'-o','lstart=,comm='],capture_output=True,text=True).stdout.strip()
original=identity();assert 'SB-Win64-Shipping.exe' in original;assert shutil.disk_usage(root).free>=3*1024**3
marker=folder/'gpu-work-trace.arm';nonce=f'owned-game-{a.pid}-controller-{os.getpid()}';stop=False
start=time.monotonic();record={'pid':a.pid,'controllerPID':os.getpid(),'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'maximumControllerSeconds':a.seconds,'nativeMarkerFreshnessSeconds':30,'refreshEverySeconds':20,'diagnosticOnly':True,'refreshes':[]}
def finish(*_):
 global stop
 stop=True
signal.signal(signal.SIGTERM,finish);signal.signal(signal.SIGINT,finish)
try:
 with marker.open('x') as f:f.write(nonce+'\n')
 print(json.dumps(record),flush=True);last=-20
 while not stop and time.monotonic()-start<a.seconds:
  if identity()!=original:record['finished']='game-exited-or-identity-changed';break
  if not marker.exists() or marker.read_text().strip()!=nonce:record['finished']='marker-ownership-changed';break
  if time.monotonic()-start-last>=20:
   os.utime(marker,None);last=time.monotonic()-start;record['refreshes'].append(last)
  time.sleep(1)
finally:
 if marker.exists() and marker.read_text().strip()==nonce:marker.unlink();record['markerRemoved']=True
 record['elapsedSeconds']=time.monotonic()-start;record['endUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();(folder/f'capture-controller-{a.pid}.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
