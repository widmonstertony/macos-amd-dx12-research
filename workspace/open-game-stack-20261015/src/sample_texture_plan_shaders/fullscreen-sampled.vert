#version 450
layout(set=0,binding=0) uniform sampler sampleSampler;
layout(set=0,binding=1) uniform texture2D images[128];
void main() {
    vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    vec4 sampleValue = textureLod(sampler2D(images[5], sampleSampler), vec2(0.5), 0.0);
    bool expected = sampleValue.r > 0.15 && sampleValue.r < 0.18 &&
                    sampleValue.g > 0.22 && sampleValue.g < 0.26 && sampleValue.a == 1.0;
    gl_Position = expected ? vec4(p * 2.0 - 1.0, 0.0, 1.0) : vec4(5.0);
}
