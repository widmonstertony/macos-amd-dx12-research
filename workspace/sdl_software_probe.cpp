// Uses this legitimate Steam client's unmodified SDL3 public API to exercise
// software presentation. Own solid-color window only; no Steam/credential read.
using U32=unsigned; using U64=unsigned long long; using I32=int; using H=void*;
extern "C" {
__declspec(dllimport) H __stdcall LoadLibraryW(const wchar_t*);
__declspec(dllimport) void* __stdcall GetProcAddress(H,const char*);
__declspec(dllimport) H __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(H,const void*,U32,U32*,void*);
__declspec(dllimport) void __stdcall Sleep(U32);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(U32);
}
static void text(const char *s){U32 n=0,w=0;while(s[n])n++;WriteFile(GetStdHandle((U32)-11),s,n,&w,nullptr);}
static void hex(U32 n){char b[]="0x00000000\n";for(U32 i=0;i<8;i++)b[9-i]="0123456789abcdef"[(n>>(i*4))&15];text(b);}
extern "C" void mainCRTStartup(){
 H sdl=LoadLibraryW(L"Z:\\Users\\tonytan\\Documents\\GitHub\\gptk-intel-research-20261011\\SteamClient\\SDL3.dll");
 if(!sdl){text("SDL_LOAD_FAILED\n");ExitProcess(2);}
#define SDL_API(var,type,symbol) auto var=reinterpret_cast<type>(GetProcAddress(sdl,symbol));if(!var){text("MISSING " symbol "\n");ExitProcess(3);}
 SDL_API(init,bool(*)(U32),"SDL_Init")
 SDL_API(window,H(*)(const char*,I32,I32,U64),"SDL_CreateWindow")
 SDL_API(renderer,H(*)(H,const char*),"SDL_CreateRenderer")
 SDL_API(name,const char*(*)(H),"SDL_GetRendererName")
 SDL_API(color,bool(*)(H,unsigned char,unsigned char,unsigned char,unsigned char),"SDL_SetRenderDrawColor")
 SDL_API(clear,bool(*)(H),"SDL_RenderClear")
 SDL_API(present,bool(*)(H),"SDL_RenderPresent")
 SDL_API(pump,void(*)(),"SDL_PumpEvents")
 SDL_API(properties,U32(*)(H),"SDL_GetWindowProperties")
 SDL_API(property,H(*)(U32,const char*,H),"SDL_GetPointerProperty")
 SDL_API(destroyRenderer,void(*)(H),"SDL_DestroyRenderer")
 SDL_API(destroyWindow,void(*)(H),"SDL_DestroyWindow")
 SDL_API(quit,void(*)(),"SDL_Quit")
 SDL_API(error,const char*(*)(),"SDL_GetError")
 if(!init(0x20)){text(error());text("\nSDL_INIT_FAILED\n");ExitProcess(4);}
 H win=window("SDL3 own software presentation diagnostic",320,180,0);
 if(!win){text(error());text("\nSDL_WINDOW_FAILED\n");ExitProcess(5);}
 H r=renderer(win,"software");
 if(!r){text(error());text("\nSDL_SOFTWARE_RENDERER_FAILED\n");ExitProcess(6);}
 text("actual_renderer=");text(name(r));text("\n");
 bool good=color(r,37,89,151,255)&&clear(r)&&present(r);
 for(U32 i=0;i<30;i++){pump();Sleep(50);}
 H hwnd=property(properties(win),"SDL.window.win32.hwnd",nullptr);
 H user=LoadLibraryW(L"user32.dll"),gdi=LoadLibraryW(L"gdi32.dll");
 auto getDC=reinterpret_cast<H(__stdcall*)(H)>(GetProcAddress(user,"GetDC"));
 auto releaseDC=reinterpret_cast<I32(__stdcall*)(H,H)>(GetProcAddress(user,"ReleaseDC"));
 auto getPixel=reinterpret_cast<U32(__stdcall*)(H,I32,I32)>(GetProcAddress(gdi,"GetPixel"));
 U32 actual=0xffffffff;
 if(hwnd&&getDC&&releaseDC&&getPixel){H dc=getDC(hwnd);if(dc){actual=getPixel(dc,16,16);releaseDC(hwnd,dc);}}
 text("own_window_gdi_pixel=");hex(actual);
 text("expected_pixel=0x00975925\n");
 good=good&&actual==0x00975925;
 destroyRenderer(r);destroyWindow(win);quit();
 text(good?"SDL3_SOFTWARE_AND_OWN_WINDOW_GDI=PASS\n":"SDL3_SOFTWARE_AND_OWN_WINDOW_GDI=FAIL\n");
 ExitProcess(good?0:7);
}
