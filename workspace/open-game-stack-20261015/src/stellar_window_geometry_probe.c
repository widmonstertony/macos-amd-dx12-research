/* Read only the game's top-level geometry; no controls, input or pixels. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static BOOL CALLBACK window(HWND hwnd, LPARAM ignored)
{
    wchar_t cls[128];
    if (!IsWindowVisible(hwnd) || !GetClassNameW(hwnd, cls, 128) || wcscmp(cls, L"UnrealWindow")) return TRUE;
    DWORD pid = 0; RECT outer, client;
    GetWindowThreadProcessId(hwnd, &pid);
    GetWindowRect(hwnd, &outer); GetClientRect(hwnd, &client);
    printf("geometry.hwnd=%p pid=%lu dpi=%u outer=%ld,%ld,%ld,%ld client=%ld,%ld,%ld,%ld\n",
           hwnd, pid, GetDpiForWindow(hwnd), outer.left, outer.top, outer.right, outer.bottom,
           client.left, client.top, client.right, client.bottom);
    return TRUE;
}
int main(void)
{
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    return EnumWindows(window, 0) ? 0 : 1;
}
