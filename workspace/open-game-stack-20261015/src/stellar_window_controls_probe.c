/* Read-only window styles, enable state, responsiveness and cursor clipping. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>

static int refresh_frame;
static int show_window;

static BOOL CALLBACK inspect(HWND hwnd, LPARAM ignored)
{
    wchar_t cls[128];
    if (!IsWindowVisible(hwnd) || !GetClassNameW(hwnd, cls, 128) || wcscmp(cls, L"UnrealWindow")) return TRUE;
    DWORD pid=0, thread=GetWindowThreadProcessId(hwnd, &pid);
    RECT outer={0},client={0},clip={0};
    GUITHREADINFO gui={sizeof(gui)};
    GetWindowRect(hwnd,&outer); GetClientRect(hwnd,&client); GetClipCursor(&clip);
    GetGUIThreadInfo(thread,&gui);
    LONG_PTR style=GetWindowLongPtrW(hwnd,GWL_STYLE),ex=GetWindowLongPtrW(hwnd,GWL_EXSTYLE);
    DWORD_PTR reply=0;
    SetLastError(0);
    LRESULT responsive=SendMessageTimeoutW(hwnd,WM_NULL,0,0,SMTO_ABORTIFHUNG|SMTO_BLOCK,250,&reply);
    DWORD error=GetLastError();
    printf("window hwnd=%p pid=%lu thread=%lu enabled=%d style=0x%llx ex=0x%llx resize=%d maximize=%d popup=%d responsive=%lld responseError=%lu\n",hwnd,pid,thread,IsWindowEnabled(hwnd),(unsigned long long)style,(unsigned long long)ex,!!(style&WS_THICKFRAME),!!(style&WS_MAXIMIZEBOX),!!(style&WS_POPUP),(long long)responsive,error);
    printf("geometry outer=%ld,%ld,%ld,%ld client=%ld,%ld,%ld,%ld clip=%ld,%ld,%ld,%ld guiFlags=0x%lx capture=%p foreground=%p\n",outer.left,outer.top,outer.right,outer.bottom,client.left,client.top,client.right,client.bottom,clip.left,clip.top,clip.right,clip.bottom,gui.flags,gui.hwndCapture,GetForegroundWindow());
    MINMAXINFO constraints={0};
    /* WM_GETMINMAXINFO expects initialized defaults, as in Wine's own
       sync_window_min_max_info(). Zero maxima would manufacture a limit. */
    constraints.ptMinTrackSize.x=GetSystemMetrics(SM_CXMINTRACK);
    constraints.ptMinTrackSize.y=GetSystemMetrics(SM_CYMINTRACK);
    constraints.ptMaxTrackSize.x=GetSystemMetrics(SM_CXMAXTRACK);
    constraints.ptMaxTrackSize.y=GetSystemMetrics(SM_CYMAXTRACK);
    constraints.ptMaxSize.x=GetSystemMetrics(SM_CXMAXIMIZED);
    constraints.ptMaxSize.y=GetSystemMetrics(SM_CYMAXIMIZED);
    LRESULT limits=SendMessageTimeoutW(hwnd,WM_GETMINMAXINFO,0,(LPARAM)&constraints,SMTO_ABORTIFHUNG|SMTO_BLOCK,250,&reply);
    printf("constraints returned=%lld minTrack=%ld,%ld maxTrack=%ld,%ld\n",(long long)limits,constraints.ptMinTrackSize.x,constraints.ptMinTrackSize.y,constraints.ptMaxTrackSize.x,constraints.ptMaxTrackSize.y);
    if (show_window) {
        show_window=0;
        AllowSetForegroundWindow(ASFW_ANY);
        BOOL top=BringWindowToTop(hwnd);
        BOOL foreground=SetForegroundWindow(hwnd);
        printf("bringToTop=%d setForeground=%d error=%lu\n",top,foreground,GetLastError());
    }
    if (refresh_frame) {
        refresh_frame=0;
        SetLastError(0);
        BOOL refreshed=SetWindowPos(hwnd,NULL,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED);
        printf("refreshFrame=%d error=%lu\n",refreshed,GetLastError());
    }
    return TRUE;
}
int main(int argc,char **argv)
{
    refresh_frame=argc==2 && !strcmp(argv[1],"--refresh");
    show_window=argc==2 && !strcmp(argv[1],"--show");
    DPI_AWARENESS_CONTEXT (WINAPI *setDpi)(DPI_AWARENESS_CONTEXT) =
        (void *)GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext");
    if (setDpi) setDpi(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    for (unsigned i=0;i<(argc==2?3:30);i++) {
        printf("tick=%u\n",i);
        if (!EnumWindows(inspect,0)) return 1;
        fflush(stdout);
        Sleep(1000);
    }
    return 0;
}
