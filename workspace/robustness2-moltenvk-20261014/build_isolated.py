#!/usr/bin/env python3
"""Rebuild this isolated tree and native probes. Does not install or run tests."""
import pathlib,subprocess,sys
ROOT=pathlib.Path(__file__).resolve().parent
source=ROOT/'vendor/MoltenVK-db66022459ffb663aa2b50f6b018bc2e124f5edf'
if not source.is_dir():raise SystemExit('Pinned vendor source is missing; restore the recorded archive first.')
def run(command,log):
    log.write('$ '+' '.join(map(str,command))+'\n');log.flush()
    subprocess.run(list(map(str,command)),cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
with (ROOT/'evidence/rebuild.log').open('w') as log:
    run([sys.executable,ROOT/'patch_sources.py'],log)
    run(['cmake','-S',source,'-B',ROOT/'build','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_OSX_ARCHITECTURES=x86_64','-DMVK_EXCLUDE_SPIRV_TOOLS=ON','-DCPM_SOURCE_CACHE='+str(ROOT/'vendor/cache')],log)
    run(['cmake','--build',ROOT/'build','-j','4'],log)
    for name in ('integrated_probe','integrated_array_probe','range_probe','reject_probe'):
        run(['/usr/bin/clang++','-std=c++17','-O2','-Wall','-Wextra','-Wno-missing-field-initializers','-I/usr/local/include',ROOT/f'src/{name}.cpp','-L/usr/local/lib','-lvulkan','-Wl,-rpath,/usr/local/lib','-o',ROOT/f'build/{name}'],log)
    run(['/usr/local/bin/glslc','-O0','--target-env=vulkan1.2',ROOT/'src/ranges.comp','-o',ROOT/'build/ranges.spv'],log)
    run(['/usr/local/bin/glslc','-O0','--target-env=vulkan1.2','-DRUNTIME_DESCRIPTORS=1',ROOT/'src/variable-array.comp','-o',ROOT/'build/variable-array.spv'],log)
print('Isolated rebuild completed; no GPU execution or installation performed.')
