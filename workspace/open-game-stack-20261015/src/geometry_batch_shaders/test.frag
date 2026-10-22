#version 450
layout(location=0) flat in uvec4 result;
layout(location=0) out uvec4 color;
void main(){color=result;}
