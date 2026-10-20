// Self-authored SM5 shaders compiled through the genuine Wine public Windows
// D3DCompile interface. No DXC, shader-model promotion, or game shader changes.
struct DxbcPrograms {
    Com *VSBlob, *PSBlob;
    const void *VS, *PS;
    Size VSBytes, PSBytes;
};
static U32 dxbc_read32(const unsigned char *p) { return U32(p[0]) | U32(p[1]) << 8 | U32(p[2]) << 16 | U32(p[3]) << 24; }
static bool dxbc_check_container(const void *data, Size bytes, U32 expectedType) {
    const auto *p = static_cast<const unsigned char *>(data);
    if (bytes < 32 || dxbc_read32(p) != 0x43425844 || dxbc_read32(p + 24) != bytes) return false;
    U32 count = dxbc_read32(p + 28); if (count > 128 || 32 + Size(count) * 4 > bytes) return false;
    bool sm5 = false, hasDXIL = false;
    for (U32 part = 0; part < count; ++part) {
        U32 offset = dxbc_read32(p + 32 + part * 4); if (Size(offset) + 8 > bytes) return false;
        U32 size = dxbc_read32(p + offset + 4), kind = dxbc_read32(p + offset);
        if (Size(offset) + 8 + size > bytes) return false;
        char name[5] = {char(p[offset]), char(p[offset+1]), char(p[offset+2]), char(p[offset+3]), 0};
        text("dxbc.container.part="); text(name); text(" bytes="); number(size); text("\n");
        if (kind == 0x4c495844) hasDXIL = true;
        if ((kind == 0x58454853 || kind == 0x52444853) && size >= 8) { // SHEX or SHDR.
            U32 version = dxbc_read32(p + offset + 8), program = version >> 16;
            U32 major = (version >> 4) & 15, minor = version & 15;
            text("dxbc.shader_type="); number(program); text(" model="); number(major); text("."); number(minor); text("\n");
            if (program == expectedType && major == 5 && minor == 0) sm5 = true;
        }
    }
    text("dxbc.contains_DXIL="); number(hasDXIL); text(" genuine_SM5_tokens="); number(sm5); text("\n");
    return sm5 && !hasDXIL;
}
static bool dxbc_compile_programs(DxbcPrograms *out) {
    Handle library = LoadLibraryW(L"d3dcompiler_47.dll");
    if (!library) { text("dxbc.D3DCompiler47.LoadLibrary.failed="); number(GetLastError()); text("\n"); return false; }
    static wchar_t path[1024] = {}; GetModuleFileNameW(library, path, 1024);
    text("dxbc.D3DCompiler47.path="); wide(path); text("\n");
    using Compile = HR (__stdcall *)(const void *, Size, const char *, const void *, void *, const char *, const char *, U32, U32, Com **, Com **);
    auto compile = reinterpret_cast<Compile>(GetProcAddress(library, "D3DCompile"));
    if (!compile) { text("dxbc.D3DCompile.export missing\n"); return false; }
    static const char source[] =
        "float4 vsMain(uint id:SV_VertexID):SV_Position {"
        "float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};"
        "return float4(p[id],0,1);}\n"
        "float4 psMain(float4 position:SV_Position):SV_Target0 {"
        "uint2 pixel=uint2(position.xy);uint r=(pixel.x*3u+17u)&255u;"
        "uint g=(pixel.y*5u+29u)&255u;"
        "return float4(float(r)/255.0,float(g)/255.0,73.0/255.0,1.0);}\n";
    const char *entries[] = {"vsMain", "psMain"}, *profiles[] = {"vs_5_0", "ps_5_0"};
    for (U32 stage = 0; stage < 2; ++stage) {
        Com **blob = stage ? &out->PSBlob : &out->VSBlob, *errors = nullptr;
        HR result = compile(source, sizeof(source)-1, "own-sm5-pattern.hlsl", nullptr, nullptr, entries[stage], profiles[stage], 1u << 15, 0, blob, &errors);
        text("dxbc.D3DCompile.profile="); text(profiles[stage]); text("\n"); hr("dxbc.D3DCompile", result);
        if (errors) { text("dxbc.compiler_messages="); text(static_cast<const char *>(method<void *(__stdcall *)(Com *)>(errors,3)(errors))); text("\n"); release(errors); }
        if (result < 0 || !*blob) return false;
        const void *data = method<void *(__stdcall *)(Com *)>(*blob,3)(*blob); Size bytes = method<Size (__stdcall *)(Com *)>(*blob,4)(*blob);
        if (!dxbc_check_container(data, bytes, stage ? 0 : 1)) { text("dxbc.shader verification failed; no GPU execution\n"); return false; }
        if (stage) { out->PS = data; out->PSBytes = bytes; } else { out->VS = data; out->VSBytes = bytes; }
    }
    return true;
}
