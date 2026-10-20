#!/usr/bin/env python3
"""Independent unmodified source-build and opt-out controls; no games."""
import argparse,json,os,pathlib,subprocess
ROOT=pathlib.Path(__file__).resolve().parent;OLD=ROOT.parent/'robustness2-amd-20261014'
p=argparse.ArgumentParser();p.add_argument('--run',action='store_true');args=p.parse_args()
if not args.run:p.error('--run is required')
dest=ROOT/'evidence/baseline-controls';dest.mkdir(exist_ok=False);rows=[]
for name,library in [('unmodified-source',ROOT/'baseline/libMoltenVK.dylib'),('patched-opt-out',ROOT/'build/MoltenVK/libMoltenVK.1.4.2.dylib')]:
    icd=dest/(name+'-icd.json');icd.write_text(json.dumps({'file_format_version':'1.0.0','ICD':{'library_path':str(library),'api_version':'1.4.0','is_portability_driver':True}}))
    env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','VK_','MVK_','MTL_DEBUG_','GPU_ADAPTER_','R2_'))};env.update(VK_ICD_FILENAMES=str(icd),MVK_R2_RESEARCH='0',MVK_CONFIG_LOG_LEVEL='2',MTL_DEBUG_LAYER='1')
    output=dest/(name+'.json');r=subprocess.run([str(OLD/'build/gpu_probe'),str(OLD/'build/memory-original.spv'),str(OLD/'build/memory-robust.spv'),str(output)],env=env,cwd=ROOT,capture_output=True,text=True,timeout=50)
    (dest/(name+'.stdout.log')).write_text(r.stdout);(dest/(name+'.stderr.log')).write_text(r.stderr)
    rows.append({'case':name,'exitCode':r.returncode,'result':json.loads(output.read_text()) if output.exists() else None});(dest/'summary.json').write_text(json.dumps(rows,indent=2)+'\n')
    print(name+': '+('PASS' if r.returncode==0 else 'FAIL'),flush=True)
    if r.returncode:raise SystemExit('Control failed; evidence preserved.')
