#!/usr/bin/env python3
"""Bounded private 3D attachment GPU output test; never launches a game."""
import argparse,datetime,hashlib,json,os,pathlib,re,subprocess
p=pathlib.Path(__file__).resolve().parent
a=argparse.ArgumentParser();a.add_argument('--library',choices=['original','native-attachment','typed-roots'],required=True);a.add_argument('--heaps',choices=['1','2'],required=True);a.add_argument('--label',required=True);args=a.parse_args()
assert re.fullmatch('[A-Za-z0-9_-]{1,80}',args.label)
if args.library=='original':
 lib=p/'build/moltenvk/MoltenVK/libMoltenVK.1.4.2.dylib';expected='93709d752bdef141b2f7831539354f78d07f7a872ff2ee49b5d42d6c3f3a386d'
else:
 build=json.loads((p/('evidence/pending-native-typed-roots.json' if args.library=='typed-roots' else 'evidence/pending-native-3d-attachment.json')).read_text());lib=pathlib.Path(build['library']);expected=build['librarySHA256']
assert hashlib.sha256(lib.read_bytes()).hexdigest()==expected
d=p/'evidence'/args.label;d.mkdir(exist_ok=False)
icd=d/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','VKD3D_','MVK_','MTL_','WINE','YYB_'))}
env.update(PATH='/nonexistent',VK_ICD_FILENAMES=str(icd),MTL_DEBUG_LAYER='1',MVK_CONFIG_LOG_LEVEL='2',MVK_CONFIG_USE_MTLHEAP=args.heaps,MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_AMD_REFERENCE_RBA2='1',MVK_AMD_REFERENCE_RIA2='1',MVK_AMD_REFERENCE_NULL='1',MVK_AMD_BYTE_GUARDS='1')
exe=p/'build/probes/alias_3d_probe';cmd=[str(exe)]
j={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'library':str(lib),'librarySHA256':expected,'probeSHA256':hashlib.sha256(exe.read_bytes()).hexdigest(),'command':cmd,'heapMode':args.heaps,'gameStarted':False,'originalEnvironmentModified':False,'scope':'Private same-format framebuffer attachment implementation output, baseline upload plus slice-clear/witness readback. Native traits queried/requested unchanged. This is not Vulkan portability-feature conformance; sampled/storage views are outside scope.'}
with (d/'stdout.log').open('w')as out,(d/'stderr.log').open('w')as err:
 child=subprocess.Popen(cmd,env=env,stdout=out,stderr=err,start_new_session=True)
 try:j['exitCode']=child.wait(timeout=45)
 except subprocess.TimeoutExpired:child.kill();j['exitCode']=child.wait();j['timedOut']=True
out=(d/'stdout.log').read_text(errors='replace');err=(d/'stderr.log').read_text(errors='replace')
j['actualOutputPassed']=j['exitCode']==0 and 'RESULT PASS' in out;j['metalValidationEnabled']='Metal API Validation Enabled'in err
(d/'run.json').write_text(json.dumps(j,indent=2)+'\n');print(json.dumps(j,indent=2));print(out[-4500:]);print(err[-1500:])
raise SystemExit(0 if j['actualOutputPassed'] else 1)
