#!/usr/bin/env python3
"""Qualify the real readonly texel-buffer helper, including precise writes."""
import argparse, hashlib, json, os, shlex, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--library',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();out=a.output.resolve();lib=a.library.resolve()
assert not out.exists() and out.is_relative_to(ROOT/'evidence')
assert lib.is_relative_to(ROOT/'build') and lib.is_file()
out.mkdir();(out/'msl').mkdir();(out/'forensics.arm').touch()
sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
librarySHA=sha(lib);source=ROOT/'src/texel_heap_helper_gpu.mm';sourceSHA=sha(source)
flags={l.split(' = ',1)[0]:l.split(' = ',1)[1] for l in
       (ROOT/'build/moltenvk-bounded-archive/MoltenVK/CMakeFiles/MoltenVK.dir/flags.make').read_text().splitlines() if ' = ' in l}
exe=out/'probe'
cmd=['clang++','-std=c++17','-O2','-DNDEBUG','-DMVK_USE_METAL_PRIVATE_API=0',
     '-DMVK_EXCLUDE_SPIRV_TOOLS=1','-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross',
     '-Wl,-headerpad_max_install_names',*shlex.split(flags['OBJCXX_INCLUDES']),source,lib,
     '-framework','Foundation','-framework','Metal','-framework','QuartzCore','-o',exe]
with (out/'build.log').open('w') as log:
    subprocess.run([str(x) for x in cmd],stdout=log,stderr=subprocess.STDOUT,check=True)
ident=subprocess.check_output(['otool','-D',str(lib)],text=True).splitlines()[1].strip()
subprocess.run(['install_name_tool','-change',ident,str(lib),str(exe)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(exe)],check=True)
results=[]
for allWrite in [False,True]:
    for order in ['fetch-first','sample-first']:
        label=('write-table-' if allWrite else 'read-table-')+order
        env={k:v for k,v in os.environ.items() if not k.startswith(('MVK_','MTL_','VK_','DYLD_','TEXEL_FIXTURE_'))}
        env.update(MTL_DEBUG_LAYER='1',MVK_AMD_SHARED_LIVE_SNAPSHOTS='1',MVK_AMD_ENCODER_HEAP_PLANS='1',
                   MVK_CONFIG_SHADER_DUMP_DIR=str(out/'msl'),MVK_AMD_FORENSICS_ARM_PATH=str(out/'forensics.arm'))
        if allWrite:env['TEXEL_FIXTURE_ALL_WRITE_TABLE']='1'
        with (out/(label+'.stdout')).open('w') as so,(out/(label+'.stderr')).open('w') as se:
            subprocess.run([str(exe),str(out/(label+'.json')),order],env=env,stdout=so,stderr=se,timeout=30,check=True)
        row=json.loads((out/(label+'.json')).read_text());assert row['passed'] and row['mismatches']==0
        row.update(allWriteTable=allWrite,label=label);results.append(row)
assert librarySHA==sha(lib) and sourceSHA==sha(source)
report={'passed':True,'candidateSHA256':librarySHA,'sourceSHA256':sourceSHA,
        'results':results,'totalGPUValues':sum(r['pixelsOrWordsChecked'] for r in results),
        'sharedBackingBuffer':True,'readWriteTablesRemainPrecise':True,'writesBeforeAndAfterHeapRead':True,
        'GPUOutputMismatches':0,'gameOperated':False,'actualGamePerformanceClaimed':False}
(out/'qualification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'passed':True,'totalGPUValues':report['totalGPUValues'],'actualHelperTested':True}))
