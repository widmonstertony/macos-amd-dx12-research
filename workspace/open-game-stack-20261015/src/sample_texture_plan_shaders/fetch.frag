#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(set=0,binding=0) uniform sampler sampleSampler;
layout(set=0,binding=1) uniform texture2D images[128];
layout(location=0) out vec4 color;
void main() {
    uint i = uint(gl_FragCoord.x);
    color = texelFetch(sampler2D(images[nonuniformEXT(i)], sampleSampler), ivec2(0), 0);
}
