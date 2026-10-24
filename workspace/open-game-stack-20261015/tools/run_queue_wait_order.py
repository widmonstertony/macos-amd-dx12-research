#!/usr/bin/env python3
"""Real GPU separate-event wait order control; no missing signal is submitted."""
import argparse,pathlib,json,hashlib,subprocess,os,re,time,plistlib,shlex,shutil
r=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=pathlib.Path,required=True);p.add_argument('--label',required=True);p.add_argument('--reverse',action='store_true');a=p.parse_args();lib=a.library.resolve();assert lib.is_relative_to(r/'build') and lib.is_file();assert re.fullmatch('[a-z0-9-]{1,64}',a.label)
out=r/'evidence'/a.label;out.mkdir(exist_ok=False);(out/'msl').mkdir()
s=(r/'src/queue_sync_probe.cpp').read_text()
def replace(old,new):
 global s
 assert s.count(old)==1,(old,s.count(old));s=s.replace(old,new)
replace('words=4096,rounds=64','words=4096,rounds=1024')
replace('VkSemaphore timeline;CHECK(vkCreateSemaphore(device,&si,nullptr,&timeline));','VkSemaphore timeline[3];for(unsigned i=0;i<3;++i)CHECK(vkCreateSemaphore(device,&si,nullptr,&timeline[i]));')
replace('timelineInfo.pWaitSemaphoreValues=i?&wait:nullptr;','timelineInfo.pWaitSemaphoreValues=i?&wait:nullptr;')
replace('submit.pWaitSemaphores=i?&timeline:nullptr;','submit.pWaitSemaphores=i?&timeline[i-1]:nullptr;')
replace('submit.pSignalSemaphores=&timeline;','submit.pSignalSemaphores=&timeline[i];')
replace('wi.pSemaphores=&timeline;','wi.pSemaphores=&timeline[2];')
replace('vkGetSemaphoreCounterValue(device,timeline,&actual)','vkGetSemaphoreCounterValue(device,timeline[2],&actual)')
replace('vkDestroySemaphore(device,timeline,nullptr);','for(unsigned i=0;i<3;++i)vkDestroySemaphore(device,timeline[i],nullptr);')
if a.reverse:replace('for(unsigned i=0;i<3;++i){CHECK(vkResetCommandPool(device,pools[i],0));','for(unsigned j=0;j<3;++j){unsigned i=2-j;CHECK(vkResetCommandPool(device,pools[i],0));')
source=out/'queue_wait_order.cpp';source.write_text(s)
app=out/'QueueProbeRunner.app';macos=app/'Contents'/'MacOS';macos.mkdir(parents=True)
frameworks=app/'Contents'/'Frameworks';frameworks.mkdir()
# Keep the executable and candidate dylib inside the signed app bundle. Launch
# Services starts these probes through launchd; executing a second binary back
# in Documents can stall in dyld's initial open/provenance path before main().
binary=macos/'queue_wait_order'
subprocess.run(['clang++','-std=c++17','-O2','-I',str(r/'src'),'-I',str(r/'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'),str(source),'/usr/local/lib/libvulkan.dylib','-o',str(binary)],check=True)
bundled_lib=frameworks/'libCandidate.dylib';shutil.copy2(lib,bundled_lib)
runner=macos/'run-probe'
with (app/'Contents'/'Info.plist').open('wb') as f:plistlib.dump({'CFBundleExecutable':'run-probe','CFBundleIdentifier':'local.openstack.queue-probe.'+a.label,'CFBundleName':'QueueProbeRunner','CFBundlePackageType':'APPL','CFBundleVersion':'1','NSSupportsAutomaticGraphicsSwitching':False},f)
icd=app/'Contents'/'Resources'/'icd.json';icd.parent.mkdir();icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(bundled_lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_'))};env.update(VK_ICD_FILENAMES=str(icd),MTL_DEBUG_LAYER='1',MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES='1',MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS='0',MVK_AMD_CPU_GATE_UNSIGNALED_TIMELINE_WAITS='1',MVK_CONFIG_USE_MTLHEAP='2',MVK_AMD_QUEUE_FAILURE_CONTEXT='1',MVK_AMD_RUNTIME_TRACE='1',MVK_CONFIG_SHADER_DUMP_DIR=str(out/'msl'))
exports='\n'.join('export '+k+'='+shlex.quote(str(v)) for k,v in env.items() if k.startswith(('VK_','MVK_','MTL_','DYLD_')))
runner.write_text('#!/bin/zsh\n'+exports+'\nexec '+shlex.quote(str(binary))+' "$@"\n');runner.chmod(0o755)
subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
start=time.monotonic()
with (out/'stdout.log').open('w') as so,(out/'stderr.log').open('w') as se:result=subprocess.run(['/usr/bin/open','-n',str(app),'--args',str(out/'output.json')],stdout=so,stderr=se,timeout=10)
deadline=time.monotonic()+90
output=None
# The probe creates its output file before the final JSON write. Wait for a
# complete object instead of racing the short empty-file interval.
while time.monotonic()<deadline:
 try:
  if (out/'output.json').stat().st_size:
   output=json.loads((out/'output.json').read_text())
   break
 except (FileNotFoundError,json.JSONDecodeError):
  pass
 time.sleep(.1)
if output is None:raise subprocess.TimeoutExpired(str(app),90)
record={'nativeSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'reverseSubmissionOrder':a.reverse,'independentTimelineEvents':3,'allSignalsActuallySubmitted':True,'metalValidation':True,'exitCode':result.returncode,'elapsedSeconds':time.monotonic()-start,'output':output,'passed':result.returncode==0 and output.get('passed',False),'gameFailureReproduced':False,'gameStarted':False};record['controlFailed']=not record['passed'];(out/'run.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record));raise SystemExit(0 if record['passed'] else 1)
