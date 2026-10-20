#version 450
layout(constant_id=7) const float SCALE=0.25;
layout(location=2) in vec4 color;layout(location=0)out vec4 outputColor;void main(){outputColor=vec4(color.rgb*SCALE,1);}
