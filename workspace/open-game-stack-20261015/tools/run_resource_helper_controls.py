#!/usr/bin/env python3
"""Exact native helper checks, bounded CPU control and Metal GPU readback; no game launch."""
import argparse,datetime,hashlib,json,os,pathlib,re,subprocess,time,plistlib,shlex,shutil
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--library',type=pathlib.Path,required=True);p.add_argument('--registration-delta-cache',action='store_true');p.add_argument('--descriptor-write-shards',action='store_true');a=p.parse_args()
if not re.fullmatch('[a-z0-9-]{1,64}',a.label):p.error('Safe unique label required')
lib=a.library.resolve()
if not lib.is_relative_to(root/'build') or not lib.is_file():p.error('Owned existing candidate required')
out=root/'evidence'/a.label;out.mkdir(exist_ok=False)
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_'))}
env.update(MTL_DEBUG_LAYER='1',MVK_AMD_ENCODER_LIVE_CACHE='1',MVK_AMD_CROSS_ENCODER_LIVE_CACHE='1',MVK_AMD_LIVE_LOOKUP_FAST_CACHE='1',MVK_AMD_DESCRIPTOR_USE_CACHE='1',MVK_AMD_DESCRIPTOR_SNAPSHOT_REUSE='1',MVK_AMD_CROSS_ENCODER_SNAPSHOT_REUSE='1',MVK_AMD_BATCH_LIVE_USE_RESOURCE='1',MVK_AMD_BATCH_ARGUMENT_HEAPS='1',MVK_AMD_ARGUMENT_HEAP_THRESHOLD='2',MVK_AMD_RESOURCE_USE_STATS='1',MVK_AMD_REGISTRATION_DELTA_CACHE=str(int(a.registration_delta_cache)))
env['MVK_AMD_DESCRIPTOR_WRITE_SHARDS']=str(int(a.descriptor_write_shards))
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
  if name=='registration_log_control':
   result=subprocess.run(args,env=env,stdout=so,stderr=se,timeout=50)
  else:
   # Launch the Metal controls as signed high-performance-GPU apps. Direct
   # command-line launch can select Intel UHD, and a launchd-started wrapper
   # that jumps back out into Documents can stall in dyld before main(). Keep
   # both executable and exact candidate dylib inside the app bundle.
   app=out/(name+'.app');macos=app/'Contents'/'MacOS';frameworks=app/'Contents'/'Frameworks'
   macos.mkdir(parents=True);frameworks.mkdir()
   bundled_binary=macos/name;bundled_lib=frameworks/'libCandidate.dylib'
   shutil.copy2(binary,bundled_binary);shutil.copy2(lib,bundled_lib)
   subprocess.run(['/usr/bin/install_name_tool','-change',str(lib),'@executable_path/../Frameworks/libCandidate.dylib',str(bundled_binary)],check=True)
   runner=macos/'run-probe'
   exports='\n'.join('export '+k+'='+shlex.quote(str(v)) for k,v in env.items() if k.startswith(('MVK_','MTL_')))
   runner.write_text('#!/bin/zsh\n'+exports+'\nexec '+shlex.quote(str(bundled_binary))+' "$@"\n');runner.chmod(0o755)
   with (app/'Contents'/'Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleExecutable':'run-probe','CFBundleIdentifier':'local.openstack.resource-control.'+name,
                   'CFBundleName':name,'CFBundlePackageType':'APPL','CFBundleVersion':'1',
                   'NSSupportsAutomaticGraphicsSwitching':False},f)
   subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   result=subprocess.run(['/usr/bin/open','-n','-W',str(app),'--args',str(report)],stdout=so,stderr=se,timeout=50)
 output=json.loads(report.read_text()) if report.exists() and report.stat().st_size else json.loads((out/(name+'.stdout')).read_text())
 record={'test':name,'exitCode':result.returncode,'elapsedSeconds':time.monotonic()-start,'output':output,'passed':result.returncode==0 and output.get('passed',False)};records.append(record)
 print(json.dumps(record),flush=True)
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'nativeSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'registrationDeltaCache':a.registration_delta_cache,'descriptorWriteShards':a.descriptor_write_shards,'metalValidationEnabled':True,'tests':records,'passed':all(x['passed'] for x in records),'gameStarted':False}
(out/'run.json').write_text(json.dumps(record,indent=2)+'\n');raise SystemExit(0 if record['passed'] else 1)
