#!/usr/bin/env python3
"""Semantic boundary checks: valid unsupported modules must be refused."""
import hashlib,json,pathlib,subprocess,sys
from r2_lower import Lower
ROOT=pathlib.Path(__file__).resolve().parent.parent
BUILD=ROOT/'build';EVIDENCE=ROOT/'evidence'
def run(args):
    p=subprocess.run(args,capture_output=True,text=True)
    if p.returncode:raise RuntimeError(' '.join(map(str,args))+'\n'+p.stdout+p.stderr)
    return p.stdout
def dis(path):return run(['/usr/local/bin/spirv-dis','--raw-id',str(path)])
reports=[]
def reject(name,source,binding=31,counts=None):
    try:Lower(source,binding,counts).lower()
    except (ValueError,KeyError) as e:reports.append({'case':name,'rejected':True,'reason':str(e)});return
    raise AssertionError('Unsupported module was accepted: '+name)
memory=dis(BUILD/'memory-original.spv')
reject('metadata-binding-collision',memory,0)
reject('runtime-descriptor-array-missing-count',dis(BUILD/'array-runtime-original.spv'))
reject('runtime-descriptor-array-zero-count',dis(BUILD/'array-runtime-original.spv'),counts={'0:0':0})
reject('runtime-descriptor-array-excess-count',dis(BUILD/'array-runtime-original.spv'),counts={'0:0':1000001})
fixtures={
 'physical-pointer':('comp','''#version 450
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
layout(buffer_reference,std430) buffer P {uint value;};
layout(push_constant) uniform Config {P pointer;} config;
layout(local_size_x=1) in;
void main(){config.pointer.value=42;}
'''),
 'matrix-layout':('comp','''#version 450
layout(set=0,binding=0,std430) buffer B {mat4 m;} b;
layout(local_size_x=1) in;
void main(){b.m[1][2]=b.m[2][1];}
'''),
 'implicit-derivative-sampling':('frag','''#version 450
layout(set=0,binding=0) uniform texture2D t;
layout(set=0,binding=1) uniform sampler s;
layout(location=0) in vec2 uv;
layout(location=0) out vec4 color;
void main(){color=texture(sampler2D(t,s),uv);}
'''),
 'image-atomic':('comp','''#version 450
layout(set=0,binding=0,r32ui) uniform uimage2D t;
layout(local_size_x=1) in;
void main(){imageAtomicAdd(t,ivec2(0),1);}
'''),
 '3d-image':('comp','''#version 450
layout(set=0,binding=0,r32ui) uniform uimage3D t;
layout(set=0,binding=1,std430) buffer B {uvec4 value;} b;
layout(local_size_x=1) in;
void main(){b.value=imageLoad(t,ivec3(0));}
'''),
}
for name,(stage,src) in fixtures.items():
    p=BUILD/(name+'.'+stage);p.write_text(src);out=BUILD/(name+'.spv')
    run(['/usr/local/bin/glslc','-O0','--target-env=vulkan1.1',str(p),'-o',str(out)])
    run(['/usr/local/bin/spirv-val','--target-env','vulkan1.1',str(out)])
    reject(name,dis(out))
# Validate preservation of modern SPIR-V entry-point interface rules.
p=BUILD/'memory-v15-original.spv';out=BUILD/'memory-v15-robust.spv'
run(['/usr/local/bin/glslc','-O0','--target-env=vulkan1.2',str(ROOT/'shaders/memory.comp'),'-o',str(p)])
run([sys.executable,str(ROOT/'src/r2_lower.py'),str(p),str(out)])
reports.append({'case':'SPIRV1.5-metadata-entry-interface','rejected':False,'validated':True})
(EVIDENCE/'compiler-boundary-checks.json').write_text(json.dumps({'passed':True,'cases':reports},indent=2)+'\n')
print(json.dumps({'passed':True,'checks':len(reports),'refusals':sum(x.get('rejected',False) for x in reports)}))
