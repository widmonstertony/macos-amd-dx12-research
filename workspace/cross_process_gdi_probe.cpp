// Genuine foreign-HWND GDI blit with own solid-color window only.
#define mainCRTStartup unused_status_entry
#include "windows_status_probe.cpp"
#undef mainCRTStartup
static const wchar_t *ownTitle=L"Wine own cross-process GDI diagnostic";
static const char *argument=" --paint-own-hwnd=0x";
static Handle user,gdi,kernel;
static GetDCFn getDC;static ReleaseDCFn releaseDC;static GetPixelFn getPixel;
static void report(const char *name,U32 value){text(name);text("=");pointer(reinterpret_cast<Handle>(static_cast<U64>(value)));text("\n");}
static U32 paint(Handle hwnd){
  auto caption=reinterpret_cast<GetWindowTextWFn>(GetProcAddress(user,"GetWindowTextW"));
  wchar_t title[128]={};caption(hwnd,title,128);
  if(!equalWide(title,ownTitle)){text("REFUSED_NON_DIAGNOSTIC_TARGET\n");return 2;}
  Handle dc=getDC(hwnd);if(!dc)return 3;
  auto createDC=reinterpret_cast<Handle(__stdcall *)(Handle)>(GetProcAddress(gdi,"CreateCompatibleDC"));
  auto createDIB=reinterpret_cast<Handle(__stdcall *)(Handle,const void*,U32,void**,Handle,U32)>(GetProcAddress(gdi,"CreateDIBSection"));
  auto select=reinterpret_cast<Handle(__stdcall *)(Handle,Handle)>(GetProcAddress(gdi,"SelectObject"));
  auto blit=reinterpret_cast<I32(__stdcall *)(Handle,I32,I32,I32,I32,Handle,I32,I32,U32)>(GetProcAddress(gdi,"BitBlt"));
  auto flush=reinterpret_cast<I32(__stdcall *)()>(GetProcAddress(gdi,"GdiFlush"));
  auto deleteObj=reinterpret_cast<I32(__stdcall *)(Handle)>(GetProcAddress(gdi,"DeleteObject"));
  auto deleteDC=reinterpret_cast<I32(__stdcall *)(Handle)>(GetProcAddress(gdi,"DeleteDC"));
  struct Info {U32 size;I32 width,height;unsigned short planes,bpp;U32 compression,imageSize;I32 xppm,yppm;U32 used,important;U32 colors;};
  Info info={40,320,-180,1,32,0,320*180*4,0,0,0,0,0};
  void *bits=nullptr;Handle dib=createDIB(dc,&info,0,&bits,nullptr,0),mem=createDC(dc);
  if(!dib||!bits||!mem){releaseDC(hwnd,dc);return 4;}
  auto data=static_cast<U32*>(bits);for(U32 i=0;i<320*180;++i)data[i]=0x00255997;
  Handle old=select(mem,dib);I32 result=blit(dc,0,0,320,180,mem,0,0,0x00cc0020);flush();
  U32 actual=getPixel(dc,16,16);report("child_BitBlt",result);report("child_pixel",actual);
  select(mem,old);deleteObj(dib);deleteDC(mem);releaseDC(hwnd,dc);
  return result&&actual==0x00975925?0:5;
}
extern "C" void mainCRTStartup(){
  user=LoadLibraryW(L"user32.dll");gdi=LoadLibraryW(L"gdi32.dll");kernel=LoadLibraryW(L"kernel32.dll");
  getDC=reinterpret_cast<GetDCFn>(GetProcAddress(user,"GetDC"));
  releaseDC=reinterpret_cast<ReleaseDCFn>(GetProcAddress(user,"ReleaseDC"));
  getPixel=reinterpret_cast<GetPixelFn>(GetProcAddress(gdi,"GetPixel"));
  auto command=reinterpret_cast<GetCommandLineWFn>(GetProcAddress(kernel,"GetCommandLineW"));
  const wchar_t *line=command();
  for(const wchar_t *p=line;*p;++p){const wchar_t *q=p;const char *a=argument;while(*a&&*q==*a){++a;++q;}if(!*a){
    U64 value=0;for(U32 n=0;n<16;++n){U32 digit=*q++;if(digit>='0'&&digit<='9')digit-='0';else if(digit>='a'&&digit<='f')digit=digit-'a'+10;else ExitProcess(8);value=(value<<4)|digit;}
    ExitProcess(paint(reinterpret_cast<Handle>(value)));}}
  Handle sdl=LoadLibraryW(L"Z:\\Users\\tonytan\\Documents\\GitHub\\gptk-intel-research-20261011\\SteamClient\\SDL3.dll");
  auto init=reinterpret_cast<bool(*)(U32)>(GetProcAddress(sdl,"SDL_Init"));
  auto create=reinterpret_cast<Handle(*)(const char*,I32,I32,U64)>(GetProcAddress(sdl,"SDL_CreateWindow"));
  auto properties=reinterpret_cast<U32(*)(Handle)>(GetProcAddress(sdl,"SDL_GetWindowProperties"));
  auto property=reinterpret_cast<Handle(*)(U32,const char*,Handle)>(GetProcAddress(sdl,"SDL_GetPointerProperty"));
  auto pump=reinterpret_cast<void(*)()>(GetProcAddress(sdl,"SDL_PumpEvents"));
  auto destroy=reinterpret_cast<void(*)(Handle)>(GetProcAddress(sdl,"SDL_DestroyWindow"));
  auto quit=reinterpret_cast<void(*)()>(GetProcAddress(sdl,"SDL_Quit"));
  auto pause=reinterpret_cast<void(__stdcall *)(U32)>(GetProcAddress(kernel,"Sleep"));
  if(!init||!create||!properties||!property||!pump||!destroy||!quit||!pause||!init(0x20))ExitProcess(9);
  Handle win=create("Wine own cross-process GDI diagnostic",320,180,0);if(!win)ExitProcess(10);
  Handle hwnd=property(properties(win),"SDL.window.win32.hwnd",nullptr);if(!hwnd)ExitProcess(11);
  for(U32 n=0;n<10;++n){pump();pause(30);}
  if(hasArgument(line,L"--layered-child-test")){
    auto createChild=reinterpret_cast<Handle(__stdcall *)(U32,const wchar_t*,const wchar_t*,U32,I32,I32,I32,I32,Handle,Handle,Handle,void*)>(GetProcAddress(user,"CreateWindowExW"));
    auto getRect=reinterpret_cast<GetWindowRectFn>(GetProcAddress(user,"GetWindowRect"));
    struct Point{I32 x,y;};
    auto update=reinterpret_cast<I32(__stdcall *)(Handle,Handle,const Point*,const Point*,Handle,const Point*,U32,const void*,U32)>(GetProcAddress(user,"UpdateLayeredWindow"));
    Handle child=createChild(0x80000,L"STATIC",L"Own layered child",0x50000000,24,32,160,90,hwnd,nullptr,nullptr,nullptr);
    Rect start={},last={};if(!child||!getRect(child,&start))ExitProcess(16);
    U32 errors=0;Point pos={start.left,start.top};
    for(U32 n=0;n<5;++n){if(!update(child,nullptr,&pos,nullptr,nullptr,nullptr,0,nullptr,0))++errors;getRect(child,&last);if(last.left!=start.left||last.top!=start.top)++errors;}
    text("layered_child_initial_screen_xy=");signedNumber(start.left);text(",");signedNumber(start.top);text("\n");
    text("layered_child_final_screen_xy=");signedNumber(last.left);text(",");signedNumber(last.top);text("\n");
    report("layered_child_errors",errors);
    if(hasArgument(line,L"--layered-draw-test")){
      auto createDC=reinterpret_cast<Handle(__stdcall *)(Handle)>(GetProcAddress(gdi,"CreateCompatibleDC"));
      auto createDIB=reinterpret_cast<Handle(__stdcall *)(Handle,const void*,U32,void**,Handle,U32)>(GetProcAddress(gdi,"CreateDIBSection"));
      auto select=reinterpret_cast<Handle(__stdcall *)(Handle,Handle)>(GetProcAddress(gdi,"SelectObject"));
      auto getDCEx=reinterpret_cast<Handle(__stdcall *)(Handle,Handle,U32)>(GetProcAddress(user,"GetDCEx"));
      auto deleteObj=reinterpret_cast<I32(__stdcall *)(Handle)>(GetProcAddress(gdi,"DeleteObject"));
      auto deleteDC=reinterpret_cast<I32(__stdcall *)(Handle)>(GetProcAddress(gdi,"DeleteDC"));
      struct Info{U32 size;I32 width,height;unsigned short planes,bpp;U32 compression,imageSize;I32 xppm,yppm;U32 used,important,colors;};
      Info info={40,160,-90,1,32,0,160*90*4,0,0,0,0,0};void *bits=nullptr;
      Handle mem=createDC(nullptr),dib=createDIB(mem,&info,0,&bits,nullptr,0);
      if(!mem||!dib||!bits)ExitProcess(18);Handle old=select(mem,dib);
      for(U32 n=0;n<160*90;++n)static_cast<U32*>(bits)[n]=0xff255997;
      Point size={160,90},zero={0,0};unsigned char blend[4]={0,0,255,1};
      I32 applied=update(child,nullptr,&pos,&size,mem,&zero,0,blend,2);
      // Explicit cached parent DC maps the whole window backing coordinates
      // here. Derive the child point from real window bounds, not frame sizes.
      Rect ownerRect={};getRect(hwnd,&ownerRect);
      Handle dc=getDCEx(hwnd,nullptr,2);U32 actual=dc?getPixel(dc,start.left-ownerRect.left+16,start.top-ownerRect.top+16):0xffffffff;
      U32 matching=0;I32 minX=320,minY=180,maxX=0,maxY=0;
      if(dc){for(I32 y=0;y<180;++y)for(I32 x=0;x<320;++x)if(getPixel(dc,x,y)==0x00975925){++matching;if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y;}releaseDC(hwnd,dc);}
      report("parent_all_matching_pixels",matching);text("own_blue_client_bounds=");signedNumber(minX);text(",");signedNumber(minY);text(",");signedNumber(maxX);text(",");signedNumber(maxY);text("\n");
      report("layered_update_return",applied);report("parent_composite_pixel",actual);report("expected_composite_pixel",0x00975925);
      if(!applied||actual!=0x00975925||matching!=160*90)++errors;
      select(mem,old);deleteObj(dib);deleteDC(mem);
      for(U32 n=0;n<60;++n){pump();pause(50);}
    }
    destroy(win);quit();
    text(errors?"LAYERED_CHILD_SCREEN_POSITION=FAIL\n":"LAYERED_CHILD_SCREEN_POSITION=PASS\n");ExitProcess(errors?17:0);
  }
  U32 ownResult=paint(hwnd);report("same_process_DIB_control",ownResult);
  if(ownResult){destroy(win);quit();text("SAME_PROCESS_CONTROL_FAILED\n");ExitProcess(15);}
  // Reset only the diagnostic surface so old correct pixels cannot give a
  // false cross-process PASS. Parent uses a different solid background.
  auto createBrush=reinterpret_cast<Handle(__stdcall *)(U32)>(GetProcAddress(gdi,"CreateSolidBrush"));
  auto fill=reinterpret_cast<I32(__stdcall *)(Handle,const Rect*,Handle)>(GetProcAddress(user,"FillRect"));
  auto deleteObject=reinterpret_cast<I32(__stdcall *)(Handle)>(GetProcAddress(gdi,"DeleteObject"));
  Handle resetDC=getDC(hwnd),brush=createBrush(0x001e140a);Rect area={0,0,320,180};
  fill(resetDC,&area,brush);releaseDC(hwnd,resetDC);deleteObject(brush);
  auto fileName=reinterpret_cast<U32(__stdcall *)(Handle,wchar_t*,U32)>(GetProcAddress(kernel,"GetModuleFileNameW"));
  auto spawn=reinterpret_cast<I32(__stdcall *)(const wchar_t*,wchar_t*,void*,void*,I32,U32,void*,const wchar_t*,void*,void*)>(GetProcAddress(kernel,"CreateProcessW"));
  auto wait=reinterpret_cast<U32(__stdcall *)(Handle,U32)>(GetProcAddress(kernel,"WaitForSingleObject"));
  auto exitCode=reinterpret_cast<I32(__stdcall *)(Handle,U32*)>(GetProcAddress(kernel,"GetExitCodeProcess"));
  static wchar_t path[1024],childCommand[1200];U32 length=fileName(nullptr,path,1024);if(!length||length>=1024)ExitProcess(12);
  U32 j=0;childCommand[j++]=L'"';for(U32 n=0;n<length;++n)childCommand[j++]=path[n];childCommand[j++]=L'"';
  for(const char *a=argument;*a;++a)childCommand[j++]=*a;
  U64 value=reinterpret_cast<U64>(hwnd);for(I32 n=15;n>=0;--n)childCommand[j++]="0123456789abcdef"[(value>>(n*4))&15];childCommand[j]=0;
  alignas(8) unsigned char startup[104]={};*reinterpret_cast<U32*>(startup)=104;
  struct Process {Handle process,thread;U32 pid,tid;} child={};
  if(!spawn(path,childCommand,nullptr,nullptr,0,0,nullptr,nullptr,startup,&child))ExitProcess(13);
  U32 elapsed=0;while(wait(child.process,10)==258&&elapsed++<500)pump();
  U32 code=259;exitCode(child.process,&code);report("child_exit",code);
  Handle dc=getDC(hwnd);U32 actual=dc?getPixel(dc,16,16):0xffffffff;if(dc)releaseDC(hwnd,dc);
  report("parent_pixel",actual);report("expected_pixel",0x00975925);
  // Hold only this diagnostic window briefly; never sample a Steam window.
  for(U32 n=0;n<20;++n){pump();pause(50);}
  destroy(win);quit();bool good=code==0&&actual==0x00975925;
  text(good?"FOREIGN_HWND_GDI_DIB=PASS\n":"FOREIGN_HWND_GDI_DIB=FAIL\n");ExitProcess(good?0:14);
}
