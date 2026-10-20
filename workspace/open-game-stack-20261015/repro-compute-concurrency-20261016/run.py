import pathlib,os,subprocess,json,datetime,hashlib,sys
r=pathlib.Path(__file__).resolve().parent;p=r.parent;out=p/'evidence'/('compute-concurrency-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'));out.mkdir();(out/'msl').mkdir()
variant=sys.argv[1] if len(sys.argv)>1 else 'moltenvk-guarded-vector'
assert variant in ('moltenvk-guarded-vector','moltenvk-specializer-lifetime','moltenvk-binary-archive-compute-render')
lib=p/'build'/variant/'MoltenVK/libMoltenVK.1.4.2.dylib';icd=out/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(lib),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_','GPU_ADAPTER_','R2_'))}
env.update(PATH='/nonexistent',VK_ICD_FILENAMES=str(icd),MTL_DEBUG_LAYER='1',MVK_CONFIG_LOG_LEVEL='2',MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_AMD_REFERENCE_RBA2='1',MVK_AMD_REFERENCE_RIA2='1',MVK_AMD_REFERENCE_NULL='1',MVK_AMD_BYTE_GUARDS='1',MVK_AMD_COHERENT_ATOMICS='1',MVK_AMD_SERIALIZE_PIPELINE_LINK='1',MVK_AMD_RUNTIME_TRACE='1',MVK_AMD_TRACE_SLOW_COMPUTE='1',MVK_AMD_SLOW_COMPUTE_MS='0',MVK_CONFIG_SHADER_DUMP_DIR=str(out/'msl'))
cmd=[str(r/'concurrency_gpu'),str(r/'shaders'),str(out/'output.json')]
record={'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'library':str(lib),'sha256':hashlib.sha256(lib.read_bytes()).hexdigest(),'command':cmd,'maxWorkers':2,'originalGameTouched':False,'gameRestarted':False,'scope':'Own workload, controls worker count and cache sharing independently; not game throughput'}
with (out/'stdout.log').open('w') as stdout,(out/'stderr.log').open('w') as stderr:
 try:q=subprocess.run(cmd,env=env,stdout=stdout,stderr=stderr,timeout=100);record['exitCode']=q.returncode
 except subprocess.TimeoutExpired:record['timeout']=True
if (out/'output.json').exists():record['results']=json.loads((out/'output.json').read_text())
record['passed']=record.get('exitCode')==0 and record.get('results',{}).get('passed',False)
(out/'run.json').write_text(json.dumps(record,indent=2)+'\n');(r/'latest-run.json').write_text(json.dumps({'evidence':str(out),'passed':record['passed']},indent=2)+'\n');print(json.dumps(record,indent=2));raise SystemExit(0 if record['passed'] else 1)
