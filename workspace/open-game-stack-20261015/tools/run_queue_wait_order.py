#!/usr/bin/env python3
"""Real GPU separate-event wait order control; no missing signal is submitted."""
import argparse,pathlib,json,hashlib,subprocess,os,re,time
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
source=out/'queue_wait_order.cpp';source.write_text(s);binary=out/'queue_wait_order'
subprocess.run(['clang++','-std=c++17','-O2','-I',str(r/'src'),'-I',str(r/'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'),str(source),'/usr/local/lib/libvulkan.dylib','-o',str(binary)],check=True)
icd=out/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_'))};env.update(VK_ICD_FILENAMES=str(icd),MTL_DEBUG_LAYER='1',MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES='1',MVK_CONFIG_USE_MTLHEAP='2',MVK_AMD_QUEUE_FAILURE_CONTEXT='1',MVK_AMD_RUNTIME_TRACE='1',MVK_CONFIG_SHADER_DUMP_DIR=str(out/'msl'))
start=time.monotonic()
with (out/'stdout.log').open('w') as so,(out/'stderr.log').open('w') as se:result=subprocess.run([str(binary),str(out/'output.json')],env=env,stdout=so,stderr=se,timeout=50)
output=json.loads((out/'output.json').read_text());record={'nativeSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'reverseSubmissionOrder':a.reverse,'independentTimelineEvents':3,'allSignalsActuallySubmitted':True,'metalValidation':True,'exitCode':result.returncode,'elapsedSeconds':time.monotonic()-start,'output':output,'passed':result.returncode==0 and output.get('passed',False),'gameFailureReproduced':False,'gameStarted':False};record['controlFailed']=not record['passed'];(out/'run.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record));raise SystemExit(0 if record['passed'] else 1)
