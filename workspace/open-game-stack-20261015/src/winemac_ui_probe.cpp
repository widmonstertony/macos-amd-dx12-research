#define mainCRTStartup unused_base_probe_entry
#include "../../d3d12_probe.cpp"
#undef mainCRTStartup

static U32 __stdcall close_own_dialog(void *) {
    auto user=LoadLibraryW(L"user32.dll"),kernel=LoadLibraryW(L"kernel32.dll");
    auto find=reinterpret_cast<Handle (__stdcall *)(const wchar_t *,const wchar_t *)>(GetProcAddress(user,"FindWindowW"));
    auto getPID=reinterpret_cast<U32 (__stdcall *)(Handle,U32 *)>(GetProcAddress(user,"GetWindowThreadProcessId"));
    auto ownPID=reinterpret_cast<U32 (__stdcall *)()>(GetProcAddress(kernel,"GetCurrentProcessId"));
    auto post=reinterpret_cast<I32 (__stdcall *)(Handle,U32,U64,long long)>(GetProcAddress(user,"PostMessageW"));
    if(!find||!getPID||!ownPID||!post) return 1;
    for(U32 i=0;i<300;++i) {
        auto hwnd=find(nullptr,L"窗口模块隔离自检");U32 pid=0;
        if(hwnd&&getPID(hwnd,&pid)&&pid==ownPID()) {
            Sleep(200);post(hwnd,0x0111,1,0);return 0;
        }
        Sleep(10);
    }
    return 2;
}
extern "C" __declspec(noreturn) void mainCRTStartup() {
    auto user=LoadLibraryW(L"user32.dll");
    auto gdi=LoadLibraryW(L"gdi32.dll");
    auto getDC=reinterpret_cast<Handle (__stdcall *)(Handle)>(GetProcAddress(user,"GetDC"));
    auto releaseDC=reinterpret_cast<I32 (__stdcall *)(Handle,Handle)>(GetProcAddress(user,"ReleaseDC"));
    auto stock=reinterpret_cast<Handle (__stdcall *)(I32)>(GetProcAddress(gdi,"GetStockObject"));
    auto select=reinterpret_cast<Handle (__stdcall *)(Handle,Handle)>(GetProcAddress(gdi,"SelectObject"));
    auto metrics=reinterpret_cast<I32 (__stdcall *)(Handle,void *)>(GetProcAddress(gdi,"GetTextMetricsW"));
    if(!getDC||!releaseDC||!stock||!select||!metrics) ExitProcess(4);
    auto dc=getDC(nullptr);auto old=select(dc,stock(17));alignas(8) unsigned char metricData[128]={};
    I32 fontOK=metrics(dc,metricData);
    text("window_ui.GetTextMetrics=");number(fontOK);text(" height=");number(*reinterpret_cast<U32 *>(metricData));text(" error=");number(GetLastError());text("\n");
    select(dc,old);releaseDC(nullptr,dc);
    if(!fontOK) ExitProcess(5);
    auto box=reinterpret_cast<I32 (__stdcall *)(Handle,const wchar_t *,const wchar_t *,U32)>(GetProcAddress(user,"MessageBoxW"));
    auto kernel=LoadLibraryW(L"kernel32.dll");
    auto createThread=reinterpret_cast<Handle (__stdcall *)(void *,Size,U32 (__stdcall *)(void *),void *,U32,U32 *)>(GetProcAddress(kernel,"CreateThread"));
    if(!box||!createThread||!createThread(nullptr,0,close_own_dialog,nullptr,0,nullptr)) ExitProcess(2);
    I32 result=box(nullptr,L"Wine 窗口模块隔离自检，本窗口会自动关闭。",L"窗口模块隔离自检",0);
    text("window_ui.result=");number(result);text("\n");
    bool pass=result==1;
    text(pass?"window_ui.result=PASS\n":"window_ui.result=FAIL\n");
    ExitProcess(pass?0:3);
}
