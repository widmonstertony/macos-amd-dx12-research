#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#define AGS_GCC
#define AGS_EXCLUDE_DIRECTX_TYPES
#include "vendor/amd_ags.h"
#include <stdio.h>

extern "C" __declspec(dllimport) HRESULT WINAPI GetIntegratedDisplaySize(double *);

int main() {
    double sentinel = 123.25;
    HRESULT result = GetIntegratedDisplaySize(&sentinel);
    printf("display.result=%08lx sentinel=%.2f\n", (unsigned long)result, sentinel);
    if (result != E_NOTIMPL || sentinel != 123.25) return 2;
    if (GetIntegratedDisplaySize(NULL) != E_NOTIMPL) return 3;
    HMODULE real = LoadLibraryW(L"amd_ags_real.dll");
    if (!real) return 4;
    auto direct_version = (int (*)())GetProcAddress(real, "agsGetVersionNumber");
    int version = agsGetVersionNumber();
    printf("ags.version=%08x direct=%08x\n", version, direct_version ? direct_version() : 0);
    if (!direct_version || version != direct_version()) return 5;
    AGSContext *context = NULL; AGSGPUInfo info = {};
    AGSReturnCode initialized = agsInitialize(version, NULL, &context, &info);
    printf("ags.initialize=%d context=%p devices=%d array=%p\n", initialized, context, info.numDevices, info.devices);
    // AGS is allowed to fail on a system without a Windows AMD driver.
    if (initialized == AGS_SUCCESS && context) agsDeInitialize(context);
    printf("compat.control=PASS no-success-or-GPU-feature-fabrication\n");
    return 0;
}
