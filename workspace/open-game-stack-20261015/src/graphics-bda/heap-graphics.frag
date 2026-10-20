#version 460
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 8) readonly buffer Item { uint value[]; } items[];
layout(location = 0) out vec4 outColor;
void main() {
    uint index = uint(gl_FragCoord.y) * 8u + uint(gl_FragCoord.x);
    uint packed = items[nonuniformEXT(index)].value[0];
    outColor = vec4(float(packed & 255u),
                    float((packed >> 8u) & 255u),
                    float((packed >> 16u) & 255u),
                    255.0) / 255.0;
}
