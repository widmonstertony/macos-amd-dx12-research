#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#define BOOL DXC_BOOL
#include "../shader_probe_headers/dxcapi.h"
#undef BOOL

static bool emitShader(IDxcCompiler3 *compiler, FILE *file, const char *source,
                       const wchar_t *entry, const wchar_t *target, const char *symbol) {
    DxcBuffer buffer = {source, strlen(source), DXC_CP_UTF8};
    const wchar_t *args[] = {L"-E", entry, L"-T", target, L"-O3"};
    IDxcResult *result = nullptr;
    HRESULT compile = compiler->Compile(&buffer, args, 5, nullptr, __uuidof(IDxcResult), reinterpret_cast<void **>(&result));
    if (compile < 0 || !result) return false;
    IDxcBlobUtf8 *errors = nullptr;
    result->GetOutput(DXC_OUT_ERRORS, __uuidof(IDxcBlobUtf8), reinterpret_cast<void **>(&errors), nullptr);
    if (errors) { if (errors->GetStringLength()) fprintf(stderr, "%s\n", errors->GetStringPointer()); errors->Release(); }
    HRESULT status = 0;
    result->GetStatus(&status);
    if (status < 0) { result->Release(); return false; }
    IDxcBlob *shader = nullptr;
    result->GetOutput(DXC_OUT_OBJECT, __uuidof(IDxcBlob), reinterpret_cast<void **>(&shader), nullptr);
    if (!shader) { result->Release(); return false; }
    fprintf(file, "static const unsigned char %s[] = {\n", symbol);
    const auto *bytes = static_cast<const unsigned char *>(shader->GetBufferPointer());
    for (size_t i = 0; i < shader->GetBufferSize(); ++i) fprintf(file, "0x%02x,%s", bytes[i], i % 16 == 15 ? "\n" : "");
    fprintf(file, "\n};\n");
    printf("DXC.original_graphics_shader.%s.bytes=%zu\n", symbol, shader->GetBufferSize());
    shader->Release(); result->Release();
    return true;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: compile_graphics_shaders <libdxcompiler.dylib> <output-header>\n"); return 64; }
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { fprintf(stderr, "DXC dlopen: %s\n", dlerror()); return 1; }
        auto create = reinterpret_cast<DxcCreateInstanceProc>(dlsym(library, "DxcCreateInstance"));
        if (!create) return 2;
        IDxcCompiler3 *compiler = nullptr;
        if (create(CLSID_DxcCompiler, __uuidof(IDxcCompiler3), reinterpret_cast<void **>(&compiler)) < 0 || !compiler) return 3;
        const char *source = R"HLSL(
float4 vsMain(uint id : SV_VertexID) : SV_Position {
    float2 positions[3] = {float2(-1.0, -1.0), float2(-1.0, 3.0), float2(3.0, -1.0)};
    return float4(positions[id], 0.0, 1.0);
}
float4 psMain(float4 position : SV_Position) : SV_Target0 {
    uint2 pixel = uint2(position.xy);
    uint r = (pixel.x * 3u + 17u) & 255u;
    uint g = (pixel.y * 5u + 29u) & 255u;
    return float4(float(r) / 255.0, float(g) / 255.0, 73.0 / 255.0, 1.0);
}
)HLSL";
        FILE *file = fopen(argv[2], "wb");
        if (!file) return 4;
        fprintf(file, "// Generated from original minimal graphics probe HLSL by GPTK's unchanged DXC.\n");
        bool good = emitShader(compiler, file, source, L"vsMain", L"vs_6_0", "graphics_vs_dxil") &&
                    emitShader(compiler, file, source, L"psMain", L"ps_6_0", "graphics_ps_dxil");
        if (fclose(file)) good = false;
        compiler->Release();
        return good ? 0 : 5;
    }
}
