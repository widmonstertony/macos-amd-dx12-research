#!/usr/bin/env python3
"""Compare indirect texel-view and backing-buffer read/write declarations."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',required=True,type=Path)
a=p.parse_args();out=a.output.resolve();assert not out.exists() and out.is_relative_to(ROOT/'evidence')
out.mkdir();source=ROOT/'src/texel_parent_write_gpu.mm';exe=out/'control'
sha=hashlib.sha256(source.read_bytes()).hexdigest()
with (out/'build.log').open('w') as log:
    subprocess.run(['clang++','-std=c++17','-O2','-Wall','-Wextra','-Werror','-fno-objc-arc',
        '-framework','Foundation','-framework','Metal',str(source),'-o',str(exe)],stdout=log,stderr=subprocess.STDOUT,check=True)
variants=[('auto-distinct',False,False,False),('placement-distinct',True,False,False),
          ('auto-shared-cross',False,True,True),('placement-shared-cross',True,True,True)]
results=[]
for label,placed,shared,cross in variants:
    for parent in [False,True]:
        name=label+('-parent' if parent else '-view')
        env={k:v for k,v in os.environ.items() if not k.startswith(('DYLD_','MVK_','VK_','MTL_','TEXEL_FIXTURE_'))}
        env['MTL_DEBUG_LAYER']='1'
        for key,value in [('TEXEL_FIXTURE_PLACEMENT',placed),('TEXEL_FIXTURE_SHARED',shared),
                          ('TEXEL_FIXTURE_CROSSFORMAT',cross),('TEXEL_FIXTURE_PARENT_WRITE',parent)]:
            if value:env[key]='1'
        with (out/(name+'.stdout')).open('w') as so,(out/(name+'.stderr')).open('w') as se:
            subprocess.run([str(exe),str(out/(name+'.json'))],env=env,stdout=so,stderr=se,timeout=45,check=True)
        row=json.loads((out/(name+'.json')).read_text());assert row['passed'] and row['mismatches']==0
        row['label']=name;results.append(row)
assert sha==hashlib.sha256(source.read_bytes()).hexdigest()
report={'passed':True,'sourceSHA256':sha,'results':results,'GPUWordsChecked':sum(r['totalCheckedWords'] for r in results),
        'mismatches':0,'indirectWritableArgumentBuffers':True,'directSetTextureNotUsedForWrites':True,
        'parentReadAndWriteDeclarations':True,'gameOperated':False,'actualGamePerformanceProven':False}
(out/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='results'}))
