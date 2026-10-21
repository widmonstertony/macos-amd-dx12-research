#!/usr/bin/env python3
"""One scoped game attack with a short-lived native diagnostic marker. No launch."""
import argparse,pathlib,subprocess,json,os,time,datetime,uuid,shutil
from mac_session_state import session_state
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--pid',required=True,type=int);p.add_argument('--profile',required=True);p.add_argument('--label',required=True);p.add_argument('--scene-confirmed',action='store_true');a=p.parse_args()
import re
assert all(re.fullmatch('[a-z0-9-]{1,64}',x) for x in [a.profile,a.label]) and a.scene_confirmed
assert session_state().get('screenLocked') is False
comm=subprocess.check_output(['ps','-p',str(a.pid),'-o','comm='],text=True).strip();assert 'SB-Win64-Shipping.exe' in comm
folder=root/'evidence'/a.profile;profile=json.loads((folder/'build.json').read_text())[-1];assert profile['armedWorkTrace'] and profile['workCaptureMaximumSeconds']==30
trace=folder/'msl';marker=folder/'gpu-work-trace.arm';out=root/'evidence'/a.label;out.mkdir(exist_ok=False)
nonce=uuid.uuid4().hex;before={x.name for x in trace.glob(f'trace-gpu-timeout-{a.pid}-*.json')};record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'gamePID':a.pid,'candidateSHA256':profile['candidateSHA256'],'sceneConfirmedFromOwnWindow':True,'preexistingFailureFiles':sorted(before),'cacheDeleted':False,'samples':[]}
if before:
 record['invalidCaptureReason']='GPU timeout already occurred before arming; no input sent'
 (out/'result.json').write_text(json.dumps(record,indent=2)+'\n')
 print(json.dumps(record));raise SystemExit(2)
assert shutil.disk_usage(root).free >= 3*1024**3, 'Insufficient disk reserve for diagnosis'
try:
 with marker.open('x') as f:f.write(nonce+'\n')
 record['armedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();time.sleep(.4)
 assert session_state().get('screenLocked') is False
 result=subprocess.run([str(root/'build/game-test-input'),str(a.pid),'-3','80'],capture_output=True,text=True,timeout=8)
 record.update(inputExitCode=result.returncode,inputOutput=result.stdout,inputDiagnostic=result.stderr,inputCompletedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat());(out/'start.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({k:v for k,v in record.items() if k!='samples'}),flush=True)
 if result.returncode:raise RuntimeError('Scoped attack input was not sent')
 begin=time.monotonic()
 while time.monotonic()-begin<23:
  files=[x for x in trace.glob(f'trace-gpu-timeout-{a.pid}-*.json') if x.name not in before];alive=bool(subprocess.run(['ps','-p',str(a.pid),'-o','pid='],capture_output=True,text=True).stdout.strip());sample={'elapsed':time.monotonic()-begin,'alive':alive,'GPUFailureFiles':[x.name for x in files]};record['samples'].append(sample);print(json.dumps(sample),flush=True)
  for x in files:shutil.copy2(x,out/x.name)
  if not alive:break
  time.sleep(2)
 if session_state().get('screenLocked') is False:
  with (out/'capture.stdout').open('w') as so,(out/'capture.stderr').open('w') as se:
   try:subprocess.run([str(root/'build/measure-game-frames'),str(a.pid),str(out/'after.png')],stdout=so,stderr=se,timeout=4)
   except subprocess.TimeoutExpired:record['ownWindowCaptureTimedOut']=True
 record['attackGestureVisuallyVerified']=False
 record['gamePlayable']=False
finally:
 if marker.exists() and marker.read_text().strip()==nonce:marker.unlink();record['markerRemoved']=True
 record['endUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat();record['nativeCaptureAutomaticallyExpires']=True;record['maximumMarkerAgeSeconds']=30;(out/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'evidence':str(out),'markerRemoved':record.get('markerRemoved',False)}),flush=True)
