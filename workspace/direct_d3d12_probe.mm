// Native macOS host for the ABI-verified Windows D3D12 probe. Loads the
// unmodified D3DMetal public exports directly, eliminating Wine from the test.
// Every exported D3D12/DXGI and COM call uses the Microsoft x64 calling ABI.
// Build with -fshort-wchar: DXGI description strings are UTF-16 on this ABI.
#include <dlfcn.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

static void *native_module = nullptr;
static const char *native_module_path = nullptr;
static unsigned int native_error = 0;

// Keep platform headers above these adaptations; the included probe remains
// the one authoritative set of checked D3D12 interface/structure declarations.
#define __stdcall __attribute__((ms_abi))
#define __declspec(x) PROBE_DECLSPEC_##x
#define PROBE_DECLSPEC_dllimport
#define PROBE_DECLSPEC_noreturn __attribute__((noreturn))
#define memset probe_memset
#define memcpy probe_memcpy
#include "d3d12_probe.cpp"
#undef memset
#undef memcpy

extern "C" Handle __stdcall LoadLibraryW(const wchar_t *) { return native_module; }
extern "C" void *__stdcall GetProcAddress(Handle module, const char *name) {
    dlerror();
    void *result = dlsym(module, name);
    const char *error = dlerror();
    if (error) {
        fprintf(stderr, "dlsym(%s): %s\n", name, error);
        native_error = 127; // analogous ERROR_PROC_NOT_FOUND for probe reporting.
    }
    return result;
}
extern "C" U32 __stdcall GetModuleFileNameW(Handle, wchar_t *buffer, U32 count) {
    // The mounted research paths are ASCII. This is display-only and does not
    // participate in D3DMetal loading or COM calls.
    U32 i = 0;
    if (!native_module_path || !count) return 0;
    while (native_module_path[i] && i + 1 < count) {
        buffer[i] = static_cast<unsigned char>(native_module_path[i]);
        ++i;
    }
    buffer[i] = 0;
    return i;
}
extern "C" U32 __stdcall GetLastError() { return native_error; }
extern "C" Handle __stdcall GetStdHandle(U32) { return nullptr; }
extern "C" I32 __stdcall WriteFile(Handle, const void *buffer, U32 count, U32 *written, void *) {
    U32 total = 0;
    while (total < count) {
        ssize_t n = write(STDOUT_FILENO, static_cast<const char *>(buffer) + total, count - total);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (written) *written = total; return 0; }
        total += static_cast<U32>(n);
    }
    if (written) *written = total;
    return 1;
}
extern "C" I32 __stdcall WideCharToMultiByte(U32 codepage, U32, const wchar_t *input, I32 input_count, char *output, I32 capacity, const char *, I32 *) {
    if (codepage != 65001 || input_count != -1 || capacity <= 0) return 0;
    I32 used = 0;
    for (U32 i = 0;; ++i) {
        U32 cp = static_cast<unsigned short>(input[i]);
        if (cp >= 0xd800 && cp <= 0xdbff) {
            U32 low = static_cast<unsigned short>(input[i + 1]);
            if (low >= 0xdc00 && low <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                ++i;
            } else cp = 0xfffd;
        } else if (cp >= 0xdc00 && cp <= 0xdfff) cp = 0xfffd;
        char encoded[4]; I32 n;
        if (cp <= 0x7f) { encoded[0] = static_cast<char>(cp); n = 1; }
        else if (cp <= 0x7ff) {
            encoded[0] = static_cast<char>(0xc0 | (cp >> 6));
            encoded[1] = static_cast<char>(0x80 | (cp & 63)); n = 2;
        } else if (cp <= 0xffff) {
            encoded[0] = static_cast<char>(0xe0 | (cp >> 12));
            encoded[1] = static_cast<char>(0x80 | ((cp >> 6) & 63));
            encoded[2] = static_cast<char>(0x80 | (cp & 63)); n = 3;
        } else {
            encoded[0] = static_cast<char>(0xf0 | (cp >> 18));
            encoded[1] = static_cast<char>(0x80 | ((cp >> 12) & 63));
            encoded[2] = static_cast<char>(0x80 | ((cp >> 6) & 63));
            encoded[3] = static_cast<char>(0x80 | (cp & 63)); n = 4;
        }
        if (used + n > capacity) return 0;
        for (I32 j = 0; j < n; ++j) output[used++] = encoded[j];
        if (!cp) return used;
    }
}
extern "C" void __stdcall Sleep(U32 milliseconds) { usleep(milliseconds * 1000u); }
extern "C" __attribute__((noreturn)) void __stdcall ExitProcess(U32 code) { _exit(static_cast<int>(code)); }

extern "C" int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s /absolute/path/to/D3DMetal.framework/D3DMetal\n", argv[0]);
        return 64;
    }
    native_module_path = argv[1];
    native_module = dlopen(native_module_path, RTLD_NOW | RTLD_LOCAL);
    if (!native_module) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 65; }
    text("D3D12_PROBE_HOST=native macOS with Microsoft x64 export/COM ABI; no Wine\n");
    mainCRTStartup();
}
