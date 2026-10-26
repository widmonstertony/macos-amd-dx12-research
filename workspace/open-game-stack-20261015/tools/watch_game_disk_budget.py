#!/usr/bin/env python3
"""Bounded disk-headroom monitor for one verified normal-Steam game test."""
import argparse,pathlib,json,subprocess,time,os,signal,shutil,datetime
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--launch-record',required=True,type=pathlib.Path);p.add_argument('--seconds',type=int,default=900);p.add_argument('--allow-game-stop',action='store_true',help='Explicit opt-in; default only records low disk and leaves game under human control');a=p.parse_args();record=a.launch_record.resolve();assert record.is_relative_to(root/'evidence') and 30<=a.seconds<=900
launch=json.loads(record.read_text());assert launch['verified'] and launch['normalLicensedSteamRequest']
candidates=[x for x in launch['observed'].values() if x.get('candidateMapped') and x.get('originalWriteDenied')];assert len(candidates)==1;pid=candidates[0]['pid']
def identity():
 p=subprocess.run(['ps','-p',str(pid),'-o','lstart=,comm='],capture_output=True,text=True);return p.stdout.strip()
original=identity();assert 'SB-Win64-Shipping.exe' in original
out=record.parent/'disk-budget.jsonl';start=time.monotonic()
with out.open('x') as f:
 while time.monotonic()-start<a.seconds:
  now=identity();free=shutil.disk_usage(root).free;row={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'elapsedSeconds':time.monotonic()-start,'pid':pid,'freeBytes':free,'sameGameIdentity':now==original,'minimumReserveBytes':3*1024**3,'cacheDeleted':False}
  if now!=original:row['finished']='game-exited-or-identity-changed';f.write(json.dumps(row)+'\n');f.flush();break
  if free<3*1024**3:
   row['action']='low-disk-user-action-required';row['gameStopAuthorized']=a.allow_game_stop
   if a.allow_game_stop:row['action']='SIGTERM-explicitly-authorized-low-disk'
   f.write(json.dumps(row)+'\n');f.flush()
   if a.allow_game_stop:os.kill(pid,signal.SIGTERM)
   break
  f.write(json.dumps(row)+'\n');f.flush();time.sleep(5)
 else:f.write(json.dumps({'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'finished':'bounded-monitor-expired','seconds':a.seconds})+'\n');f.flush()
