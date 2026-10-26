#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(set=0,binding=0) uniform sampler sampleSampler;
layout(set=0,binding=1) uniform texture3D volumes[];
layout(set=0,binding=2) uniform samplerBuffer texels[];
layout(set=0,binding=3) uniform texture2D images[];
void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    vec4 twoD = textureLod(sampler2D(images[5], sampleSampler), vec2(0.5), 0.0);
    vec4 threeD = texelFetch(sampler3D(volumes[0], sampleSampler), ivec3(1, 1, 0), 0);
    vec4 bufferValue = texelFetch(texels[0], 5);
    bool expected = abs(twoD.r - (41.0 / 255.0)) < (1.5 / 255.0) &&
                    abs(threeD.g - (218.0 / 255.0)) < (0.5 / 255.0) &&
                    abs(bufferValue.b - (254.0 / 255.0)) < (0.5 / 255.0);
    gl_Position = expected ? vec4(p * 2.0 - 1.0, 0.0, 1.0) : vec4(5.0);
}
