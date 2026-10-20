#!/usr/bin/env python3
"""Orchestration only; all shader lowering runs in C++ inside MoltenVK."""
import argparse,json,hashlib,os,pathlib,re,subprocess,datetime
ROOT=pathlib.Path(__file__).resolve().parent;OLD=ROOT.parent/'robustness2-moltenvk-20261014';FIRST=ROOT.parent/'robustness2-amd-20261014'
p=argparse.ArgumentParser();p.add_argument('--run',action='store_true');p.add_argument('--label',required=True);p.add_argument('--regression',action='store_true');args=p.parse_args()
if not args.run:p.error('--run required; no workload started')
if not re.fullmatch('[A-Za-z0-9_-]{1,64}',args.label):p.error('Invalid label')
dest=ROOT/'evidence'/args.label;dest.mkdir(exist_ok=False)
library=(ROOT/'build/driver/MoltenVK/libMoltenVK.1.4.2.dylib').resolve();icd=dest/'icd.json';icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(library),'api_version':'1.4.0','is_portability_driver':True}}))
env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_DEBUG_','GPU_ADAPTER_','R2_'))}
env.update(PATH='/nonexistent',VK_ICD_FILENAMES=str(icd),MVK_R2_LIBRARY=str(library),MVK_R2_RESEARCH='1',MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS='1',MVK_CONFIG_LOG_LEVEL='2',MTL_DEBUG_LAYER='1',MVK_CONFIG_SHADER_DUMP_DIR=str(ROOT/'runtime/msl'))
cases=[('bda',[ROOT/'build/bda_probe',ROOT/'build/bda.comp.spv'],{}),('graphics',[ROOT/'build/graphics_probe',ROOT/'build/guard.vert.spv',ROOT/'build/guard.frag.spv'],{})]
if args.regression:
    cases=[('memory-v13',[OLD/'build/integrated_probe',FIRST/'build/memory-original.spv',FIRST/'build/memory-original.spv'],{}),('memory-v15',[OLD/'build/integrated_probe',FIRST/'build/memory-v15-original.spv',FIRST/'build/memory-v15-original.spv'],{}),('array-fixed',[OLD/'build/integrated_array_probe',FIRST/'build/array-fixed-original.spv'],{}),('array-runtime',[OLD/'build/integrated_array_probe',FIRST/'build/array-runtime-original.spv'],{}),('ranges',[OLD/'build/range_probe',OLD/'build/ranges.spv'],{})]+[(f'variable-{n}',[OLD/'build/integrated_array_probe',OLD/'build/variable-array.spv'],{'R2_VARIABLE_COUNT':str(n)})for n in (1,2,3)]
rows=[]
for name,command,overrides in cases:
    output=dest/(name+'.json');caseEnv={**env,**overrides};start=datetime.datetime.now(datetime.timezone.utc).isoformat()
    r=subprocess.run([str(a)for a in command]+[str(output)],cwd=ROOT,env=caseEnv,capture_output=True,text=True,timeout=50)
    (dest/(name+'.stdout.log')).write_text(r.stdout);(dest/(name+'.stderr.log')).write_text(r.stderr)
    row={'case':name,'timeUTC':start,'command':[str(a)for a in command],'exitCode':r.returncode,'librarySha256':hashlib.sha256(library.read_bytes()).hexdigest(),'pathForGpuProcess':'/nonexistent','metalValidationEnabled':'Metal API Validation Enabled'in r.stderr}
    if output.exists():row['results']=json.loads(output.read_text())
    rows.append(row);(dest/'suite.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(name+': '+('PASS' if r.returncode==0 else 'FAIL'),flush=True)
    if r.returncode or not row.get('results',{}).get('passed'):raise SystemExit('Stopped; raw failure retained in '+str(dest))
print('Native GPU suite passed; no game or installed environment touched.')
