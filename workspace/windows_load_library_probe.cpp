// Windows x64 DLL-load-stage probe: only kernel32 imports, no CRT and no calls
// into any graphics factory/device/COM interface. Prints before and after each
// LoadLibrary plus public export addresses; optional per-module invocation.
using U32 = unsigned int;
using U64 = unsigned long long;
using I32 = int;
using Handle = void *;
extern "C" {
__declspec(dllimport) Handle __stdcall LoadLibraryW(const wchar_t *);
__declspec(dllimport) void *__stdcall GetProcAddress(Handle, const char *);
__declspec(dllimport) U32 __stdcall GetModuleFileNameW(Handle, wchar_t *, U32);
__declspec(dllimport) U32 __stdcall GetLastError();
__declspec(dllimport) void __stdcall SetLastError(U32);
__declspec(dllimport) Handle __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(Handle, const void *, U32, U32 *, void *);
__declspec(dllimport) I32 __stdcall WideCharToMultiByte(U32, U32, const wchar_t *, I32, char *, I32, const char *, I32 *);
__declspec(dllimport) wchar_t *__stdcall GetCommandLineW();
__declspec(dllimport) U32 __stdcall SetErrorMode(U32);
__declspec(dllimport) void __stdcall Sleep(U32);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(U32);
void *memset(void *dst, int value, U64 size) {
    auto *p = static_cast<volatile unsigned char *>(dst);
    for (U64 i = 0; i < size; ++i) p[i] = static_cast<unsigned char>(value);
    return dst;
}
}
static void text(const char *s) {
    U32 length = 0, written = 0;
    while (s[length]) ++length;
    WriteFile(GetStdHandle(static_cast<U32>(-11)), s, length, &written, nullptr);
}
static __attribute__((noinline)) void wide(const wchar_t *s) {
    char buffer[2048];
    I32 n = WideCharToMultiByte(65001, 0, s, -1, buffer, sizeof(buffer), nullptr, nullptr);
    text(n > 0 ? buffer : "<UTF16 conversion failed>");
}
static void hex(U64 v) {
    char buffer[19] = "0x0000000000000000";
    for (U32 i = 0; i < 16; ++i) buffer[17-i] = "0123456789abcdef"[(v >> (i*4)) & 15];
    text(buffer);
}
static bool same(const wchar_t *a, const wchar_t *b) {
    for (U32 i = 0;; ++i) { if (a[i] != b[i]) return false; if (!a[i]) return true; }
}
static const wchar_t *selection() {
    static wchar_t selected[64];
    const wchar_t *line = GetCommandLineW();
    U32 i = 0;
    if (line[i] == L'"') { ++i; while (line[i] && line[i] != L'"') ++i; if (line[i]) ++i; }
    else while (line[i] && line[i] != L' ' && line[i] != L'\t') ++i;
    while (line[i] == L' ' || line[i] == L'\t') ++i;
    if (!line[i]) return L"all";
    bool quoted = line[i] == L'"'; if (quoted) ++i;
    U32 out = 0;
    while (line[i] && out < 63 && (quoted ? line[i] != L'"' : line[i] != L' ' && line[i] != L'\t')) selected[out++] = line[i++];
    selected[out] = 0;
    return selected;
}
static void public_export(Handle module, const char *name) {
    SetLastError(0);
    void *address = GetProcAddress(module, name);
    U32 error = GetLastError();
    text("EXPORT name="); text(name); text(" address="); hex(reinterpret_cast<U64>(address)); text(" error="); hex(error); text("\n");
}
static bool load(const wchar_t *name, const char *first, const char *second) {
    text("LOAD.begin module="); wide(name); text("\n");
    SetLastError(0);
    Handle module = LoadLibraryW(name);
    U32 error = GetLastError();
    text("LOAD.return module="); wide(name); text(" handle="); hex(reinterpret_cast<U64>(module)); text(" error="); hex(error); text("\n");
    if (!module) return false;
    wchar_t path[1024];
    text("LOAD.path=");
    if (GetModuleFileNameW(module, path, 1024)) wide(path); else text("<unavailable>");
    text("\n");
    if (first) public_export(module, first);
    if (second) public_export(module, second);
    text("LOAD.async_wait_begin module="); wide(name); text(" milliseconds=250\n");
    Sleep(250);
    text("LOAD.async_wait_return module="); wide(name); text("\n");
    return true;
}
extern "C" __declspec(noreturn) void mainCRTStartup() {
    SetErrorMode(0x8001); // failcriticalerrors + noopenfileerrorbox; no GUI API used.
    const wchar_t *selected = selection();
    text("WINDOWS_LOAD_LIBRARY_PROBE=1 selection="); wide(selected); text("\n");
    text("No graphics exports or COM methods will be called.\n");
    bool all = same(selected, L"all"), ok = true;
    if (all || same(selected, L"user32")) ok &= load(L"user32.dll", "EnumDisplayMonitors", nullptr);
    if (all || same(selected, L"dxgi")) ok &= load(L"dxgi.dll", "CreateDXGIFactory1", "CreateDXGIFactory2");
    if (all || same(selected, L"d3d12")) ok &= load(L"d3d12.dll", "D3D12CreateDevice", "D3D12GetInterface");
    if (!all && !same(selected, L"user32") && !same(selected, L"dxgi") && !same(selected, L"d3d12")) {
        text("Invalid selection: use all, user32, dxgi, or d3d12.\n"); ExitProcess(2);
    }
    text(ok ? "LOAD_PROBE.result=PASS\n" : "LOAD_PROBE.result=FAIL\n");
    ExitProcess(ok ? 0 : 3);
}
