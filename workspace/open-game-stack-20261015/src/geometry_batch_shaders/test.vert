#version 450
layout(location=0) flat out uvec2 info;
void main(){info=uvec2(gl_VertexIndex,gl_InstanceIndex);gl_Position=vec4(0,0,0,1);}
