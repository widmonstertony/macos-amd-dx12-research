#!/usr/bin/env python3
"""Exact native helper checks, bounded CPU control and Metal GPU readback; no game launch."""
import argparse,datetime,hashlib,json,os,pathlib,re,subprocess,time
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--library',type=pathlib.Path,required=True);p.add_argument('--registration-delta-cache',action='store_true');a=p.parse_args()
if not re.fullmatch('[a-z0-9-]{1,64}',a.label):p.error('Safe unique label required')
lib=a.library.resolve()
if not lib.is_relative_to(root/'build') or not lib.is_file():p.error('Owned existing candidate required')
out=root/'evidence'/a.label;out.mkdir(exist_ok=False)
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_'))}
env.update(MTL_DEBUG_LAYER='1',MVK_AMD_ENCODER_LIVE_CACHE='1',MVK_AMD_CROSS_ENCODER_LIVE_CACHE='1',MVK_AMD_LIVE_LOOKUP_FAST_CACHE='1',MVK_AMD_DESCRIPTOR_USE_CACHE='1',MVK_AMD_DESCRIPTOR_SNAPSHOT_REUSE='1',MVK_AMD_CROSS_ENCODER_SNAPSHOT_REUSE='1',MVK_AMD_BATCH_LIVE_USE_RESOURCE='1',MVK_AMD_BATCH_ARGUMENT_HEAPS='1',MVK_AMD_ARGUMENT_HEAP_THRESHOLD='2',MVK_AMD_RESOURCE_USE_STATS='1',MVK_AMD_REGISTRATION_DELTA_CACHE=str(int(a.registration_delta_cache)))
records=[]
for name in ['registration_log_control','resource_lookup_epoch_gpu','heap_write_declaration_gpu']:
 binary=root/'build/probes'/name
 if name!='registration_log_control':
  proof=json.loads(binary.with_suffix('.build.json').read_text())
  assert proof['candidateSHA256']==hashlib.sha256(lib.read_bytes()).hexdigest()
 args=[str(binary)]
 report=out/(name+'.json')
 if name!='registration_log_control':args.append(str(report))
 start=time.monotonic()
 with (out/(name+'.stdout')).open('w') as so,(out/(name+'.stderr')).open('w') as se:
  result=subprocess.run(args,env=env,stdout=so,stderr=se,timeout=50)
 output=json.loads(report.read_text()) if report.exists() else json.loads((out/(name+'.stdout')).read_text())
 record={'test':name,'exitCode':result.returncode,'elapsedSeconds':time.monotonic()-start,'output':output,'passed':result.returncode==0 and output.get('passed',False)};records.append(record)
 print(json.dumps(record),flush=True)
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'nativeSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'registrationDeltaCache':a.registration_delta_cache,'metalValidationEnabled':True,'tests':records,'passed':all(x['passed'] for x in records),'gameStarted':False}
(out/'run.json').write_text(json.dumps(record,indent=2)+'\n');raise SystemExit(0 if record['passed'] else 1)
