#version 450
layout(location=0) flat in uint tag;
layout(location=0) out vec4 color;
layout(set=0,binding=2,std430) readonly buffer FragmentRead {uint v[];} source;
layout(set=0,binding=3,std430) buffer FragmentWrite {uint v[];} witness;
layout(push_constant) uniform Config {int readIndex;int writeBase;} config;
void main(){
 uint pixel=uint(gl_FragCoord.y)*8u+uint(gl_FragCoord.x);
 witness.v[config.writeBase+int(pixel)]=200u+pixel;
 color=vec4(float(tag),float(source.v[config.readIndex]),float(pixel+1u),255.0)/255.0;
}
