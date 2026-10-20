#version 450
layout(triangles) in;layout(triangle_strip,max_vertices=3) out;layout(location=2) out vec4 color; void main(){for(int j=0;j<3;j++){gl_Position=gl_in[j].gl_Position;gl_Layer=0;color=vec4(32.0/255.0,64.0/255.0,192.0/255.0,1);EmitVertex();}EndPrimitive();}
