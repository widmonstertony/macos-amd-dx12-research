#!/usr/bin/env python3
"""Build orchestration only; never executes a GPU workload or installs a library."""
import pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parent
def run(args,log):
    log.write('$ '+' '.join(map(str,args))+'\n');log.flush()
    subprocess.run(list(map(str,args)),cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
with (ROOT/'evidence/rebuild.log').open('w') as log:
    run([sys.executable,ROOT/'patch_native.py'],log)
    run(['cmake','-S',ROOT/'vendor/MoltenVK-db66022459ffb663aa2b50f6b018bc2e124f5edf','-B',ROOT/'build/driver','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_ARCHITECTURES=x86_64','-DMVK_EXCLUDE_SPIRV_TOOLS=ON','-DCPM_SOURCE_CACHE='+str(ROOT/'vendor/cache')],log)
    run(['cmake','--build',ROOT/'build/driver','-j','4'],log)
    run(['/usr/bin/clang++','-std=c++17','-O2','-Wall','-Wextra','-I/usr/local/include',ROOT/'src/R2Native.cpp',ROOT/'src/native_cli.cpp','-L/usr/local/lib','-lSPIRV-Tools-shared','-Wl,-rpath,/usr/local/lib','-o',ROOT/'build/native_cli'],log)
    for shader in ['bda.comp','guard.vert','guard.frag']:
        run(['/usr/local/bin/glslc','-O0','--target-env=vulkan1.2',ROOT/'src'/shader,'-o',ROOT/'build'/(shader+'.spv')],log)
    for name in ['bda_probe','graphics_probe']:
        run(['/usr/bin/clang++','-std=c++17','-O2','-Wall','-Wextra','-Wno-missing-field-initializers','-I/usr/local/include',ROOT/'src'/(name+'.cpp'),'-L/usr/local/lib','-lvulkan','-Wl,-rpath,/usr/local/lib','-o',ROOT/'build'/name],log)
print('Native isolated build finished. No GPU workload or installation performed.')
