#version 450
layout(triangles)in;layout(triangle_strip,max_vertices=3)out;layout(location=2)in vec4 inputColor[];layout(location=2)out vec4 color;void main(){for(int j=0;j<3;j++){gl_Position=gl_in[j].gl_Position;gl_Layer=0;color=inputColor[j]+vec4(7.0/64.0,0,0,0);EmitVertex();}EndPrimitive();}
