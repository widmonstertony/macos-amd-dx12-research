#!/usr/bin/env python3
"""Owned rendered-image Metal control; preserve GPU timing regressions."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--output',required=True,type=Path)
a=p.parse_args();out=a.output.resolve()
assert out.is_relative_to(ROOT/'evidence') and not out.exists()
out.mkdir();source=ROOT/'src/render_view_heap_gpu.mm';exe=out/'control'
source_sha=hashlib.sha256(source.read_bytes()).hexdigest()
with (out/'build.log').open('w') as log:
    subprocess.run(['clang++','-std=c++17','-O2','-Wall','-Wextra','-Werror',
        '-fno-objc-arc','-framework','Foundation','-framework','Metal',str(source),'-o',str(exe)],
        stdout=log,stderr=subprocess.STDOUT,check=True)
results=[]
for placed in [False,True]:
    for views in [False,True]:
        for extras in [False,True]:
            label=('placement' if placed else 'auto')+('-views' if views else '-roots')+('-extra' if extras else '-only')
            env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','MVK_','VK_','MTL_','IMAGE_HEAP_'))}
            env['MTL_DEBUG_LAYER']='1'
            for key,enabled in [('IMAGE_HEAP_PLACEMENT',placed),('IMAGE_HEAP_VIEWS',views),('IMAGE_HEAP_EXTRAS',extras)]:
                if enabled:env[key]='1'
            with (out/(label+'.stdout')).open('w') as so,(out/(label+'.stderr')).open('w') as se:
                subprocess.run([str(exe),str(out/(label+'.json'))],env=env,stdout=so,stderr=se,timeout=45,check=True)
            row=json.loads((out/(label+'.json')).read_text());assert row['passed'] and row['mismatches']==0
            row['label']=label;results.append(row)
assert source_sha==hashlib.sha256(source.read_bytes()).hexdigest()
report={'passed':True,'sourceSHA256':source_sha,'results':results,
    'GPUWordsChecked':sum(r['GPUWordsChecked'] for r in results),'mismatches':0,
    'metalDebugLayerEnabled':True,'APIAndGPUTimingNotGameBenchmark':True,
    'performanceRegressionsRetained':[r['label'] for r in results if r['heapGPUIntervalMedianNS']>1.5*r['preciseGPUIntervalMedianNS']],
    'allHeapDeclarationsRecommended':False,'gameOperated':False,'gameFPSClaimed':False}
(out/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='results'}))
