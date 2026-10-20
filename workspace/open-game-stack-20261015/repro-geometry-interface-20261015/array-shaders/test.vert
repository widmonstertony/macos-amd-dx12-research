#version 450
layout(location=0)in vec2 position;layout(location=1)in vec2 values[2];layout(location=3)in mat2 transform;layout(location=2)out vec4 color;void main(){gl_Position=vec4(position,0,1);color=vec4(values[0].x+transform[0].x,values[0].y+transform[1].x,values[1].x+transform[0].y,values[1].y+transform[1].y);}
