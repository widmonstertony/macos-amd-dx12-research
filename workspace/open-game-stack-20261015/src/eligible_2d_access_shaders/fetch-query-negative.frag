#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(set=0,binding=0) uniform sampler sampleSampler;
layout(set=0,binding=1) uniform texture3D volumes[];
layout(set=0,binding=2) uniform samplerBuffer texels[];
layout(set=0,binding=3) uniform texture2D images[];
layout(location=0) out vec4 color;
void main() {
    uint i = uint(gl_FragCoord.x);
    ivec2 size = textureSize(sampler2D(images[nonuniformEXT(i)], sampleSampler), 0);
    vec4 twoD = texelFetch(sampler2D(images[nonuniformEXT(i)], sampleSampler), size - ivec2(4), 0);
    ivec3 coordinate = ivec3(i % 4u, (i / 4u) % 4u, i / 16u);
    vec4 threeD = texelFetch(sampler3D(volumes[0], sampleSampler), coordinate, 0);
    vec4 bufferValue = texelFetch(texels[0], int(i));
    color = all(equal(size, ivec2(4))) ? vec4(twoD.r, threeD.g, bufferValue.b, 1.0) : vec4(1, 0, 1, 1);
}
