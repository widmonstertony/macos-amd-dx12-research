// Read-only text probe restricted to visible top-level dialogs titled "Error".
// It does not activate windows, click controls, read Steam login windows, or
// inspect process memory.
using U32=unsigned int;using I32=int;using U64=unsigned long long;using I64=long long;using H=void*;
extern "C" {
__declspec(dllimport) H __stdcall LoadLibraryW(const wchar_t*);
__declspec(dllimport) void* __stdcall GetProcAddress(H,const char*);
__declspec(dllimport) H __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(H,const void*,U32,U32*,void*);
__declspec(dllimport) void __stdcall ExitProcess(U32);
}
using Callback=I32(__stdcall*)(H,I64);
static I32(__stdcall *getText)(H,wchar_t*,I32);
static I32(__stdcall *getClass)(H,wchar_t*,I32);
static I32(__stdcall *visible)(H);
static I32(__stdcall *enumChildren)(H,Callback,I64);
static wchar_t childCaption[2048],childClass[128],dialogCaption[128],dialogClass[128];
static void text(const char*s){U32 n=0,w=0;while(s[n])n++;WriteFile(GetStdHandle((U32)-11),s,n,&w,nullptr);}
static bool eq(const wchar_t*a,const wchar_t*b){while(*a&&*a==*b){a++;b++;}return *a==*b;}
static void wide(const wchar_t*s){for(unsigned i=0;s[i]&&i<2047;i++){unsigned c=s[i];char b[5];unsigned n=0;if(c<0x80)b[n++]=(char)c;else if(c<0x800){b[n++]=(char)(0xc0|(c>>6));b[n++]=(char)(0x80|(c&63));}else{b[n++]=(char)(0xe0|(c>>12));b[n++]=(char)(0x80|((c>>6)&63));b[n++]=(char)(0x80|(c&63));}b[n]=0;text(b);}}
static I32 __stdcall child(H h,I64){
 childCaption[0]=0;childClass[0]=0;getText(h,childCaption,2048);getClass(h,childClass,128);
 if(childCaption[0]){text("control_class=");wide(childClass);text(" text=");wide(childCaption);text("\n");}
 return 1;
}
static I32 __stdcall visit(H h,I64){
 if(!visible(h))return 1;
 dialogCaption[0]=0;dialogClass[0]=0;getText(h,dialogCaption,128);getClass(h,dialogClass,128);
 if(eq(dialogCaption,L"Error")&&eq(dialogClass,L"#32770")){text("dialog=Error\n");enumChildren(h,child,0);}
 return 1;
}
extern "C" void mainCRTStartup(){
 H u=LoadLibraryW(L"user32.dll");if(!u)ExitProcess(2);
 auto enumerate=(I32(__stdcall*)(Callback,I64))GetProcAddress(u,"EnumWindows");
 enumChildren=(decltype(enumChildren))GetProcAddress(u,"EnumChildWindows");
 getText=(decltype(getText))GetProcAddress(u,"GetWindowTextW");getClass=(decltype(getClass))GetProcAddress(u,"GetClassNameW");visible=(decltype(visible))GetProcAddress(u,"IsWindowVisible");
 if(!enumerate||!enumChildren||!getText||!getClass||!visible)ExitProcess(3);
 text("scope=visible Error dialogs only; no activation or input\n");ExitProcess(enumerate(visit,0)?0:4);
}
