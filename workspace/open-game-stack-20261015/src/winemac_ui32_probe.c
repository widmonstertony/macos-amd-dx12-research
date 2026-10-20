#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

int main(void) {
    WNDCLASSW cls={0};
    cls.lpfnWndProc=DefWindowProcW;
    cls.hInstance=GetModuleHandleW(NULL);
    cls.lpszClassName=L"IsolatedWine32WindowProbe";
    ATOM atom=RegisterClassW(&cls);
    printf("ui32.RegisterClass=%u error=%lu\n",atom,GetLastError());
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,L"Wine 32-bit isolated window probe",WS_OVERLAPPEDWINDOW,140,140,300,200,NULL,NULL,cls.hInstance,NULL);
    printf("ui32.CreateWindow=%p error=%lu\n",hwnd,GetLastError());
    if(!hwnd) return 2;
    HDC dc=GetDC(hwnd);TEXTMETRICW tm={0};
    BOOL text=GetTextMetricsW(dc,&tm);
    printf("ui32.GetTextMetrics=%d error=%lu height=%ld\n",text,GetLastError(),tm.tmHeight);
    HFONT font=CreateFontW(-16,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,L"Tahoma");
    printf("ui32.CreateFont=%p error=%lu\n",font,GetLastError());
    if(font)DeleteObject(font);
    ReleaseDC(hwnd,dc);DestroyWindow(hwnd);
    printf("ui32.result=%s\n",text?"PASS":"FAIL");
    return text?0:3;
}
