// App-local Wine API compatibility, not a graphics capability override.
// GetIntegratedDisplaySize semantics: Wine c68ed23672 / Highball patch 0017.
// Original AGS calls and exception handling are forwarded unchanged.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#define AGS_GCC
#define AGS_EXCLUDE_DIRECTX_TYPES
#include "vendor/amd_ags.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

static HMODULE self;
static wchar_t directory[32768];
static wchar_t log_path[32768];
static volatile LONG faults;
static volatile LONG display_calls;

static void log_line(const char *format, ...) {
    DWORD saved = GetLastError(), written;
    char line[4096];
    int n = snprintf(line, sizeof(line), "pid=%lu tid=%lu ", GetCurrentProcessId(), GetCurrentThreadId());
    va_list args; va_start(args, format);
    vsnprintf(line + n, sizeof(line) - n - 2, format, args); va_end(args);
    size_t length = strlen(line); line[length++] = '\n';
    HANDLE file = CreateFileW(log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE) {
        WriteFile(file, line, (DWORD)length, &written, NULL); CloseHandle(file);
    }
    SetLastError(saved);
}

static void log_pc(const char *kind, const void *pc) {
    HMODULE module = NULL; char name[1024] = "unknown";
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)pc, &module)) {
        GetModuleFileNameA(module, name, sizeof(name));
    }
    log_line("%s pc=%p module=%s rva=0x%llx", kind, pc, name,
             (unsigned long long)((uintptr_t)pc - (uintptr_t)module));
}

static LONG CALLBACK observe_fault(EXCEPTION_POINTERS *p) {
    if (p->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION ||
        InterlockedIncrement(&faults) > 8) return EXCEPTION_CONTINUE_SEARCH;
    auto c = p->ContextRecord; auto e = p->ExceptionRecord;
    log_line("access-violation code=%08lx access=%llu address=%p rip=%p rax=%p rcx=%p rdx=%p r8=%p r9=%p",
             e->ExceptionCode, (unsigned long long)e->ExceptionInformation[0],
             (void *)e->ExceptionInformation[1], (void *)c->Rip, (void *)c->Rax,
             (void *)c->Rcx, (void *)c->Rdx, (void *)c->R8, (void *)c->R9);
    log_pc("fault", (void *)c->Rip);
    void *frames[24]; USHORT count = CaptureStackBackTrace(0, 24, frames, NULL);
    for (USHORT i = 0; i < count; ++i) log_pc("observer-stack", frames[i]);
    // Do not hide, handle, or resume past the application's fault.
    return EXCEPTION_CONTINUE_SEARCH;
}

extern "C" __declspec(dllexport) HRESULT WINAPI fh6_GetIntegratedDisplaySize(double *inches) {
    // Match upstream Wine: E_NOTIMPL, output untouched, no fabricated panel size.
    if (InterlockedIncrement(&display_calls) <= 4)
        log_line("GetIntegratedDisplaySize output=%p result=E_NOTIMPL", inches);
    return E_NOTIMPL;
}

static bool scoped_process() {
    wchar_t name[32768]; if (!GetModuleFileNameW(NULL, name, 32768)) return false;
    const wchar_t *base = wcsrchr(name, L'\\'); base = base ? base + 1 : name;
    return !_wcsicmp(base, L"forzahorizon6.exe") ||
           !_wcsicmp(base, L"fh6-wine-compat-control.exe");
}

static unsigned repair_missing_display_import() {
    auto base = (BYTE *)GetModuleHandleW(NULL);
    auto dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    auto nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC)
        return 0;
    auto image_size = nt->OptionalHeader.SizeOfImage;
    auto imports = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!imports.VirtualAddress || imports.VirtualAddress + imports.Size > image_size) return 0;
    HMODULE kernel = GetModuleHandleW(L"kernelbase.dll");
    if (kernel && GetProcAddress(kernel, "GetIntegratedDisplaySize")) {
        log_line("display-import native-export-present; preserved"); return 0;
    }
    auto descriptor = (IMAGE_IMPORT_DESCRIPTOR *)(base + imports.VirtualAddress);
    unsigned repaired = 0;
    for (unsigned i = 0; i < imports.Size / sizeof(*descriptor) && descriptor[i].Name; ++i) {
        auto &d = descriptor[i];
        if (d.Name >= image_size || !d.OriginalFirstThunk || !d.FirstThunk) continue;
        const char *module = (const char *)(base + d.Name);
        if (_stricmp(module, "api-ms-win-core-sysinfo-l1-2-3.dll")) continue;
        for (size_t index = 0;; ++index) {
            size_t source_rva = d.OriginalFirstThunk + index * sizeof(IMAGE_THUNK_DATA64);
            size_t target_rva = d.FirstThunk + index * sizeof(IMAGE_THUNK_DATA64);
            if (source_rva + 8 > image_size || target_rva + 8 > image_size) break;
            auto thunk = (IMAGE_THUNK_DATA64 *)(base + source_rva);
            if (!thunk->u1.AddressOfData) break;
            if (IMAGE_SNAP_BY_ORDINAL64(thunk->u1.Ordinal)) continue;
            if (thunk->u1.AddressOfData + sizeof(IMAGE_IMPORT_BY_NAME) >= image_size) continue;
            auto import = (IMAGE_IMPORT_BY_NAME *)(base + thunk->u1.AddressOfData);
            if (strcmp(import->Name, "GetIntegratedDisplaySize")) continue;
            auto slot = (ULONG_PTR *)(base + target_rva); DWORD old, ignored;
            if (!VirtualProtect(slot, sizeof(*slot), PAGE_READWRITE, &old)) continue;
            *slot = (ULONG_PTR)&fh6_GetIntegratedDisplaySize;
            VirtualProtect(slot, sizeof(*slot), old, &ignored); ++repaired;
        }
    }
    log_line("display-import repaired=%u only-missing-API=1 executable-file-edited=0", repaired);
    return repaired;
}

static FARPROC original_function(const char *name) {
    static HMODULE original;
    if (!original) {
        wchar_t path[32768]; swprintf(path, 32768, L"%lsamd_ags_real.dll", directory);
        original = LoadLibraryW(path);
        if (!original || original == self) {
            log_line("original-AGS load-failed error=%lu", GetLastError()); return NULL;
        }
    }
    return GetProcAddress(original, name);
}

extern "C" AGSReturnCode agsInitialize(
        int version, const AGSConfiguration *config, AGSContext **context, AGSGPUInfo *info) {
    auto function = (AGS_INITIALIZE)original_function("agsInitialize");
    log_line("agsInitialize enter version=0x%x contextOut=%p info=%p", version, context, info);
    if (!function) return AGS_MISSING_D3D_DLL;
    auto result = function(version, config, context, info);
    log_line("agsInitialize exit result=%d context=%p devices=%d deviceArray=%p", result,
             context ? *context : NULL, info ? info->numDevices : -1, info ? info->devices : NULL);
    return result;
}

extern "C" AGSReturnCode agsDeInitialize(AGSContext *context) {
    auto function = (AGS_DEINITIALIZE)original_function("agsDeInitialize");
    log_line("agsDeInitialize context=%p", context);
    return function ? function(context) : AGS_MISSING_D3D_DLL;
}

extern "C" AGSReturnCode agsDriverExtensionsDX12_CreateDevice(
        AGSContext *context, const AGSDX12DeviceCreationParams *creation,
        const AGSDX12ExtensionParams *extensions, AGSDX12ReturnedParams *returned) {
    auto function = (AGS_DRIVEREXTENSIONSDX12_CREATEDEVICE)original_function("agsDriverExtensionsDX12_CreateDevice");
    log_line("agsCreateDevice enter context=%p creation=%p adapter=%p featureLevel=0x%x returned=%p",
             context, creation, creation ? creation->pAdapter : NULL,
             creation ? creation->FeatureLevel : 0, returned);
    if (!function) return AGS_MISSING_D3D_DLL;
    auto result = function(context, creation, extensions, returned);
    log_line("agsCreateDevice exit result=%d device=%p", result, returned ? returned->pDevice : NULL);
    return result;
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, void *) {
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    self = module; DisableThreadLibraryCalls(module);
    GetModuleFileNameW(module, directory, 32768);
    wchar_t *slash = wcsrchr(directory, L'\\'); if (!slash) return FALSE; slash[1] = 0;
    swprintf(log_path, 32768, L"%lsfh6-wine-compat.log", directory);
    if (!scoped_process()) return TRUE;
    log_line("compat-loaded display-stub=Wine-c68ed23672 AGS=unchanged-forwarder GPU-identity=unchanged");
    AddVectoredExceptionHandler(1, observe_fault);
    repair_missing_display_import();
    return TRUE;
}
