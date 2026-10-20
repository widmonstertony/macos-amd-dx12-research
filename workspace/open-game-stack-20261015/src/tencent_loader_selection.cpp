// Read only selected graphics configuration, never credentials or arbitrary env.
#define mainCRTStartup unused_probe_entry
#include "../../d3d12_probe.cpp"
#undef mainCRTStartup
extern "C" __declspec(dllimport) U32 __stdcall GetEnvironmentVariableW(const wchar_t*,wchar_t*,U32);
extern "C" void mainCRTStartup(){
 const wchar_t* keys[]={L"WINEDLLOVERRIDES",L"WINEDLLPATH",L"GFX_BACKEND_PATH",L"VKD3D_AMD_PROTECTED_SUBSET"};
 for(auto key:keys){static wchar_t value[2048]={};U32 n=GetEnvironmentVariableW(key,value,2048);wide(key);text("=");if(n&&n<2048)wide(value);else text("(unset or too long)");text("\n");}
 Handle d=LoadLibraryW(L"d3d12.dll");module("D3D12.module",d);text("D3D12.load_error=");number(GetLastError());text("\n");
 Handle c=LoadLibraryW(L"d3d12core.dll");module("D3D12Core.module",c);text("D3D12Core.load_error=");number(GetLastError());text("\n");
 if(d){auto f=(unsigned char*)GetProcAddress(d,"D3D12CreateDevice");text("D3D12CreateDevice.prefix=");if(f)for(unsigned i=0;i<12;i++){hex(f[i]);text(" ");}text("\n");}
 ExitProcess(0);
}
