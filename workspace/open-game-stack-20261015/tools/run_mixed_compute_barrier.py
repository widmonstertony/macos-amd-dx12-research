#!/usr/bin/env python3
"""Bounded real AMD GPU control for helper binding loss (upstream #2822)."""
import argparse,hashlib,json,os,pathlib,re,subprocess,time
r=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=pathlib.Path,required=True);p.add_argument('--label',required=True);p.add_argument('--rounds',type=int,default=64);p.add_argument('--work-trace',action='store_true');p.add_argument('--failure-context',action='store_true');p.add_argument('--rebind-after-helper',action='store_true');p.add_argument('--argument-buffers',type=int,choices=[0,1],default=1);a=p.parse_args()
lib=a.library.resolve()
assert lib.is_relative_to(r/'build') and lib.is_file()
assert re.fullmatch('[a-z0-9-]{1,64}',a.label) and 1<=a.rounds<=128
out=r/'evidence'/a.label;out.mkdir(exist_ok=False);(out/'msl').mkdir()
binary=r/'build/probes/mixed_compute_barrier';shader=r/'build/probes/mixed_compute_barrier.spv'
subprocess.run(['/usr/local/bin/glslangValidator','-V',str(r/'src/mixed_compute_barrier.comp'),'-o',str(shader)],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['clang++','-std=c++17','-O2','-I',str(r/'src'),'-I',str(r/'native-vendor/Vulkan-Headers-6aefb8eb95c8e170d0805fd0f2d02832ec1e099a/include'),str(r/'src/mixed_compute_barrier_probe.cpp'),'/usr/local/lib/libvulkan.dylib','-o',str(binary)],check=True)
icd=out/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items()if not k.startswith(('DYLD_','VK_','MVK_','MTL_'))}
env.update(VK_ICD_FILENAMES=str(icd),MTL_DEBUG_LAYER='1',MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=str(a.argument_buffers),MVK_CONFIG_USE_MTLHEAP='2',MVK_CONFIG_SHADER_DUMP_DIR=str(out/'msl'),MVK_AMD_RUNTIME_TRACE='1',MVK_AMD_GPU_TIMEOUT_TRACE=str(int(a.work_trace)),MVK_AMD_QUEUE_FAILURE_CONTEXT=str(int(a.failure_context)),MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL='1',MVK_AMD_REFERENCE_RBA2='1',MVK_AMD_REFERENCE_RIA2='1',MVK_AMD_REFERENCE_NULL='1',MVK_AMD_BYTE_GUARDS='1')
if a.rebind_after_helper:env['GPU_REBIND_AFTER_HELPER']='1'
t=time.monotonic()
with(out/'stdout.log').open('w')as stdout,(out/'stderr.log').open('w')as stderr:
 result=subprocess.run([str(binary),str(shader),str(out/'output.json'),str(a.rounds)],env=env,stdout=stdout,stderr=stderr,timeout=45)
record={'librarySHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'exitCode':result.returncode,'elapsedSeconds':time.monotonic()-t,'workTrace':a.work_trace,'failureContext':a.failure_context,'argumentBuffers':a.argument_buffers,'rebindAfterHelper':a.rebind_after_helper,'gameStarted':False,'passed':result.returncode==0,'output':json.loads((out/'output.json').read_text())}
(out/'run.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record));raise SystemExit(result.returncode)
