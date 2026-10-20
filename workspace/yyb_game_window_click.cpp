// Normal Win32 input/window APIs for the one existing Stellar Blade window.
// No game launch, game code injection, process memory, settings/save edits,
// or shutdown. Only send Alt+Enter when this exact game is foreground.
using U32=unsigned int;using I32=int;using U64=unsigned long long;using I64=long long;using H=void*;
extern "C" {
__declspec(dllimport) H __stdcall LoadLibraryW(const wchar_t*);
__declspec(dllimport) void* __stdcall GetProcAddress(H,const char*);
__declspec(dllimport) H __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(H,const void*,U32,U32*,void*);
__declspec(dllimport) void __stdcall ExitProcess(U32);
}
struct Rect{I32 left,top,right,bottom;};
struct Key {unsigned short vk,scan;U32 flags,time;U64 extra;};
struct Input {U32 type,pad;union {Key key;U64 storage[4];};};
static_assert(sizeof(Input)==40,"Win64 INPUT ABI");
using Callback=I32(__stdcall*)(H,I64);
static I32(__stdcall *getClass)(H,wchar_t*,I32);
static U32(__stdcall *getPid)(H,U32*);
static I32(__stdcall *visible)(H);
static H(__stdcall *openProcess)(U32,I32,U32);
static I32(__stdcall *queryImage)(H,U32,wchar_t*,U32*);
static I32(__stdcall *closeHandle)(H);
static H game;static U32 matches,gamePid;
static bool eq(const wchar_t*a,const wchar_t*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static bool has(const wchar_t*a,const wchar_t*b){for(;*a;a++){const wchar_t*x=a,*y=b;while(*y&&*x==*y){x++;y++;}if(!*y)return true;}return false;}
static void text(const char*s){U32 n=0,w=0;while(s[n])n++;WriteFile(GetStdHandle((U32)-11),s,n,&w,nullptr);}
static void num(U64 v){char b[32];unsigned i=31;b[i]=0;do{b[--i]='0'+v%10;v/=10;}while(v);text(b+i);}
static I32 __stdcall visit(H h,I64){
  wchar_t cls[128];if(!visible(h)||!getClass(h,cls,128)||!eq(cls,L"UnrealWindow"))return 1;
  U32 pid=0;getPid(h,&pid);H process=openProcess(0x1000,0,pid);if(!process)return 1;
  static wchar_t path[4096];U32 count=4096;I32 ok=queryImage(process,0,path,&count);closeHandle(process);
  if(!ok||!eq(path,L"Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\SteamClient\\steamapps\\common\\StellarBlade\\SB\\Binaries\\Win64\\SB-Win64-Shipping.exe"))return 1;
  game=h;gamePid=pid;matches++;return 1;
}
extern "C" void mainCRTStartup(){
  H u=LoadLibraryW(L"user32.dll"),k=LoadLibraryW(L"kernel32.dll");if(!u||!k)ExitProcess(2);
  auto enumerate=(I32(__stdcall*)(Callback,I64))GetProcAddress(u,"EnumWindows");
  getClass=(decltype(getClass))GetProcAddress(u,"GetClassNameW");getPid=(decltype(getPid))GetProcAddress(u,"GetWindowThreadProcessId");visible=(decltype(visible))GetProcAddress(u,"IsWindowVisible");
  openProcess=(decltype(openProcess))GetProcAddress(k,"OpenProcess");queryImage=(decltype(queryImage))GetProcAddress(k,"QueryFullProcessImageNameW");closeHandle=(decltype(closeHandle))GetProcAddress(k,"CloseHandle");
  auto foreground=(H(__stdcall*)())GetProcAddress(u,"GetForegroundWindow");
  auto send=(U32(__stdcall*)(U32,Input*,I32))GetProcAddress(u,"SendInput");
  auto clip=(I32(__stdcall*)(const Rect*))GetProcAddress(u,"ClipCursor");
  auto position=(I32(__stdcall*)(H,H,I32,I32,I32,I32,U32))GetProcAddress(u,"SetWindowPos");
  auto show=(I32(__stdcall*)(H,I32))GetProcAddress(u,"ShowWindowAsync");
  auto activate=(I32(__stdcall*)(H))GetProcAddress(u,"SetForegroundWindow");
  auto command=(wchar_t*(__stdcall*)())GetProcAddress(k,"GetCommandLineW");
  if(!enumerate||!getClass||!getPid||!visible||!openProcess||!queryImage||!closeHandle||!foreground||!send||!clip||!position)ExitProcess(3);
  enumerate(visit,0);text("WINDOW_RELEASE exactGameMatches=");num(matches);text(" windowsPid=");num(gamePid);text("\n");
  if(matches!=1)ExitProcess(4);
  if(command&&has(command(),L" --continue-click ")){
    auto post=(I32(__stdcall*)(H,U32,U64,I64))GetProcAddress(u,"PostMessageW");
    auto client=(I32(__stdcall*)(H,Rect*))GetProcAddress(u,"GetClientRect");
    wchar_t *p=command();while(*p&&!(p[0]==L'-'&&p[1]==L'-'&&has(p,L"--continue-click ")))p++;while(*p&&*p!=L' ')p++;while(*p==L' ')p++;
    U32 x=0,y=0;bool xd=false,yd=false;while(*p>=L'0'&&*p<=L'9'){xd=true;x=x*10+(*p++-L'0');if(x>10000)ExitProcess(9);}while(*p==L' ')p++;
    while(*p>=L'0'&&*p<=L'9'){yd=true;y=y*10+(*p++-L'0');if(y>10000)ExitProcess(9);}
    Rect r={};if(!xd||!yd||!post||!client||!client(game,&r)||r.right<=0||r.bottom<=0)ExitProcess(9);
    I32 px=(I32)((U64)r.right*x/10000),py=(I32)((U64)r.bottom*y/10000);if(px>=r.right||py>=r.bottom)ExitProcess(9);
    I64 point=(I64)((U32)(unsigned short)px|((U32)(unsigned short)py<<16));
    I32 moved=post(game,0x200,0,point),down=post(game,0x201,1,point),up=post(game,0x202,0,point);
    text("WINDOW_CLICK exactGameOnly normalClientMouseMessages=");num(moved+down+up);text(" clientX=");num(px);text(" clientY=");num(py);text(" noNewGame noOtherAppInput visualResultPending\n");ExitProcess(moved&&down&&up?0:10);
  }
  if(show&&activate&&command&&has(command(),L" --show")){
    I32 restored=show(game,9);
    I32 lowered=position(game,(H)(I64)-2,0,0,0,0,0x4000|0x1|0x2);
    I32 activated=activate(game);I32 unclipped=clip(nullptr);
    text("WINDOW_SHOW restoreRequest=");num(restored);text(" removedTopmostRequest=");num(lowered);text(" foregroundRequest=");num(activated);text(" cursorUnclip=");num(unclipped);text(" no new game instance, shutdown or config edits; visual result pending\n");
    ExitProcess(activated?0:7);
  }
  if(foreground()!=game){text("WINDOW_RELEASE no input: exact game is not foreground\n");ExitProcess(5);}
  Input keys[4]={};for(unsigned i=0;i<4;i++){keys[i].type=1;keys[i].key.vk=(i==0||i==3)?0x12:0x0d;keys[i].key.flags=i>=2?2:0;}
  U32 delivered=send(4,keys,sizeof(Input));
  I32 unclipped=clip(nullptr);
  I32 lowered=position(game,(H)(I64)-2,0,0,0,0,0x4000|0x1|0x2|0x10);
  text("WINDOW_RELEASE normalAltEnterEvents=");num(delivered);text(" cursorUnclip=");num(unclipped);text(" removedTopmostRequest=");num(lowered);text(" no shutdown or config edits; visual result not established\n");
  ExitProcess(delivered==4?0:6);
}
