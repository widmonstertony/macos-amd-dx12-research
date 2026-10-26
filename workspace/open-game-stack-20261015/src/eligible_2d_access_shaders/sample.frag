#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(set=0,binding=0) uniform sampler sampleSampler;
layout(set=0,binding=3) uniform texture2D images[];
layout(location=0) out vec4 color;
void main() {
    uint i = uint(gl_FragCoord.x);
    color = textureLod(sampler2D(images[nonuniformEXT(i)], sampleSampler), vec2(0.5), 0.0);
}
