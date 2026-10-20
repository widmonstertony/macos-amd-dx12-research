#version 450
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
layout(location=0) in vec2 position;
layout(location=0) flat out uint tag;
layout(set=0,binding=0,std430) readonly buffer VertexRead {uint v[];} source;
layout(set=0,binding=1,std430) buffer VertexWrite {uint v[];} witness;
layout(buffer_reference,std430,buffer_reference_align=4) readonly buffer Physical { uint v[]; };
layout(push_constant) uniform Config {int readIndex;int writeBase;uint64_t vertexAddress;uint64_t fragmentAddress;} config;
void main(){
 gl_Position=vec4(position,0,1);
 tag=source.v[config.readIndex];
 witness.v[config.writeBase+gl_VertexIndex]=100u+uint(gl_VertexIndex)+Physical(config.vertexAddress).v[0];
}
