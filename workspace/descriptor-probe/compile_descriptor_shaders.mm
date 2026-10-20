#define main unused_graphics_shader_compiler
#include "../graphics-probe/compile_graphics_shaders.mm"
#undef main
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 3) return 64;
    void *library = dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if (!library) { fprintf(stderr,"DXC: %s\n",dlerror()); return 1; }
    auto create = reinterpret_cast<DxcCreateInstanceProc>(dlsym(library,"DxcCreateInstance"));
    IDxcCompiler3 *compiler = nullptr;
    if (!create || create(CLSID_DxcCompiler,__uuidof(IDxcCompiler3),reinterpret_cast<void **>(&compiler)) < 0 || !compiler) return 2;
    const char *source = R"HLSL(
Texture2D<float4> inputTexture : register(t0);
SamplerState pointSampler : register(s0);
cbuffer Tweak : register(b0) { uint4 tweak; };
float4 vsMain(uint id : SV_VertexID) : SV_Position {
  float2 positions[3] = {float2(-1,-1),float2(-1,3),float2(3,-1)};
  return float4(positions[id],0,1);
}
float4 psMain(float4 position : SV_Position) : SV_Target0 {
  uint2 pixel = uint2(position.xy);
  uint2 coordinate = uint2((pixel.x + tweak.w) & 63u,(pixel.y * 3u + 5u) & 63u);
  float2 uv = (float2(coordinate) + 0.5) / 64.0;
  uint4 value = uint4(round(inputTexture.SampleLevel(pointSampler,uv,0) * 255.0));
  value.r = (value.r + tweak.x) & 255u;
  value.g = (value.g + tweak.y) & 255u;
  value.b = value.b ^ tweak.z;
  return float4(value) / 255.0;
}
)HLSL";
    FILE *file = fopen(argv[2],"wb"); if (!file) return 3;
    fprintf(file,"// Own descriptor-table HLSL compiled with unchanged GPTK DXC.\n");
    bool good = emitShader(compiler,file,source,L"vsMain",L"vs_6_0","descriptor_vs_dxil") &&
      emitShader(compiler,file,source,L"psMain",L"ps_6_0","descriptor_ps_dxil");
    if (fclose(file)) good = false; compiler->Release(); return good ? 0 : 4;
  }
}
