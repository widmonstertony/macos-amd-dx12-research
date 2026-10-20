// Read-only top-level Windows/Wine metadata. No child controls, passwords,
// body text, pixels, screenshots, activation, resizing or UI automation.
using U32=unsigned int;using I32=int;using U64=unsigned long long;using I64=long long;using H=void*;
extern "C" {
__declspec(dllimport) H __stdcall LoadLibraryW(const wchar_t*);
__declspec(dllimport) void* __stdcall GetProcAddress(H,const char*);
__declspec(dllimport) H __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(H,const void*,U32,U32*,void*);
__declspec(dllimport) void __stdcall ExitProcess(U32);
}
struct Rect{I32 left,top,right,bottom;};
using Callback=I32(__stdcall*)(H,I64);
static I32(__stdcall *getText)(H,wchar_t*,I32);
static I32(__stdcall *getClass)(H,wchar_t*,I32);
static U32(__stdcall *getPid)(H,U32*);
static I32(__stdcall *visible)(H);
static I32(__stdcall *getRect)(H,Rect*);
static H(__stdcall *foreground)();
static void text(const char*s){U32 n=0,w=0;while(s[n])n++;WriteFile(GetStdHandle((U32)-11),s,n,&w,nullptr);}
static void num(I64 n){char b[32];unsigned i=31;b[i]=0;U64 v=n<0?U64(-n):U64(n);do{b[--i]='0'+v%10;v/=10;}while(v);if(n<0)b[--i]='-';text(b+i);}
static bool eq(const wchar_t*a,const wchar_t*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static I32 __stdcall visit(H h,I64){
  if(!visible(h))return 1;
  static wchar_t caption[128],cls[128];getText(h,caption,128);getClass(h,cls,128);
  const char *kind=eq(caption,L"Sign in to Steam")||eq(caption,L"登录 Steam")?"steam-login":eq(caption,L"Steam")?"steam":eq(cls,L"UnrealWindow")?"unreal-game":"other";
  U32 pid=0;getPid(h,&pid);Rect r{};I32 rectValid=getRect(h,&r);
  text("caption=");for(unsigned i=0;caption[i];i++){char c[2]={caption[i]<128?char(caption[i]):'?',0};text(c);}text(" class=");for(unsigned i=0;cls[i];i++){char c[2]={cls[i]<128?char(cls[i]):'?',0};text(c);}text(" rectValid=");num(rectValid);text("\n");
  text("{\"pid\":");num(pid);text(",\"title_kind\":\"");text(kind);text("\",\"class_kind\":\"");
  text(eq(cls,L"SDL_app")?"SDL_app":eq(cls,L"UnrealWindow")?"UnrealWindow":eq(cls,L"#32770")?"dialog":"other");
  text("\",\"rect\":[");num(r.left);text(",");num(r.top);text(",");num(r.right);text(",");num(r.bottom);text("],\"foreground\":");text(foreground()==h?"true":"false");text("}\n");return 1;
}
extern "C" void mainCRTStartup(){
  H u=LoadLibraryW(L"user32.dll");if(!u)ExitProcess(2);
  auto enumerate=(I32(__stdcall*)(Callback,I64))GetProcAddress(u,"EnumWindows");
  foreground=(decltype(foreground))GetProcAddress(u,"GetForegroundWindow");
  getText=(decltype(getText))GetProcAddress(u,"GetWindowTextW");getClass=(decltype(getClass))GetProcAddress(u,"GetClassNameW");getPid=(decltype(getPid))GetProcAddress(u,"GetWindowThreadProcessId");visible=(decltype(visible))GetProcAddress(u,"IsWindowVisible");getRect=(decltype(getRect))GetProcAddress(u,"GetWindowRect");
  if(!enumerate||!getText||!getClass||!getPid||!visible||!getRect||!foreground)ExitProcess(3);
  text("{\"scope\":\"top-level window metadata only; no controls or credentials\"}\n");ExitProcess(enumerate(visit,0)?0:4);
}
