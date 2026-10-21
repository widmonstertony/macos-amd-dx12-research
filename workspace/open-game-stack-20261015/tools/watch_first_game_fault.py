#!/usr/bin/env python3
"""Bounded preservation and teardown of one already-failed, verified game test."""
import argparse,pathlib,json,subprocess,time,shutil,os,signal,datetime,re
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--launch-record',type=pathlib.Path,required=True);p.add_argument('--profile',required=True);p.add_argument('--seconds',type=int,default=600);p.add_argument('--output',type=pathlib.Path);a=p.parse_args();assert 10<=a.seconds<=1800 and re.fullmatch('[a-z0-9-]{1,64}',a.profile)
lp=a.launch_record.resolve();assert lp.is_relative_to(root/'evidence');launch=json.loads(lp.read_text());assert launch['verified'] and launch['normalLicensedSteamRequest'];game=[x for x in launch['observed'].values() if x.get('candidateMapped') and x.get('originalWriteDenied')];assert len(game)==1;pid=game[0]['pid'];trace=root/'evidence'/a.profile/'msl'
def identity():return subprocess.run(['ps','-p',str(pid),'-o','lstart=,comm='],capture_output=True,text=True).stdout.strip()
original=identity();assert 'SB-Win64-Shipping.exe' in original
out=a.output.resolve() if a.output else root/'evidence'/f'first-armed-sword-fault-{pid}-20261021';assert out.is_relative_to(root/'evidence');out.mkdir(exist_ok=False);start=time.monotonic();detected=None
record={'gamePID':pid,'startUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'maximumSeconds':a.seconds,'cacheDeleted':False,'signalSent':False,'gamePlayable':False}
while time.monotonic()-start<a.seconds:
 files=list(trace.glob(f'trace-gpu-timeout-{pid}-*.json'))
 if files and detected is None:detected=time.monotonic();record['firstDetectedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();print(json.dumps({'detected':True,'gamePID':pid}),flush=True)
 if detected is not None:
  for f in files:shutil.copy2(f,out/f.name)
  if len(files)>=3 or time.monotonic()-detected>=10:
   record['faultFiles']=[f.name for f in files];record['freeBytesAtFailure']=shutil.disk_usage(root).free
   subprocess.run(['/usr/local/bin/python3',str(root/'tools/summarize_game_gpu_fault.py'),'--profile',a.profile,'--pid',str(pid),'--output',str(out/'dependency-analysis.json')],timeout=15)
   if identity()==original:os.kill(pid,signal.SIGTERM);record['signalSent']=True
   record['finished']='GPU-fault-preserved-then-stop-only-failed-test';break
 if identity()!=original:record['finished']='game-exited-or-identity-changed';break
 time.sleep(1)
else:record['finished']='bounded-watch-expired'
record['endUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();(out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
