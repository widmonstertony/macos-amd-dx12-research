using U32=unsigned int; using U16=unsigned short; using I32=int; using H=void*; using U64=unsigned long long;
extern "C" { __declspec(dllimport) H __stdcall LoadLibraryW(const wchar_t*); __declspec(dllimport) void* __stdcall GetProcAddress(H,const char*); __declspec(dllimport) void __stdcall ExitProcess(U32); }
static bool equal(const wchar_t*a,const wchar_t*b){while(*a&&*a==*b){++a;++b;}return *a==*b;}
static bool starts(const wchar_t*a,const wchar_t*b){while(*b&&*a==*b){++a;++b;}return !*b;}
extern "C" void mainCRTStartup(){
 H u=LoadLibraryW(L"user32.dll"),k=LoadLibraryW(L"kernel32.dll"); if(!u||!k)ExitProcess(2);
 auto find=(H(__stdcall*)(const wchar_t*,const wchar_t*))GetProcAddress(u,"FindWindowW");
 auto text=(I32(__stdcall*)(H,wchar_t*,I32))GetProcAddress(u,"GetWindowTextW");
 auto cls=(I32(__stdcall*)(H,wchar_t*,I32))GetProcAddress(u,"GetClassNameW");
 auto top=(I32(__stdcall*)(H))GetProcAddress(u,"BringWindowToTop");
 auto fg=(I32(__stdcall*)(H))GetProcAddress(u,"SetForegroundWindow");
 auto post=(I32(__stdcall*)(H,U32,U64,long long))GetProcAddress(u,"PostMessageW");
 auto sleep=(void(__stdcall*)(U32))GetProcAddress(k,"Sleep");
 if(!find||!text||!cls||!top||!fg||!post||!sleep)ExitProcess(3);
 H w=find(nullptr,L"StellarBlade  "); if(!w)w=find(nullptr,L"StellarBlade"); if(!w)ExitProcess(4);
 wchar_t t[64]={},c[64]={}; text(w,t,64); cls(w,c,64); if(!starts(t,L"StellarBlade")||!equal(c,L"UnrealWindow"))ExitProcess(5);
 top(w); fg(w); sleep(250); constexpr U32 down=0x0100,up=0x0101; constexpr U64 enter=0x0d;
 if(!post(w,down,enter,0x001c0001)||!post(w,up,enter,0xc01c0001))ExitProcess(6);
 ExitProcess(0);
}
