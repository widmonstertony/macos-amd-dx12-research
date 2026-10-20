#version 450
layout(location=0) in vec2 position;
layout(location=0) flat out uint tag;
layout(set=0,binding=0,std430) readonly buffer VertexRead {uint v[];} source;
layout(set=0,binding=1,std430) buffer VertexWrite {uint v[];} witness;
layout(push_constant) uniform Config {int readIndex;int writeBase;} config;
void main(){
 gl_Position=vec4(position,0,1);
 tag=source.v[config.readIndex];
 witness.v[config.writeBase+gl_VertexIndex]=100u+uint(gl_VertexIndex);
}
