#!/usr/bin/env python3
"""Run isolated native tests only. No Wine, games, installation or vendor writes."""
import argparse,datetime,hashlib,json,os,pathlib,re,subprocess
ROOT=pathlib.Path(__file__).resolve().parent
OLD=ROOT.parent/'robustness2-amd-20261014'
p=argparse.ArgumentParser();p.add_argument('--run',action='store_true');p.add_argument('--label',required=True);p.add_argument('--copy',action='store_true');args=p.parse_args()
if not args.run:p.error('--run is required; nothing started')
if not re.fullmatch('[A-Za-z0-9_-]{1,64}',args.label):p.error('Invalid label')
dest=ROOT/'evidence'/args.label;dest.mkdir(exist_ok=False)
library=(ROOT/'build/MoltenVK/libMoltenVK.1.4.2.dylib').resolve()
icd=dest/'MoltenVK_icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(library),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_DEBUG_','GPU_ADAPTER_','R2_'))}
env.update(VK_ICD_FILENAMES=str(icd),MVK_R2_LIBRARY=str(library),MVK_R2_RESEARCH='1',MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_CONFIG_LOG_LEVEL='2',MTL_DEBUG_LAYER='1',MVK_CONFIG_SHADER_DUMP_DIR=str(ROOT/'runtime/msl-dumps'))
if args.copy:env['R2_COPY_DESCRIPTORS']='1'
cases=[('memory-v13',[ROOT/'build/integrated_probe',OLD/'build/memory-original.spv',OLD/'build/memory-original.spv']),('memory-v15',[ROOT/'build/integrated_probe',OLD/'build/memory-v15-original.spv',OLD/'build/memory-v15-original.spv']),('array-fixed',[ROOT/'build/integrated_array_probe',OLD/'build/array-fixed-original.spv']),('array-runtime',[ROOT/'build/integrated_array_probe',OLD/'build/array-runtime-original.spv'])]
if (ROOT/'build/range_probe').exists():cases.append(('ranges-dynamic-uniform',[ROOT/'build/range_probe',ROOT/'build/ranges.spv']))
for allocated in (1,2,3):cases.append((f'variable-allocated-{allocated}',[ROOT/'build/integrated_array_probe',ROOT/'build/variable-array.spv']))
cases.append(('unsupported-refused',[ROOT/'build/reject_probe',OLD/'build/matrix-layout.spv',OLD/'build/physical-pointer.spv']))
results=[]
for name,command in cases:
    output=dest/(name+'.json')
    started=datetime.datetime.now(datetime.timezone.utc).isoformat()
    case_env=env.copy()
    if name.startswith('variable-allocated-'):case_env['R2_VARIABLE_COUNT']=name.rsplit('-',1)[1]
    r=subprocess.run(list(map(str,command))+[str(output)],cwd=ROOT,env=case_env,text=True,capture_output=True,timeout=50)
    (dest/(name+'.stdout.log')).write_text(r.stdout);(dest/(name+'.stderr.log')).write_text(r.stderr)
    row={'case':name,'startedUTC':started,'exitCode':r.returncode,'command':list(map(str,command)),'librarySha256':hashlib.sha256(library.read_bytes()).hexdigest(),'copyDescriptors':args.copy}
    if output.exists():row['results']=json.loads(output.read_text())
    row['metalValidationEnabled']='Metal API Validation Enabled' in r.stderr
    row['driverWitness']=re.findall(r'DRIVER_WITNESS[^\n]*',r.stdout)
    results.append(row);(dest/'suite.json').write_text(json.dumps(results,indent=2)+'\n')
    print(name+': '+('PASS' if r.returncode==0 else 'FAIL'),flush=True)
    if r.returncode or not row.get('results',{}).get('passed'):raise SystemExit('Stopped. Raw failure preserved in '+str(dest))
print('Isolated driver suites passed. No features advertised or game launched.')
