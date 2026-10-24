#!/usr/bin/env python3
"""Build the exact liveness crossover control against an owned candidate."""
import argparse,hashlib,json,pathlib,shlex,subprocess
r=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=pathlib.Path,required=True);a=p.parse_args()
lib=a.library.resolve();assert lib.is_file() and lib.is_relative_to(r/'build')
flags=(r/'build/moltenvk-bounded-archive/MoltenVK/CMakeFiles/MoltenVK.dir/flags.make').read_text()
d={line.split(' = ',1)[0]:line.split(' = ',1)[1] for line in flags.splitlines() if ' = ' in line}
out=r/'build/probes/live_snapshot_crossover_control'
cmd=['clang++','-Wl,-headerpad_max_install_names','-std=c++17','-O2','-DNDEBUG','-DMVK_USE_METAL_PRIVATE_API=0','-DMVK_EXCLUDE_SPIRV_TOOLS=1','-DSPIRV_CROSS_NAMESPACE_OVERRIDE=MVK_spirv_cross']+shlex.split(d['OBJCXX_INCLUDES'])+[str(r/'src/live_snapshot_crossover_control.mm'),str(lib),'-framework','Foundation','-framework','Metal','-framework','QuartzCore','-o',str(out)]
subprocess.run(cmd,check=True)
subprocess.run(['install_name_tool','-change','@rpath/libMoltenVK.1.dylib',str(lib),str(out)],check=True)
out.with_suffix('.build.json').write_text(json.dumps({'candidate':str(lib),'candidateSHA256':hashlib.sha256(lib.read_bytes()).hexdigest(),'command':cmd},indent=2)+'\n')
print(out)
