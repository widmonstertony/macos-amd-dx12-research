from pathlib import Path
import subprocess,json
r=Path(__file__).resolve().parent;(r/'shaders').mkdir(exist_ok=True)
steps=64
for variant in range(12):
 s='''#version 450
layout(local_size_x=64) in;
layout(set=0,binding=0,std430) readonly buffer Input {uvec2 data[];} src;
layout(set=0,binding=1,std430) buffer Output {uint data[];} dst;
void main(){uint t=gl_GlobalInvocationID.x;
'''+f'uint h={0x9e3779b9^variant}u;\n'
 for k in range(steps):
  s+=f'uvec2 v{k}=src.data[(t+{17*k}u)&255u]; h=((h^v{k}.x)*1664525u+v{k}.y+1013904223u); h=(h<<7u)|(h>>25u);\n'
 s+='dst.data[t]=h;}\n'
 path=r/'shaders'/f'case{variant}.comp';path.write_text(s)
 subprocess.run(['/usr/local/bin/glslangValidator','-V',str(path),'-o',str(path.with_suffix('.spv'))],check=True,capture_output=True)
s='''#version 450
layout(local_size_x=64) in;
layout(constant_id=0) const uint variant=7;
layout(set=0,binding=0,std430) readonly buffer Input {uvec2 data[];} src;
layout(set=0,binding=1,std430) buffer Output {uint data[];} dst;
void main(){uint t=gl_GlobalInvocationID.x; dst.data[t]=(src.data[t].x ^ src.data[t].y) + variant;}
'''
f=r/'shaders/specialize.comp';f.write_text(s);subprocess.run(['/usr/local/bin/glslangValidator','-V',str(f),'-o',str(f.with_suffix('.spv'))],check=True,capture_output=True)
(r/'generation.json').write_text(json.dumps({'cases':12,'vectorReadsPerInvocation':steps,'workgroupSize':64,'seedDifferentPerCase':True,'scope':'Owned functional stress, not captured game shader execution'},indent=2)+'\n')
s=Path('robustness2-reference-20261015/src/gpu_common.hpp').read_text();s=s.replace('"VK_EXT_descriptor_indexing"};','"VK_EXT_descriptor_indexing","VK_EXT_pipeline_creation_feedback"};').replace('di.enabledExtensionCount=2;di.ppEnabledExtensionNames=dext','di.enabledExtensionCount=3;di.ppEnabledExtensionNames=dext');(r/'gpu_common.hpp').write_text(s)
