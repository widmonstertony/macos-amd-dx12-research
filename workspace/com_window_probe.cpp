// Independent, genuine STA-to-MTA IStream marshalling test. No Steam content.
#define mainCRTStartup unused_status_entry
#include "windows_status_probe.cpp"
#undef mainCRTStartup
struct Guid { U32 a; unsigned short b,c; unsigned char d[8]; };
static const Guid streamIID={0x0000000c,0,0,{0xc0,0,0,0,0,0,0,0x46}};
using InitFn=I32(__stdcall *)(void *,U32);
using UninitFn=void(__stdcall *)();
using UnmarshalFn=I32(__stdcall *)(void *,const Guid *,void **);
static InitFn initCOM; static UninitFn uninitCOM; static UnmarshalFn receive;
static void *marshalled; static U32 workerResult=9;
static void releaseObject(void *p) {
  if(p) reinterpret_cast<U32(__stdcall *)(void *)>((*static_cast<void***>(p))[2])(p);
}
static U32 __stdcall worker(void *) {
  I32 result=initCOM(nullptr,0);
  if(result<0){ workerResult=2; return 2; }
  void *stream=nullptr; result=receive(marshalled,&streamIID,&stream);
  text("MTA_unmarshal_hresult="); pointer(reinterpret_cast<Handle>(static_cast<U64>(static_cast<U32>(result))));text("\n");
  workerResult=result<0||!stream?3:0; releaseObject(stream); uninitCOM();return workerResult;
}
extern "C" void mainCRTStartup() {
  Handle ole=LoadLibraryW(L"ole32.dll"), kernel=LoadLibraryW(L"kernel32.dll");
  initCOM=reinterpret_cast<InitFn>(GetProcAddress(ole,"CoInitializeEx"));
  uninitCOM=reinterpret_cast<UninitFn>(GetProcAddress(ole,"CoUninitialize"));
  receive=reinterpret_cast<UnmarshalFn>(GetProcAddress(ole,"CoGetInterfaceAndReleaseStream"));
  auto create=reinterpret_cast<I32(__stdcall *)(Handle,I32,void**)>(GetProcAddress(ole,"CreateStreamOnHGlobal"));
  auto marshal=reinterpret_cast<I32(__stdcall *)(const Guid*,void*,void**)>(GetProcAddress(ole,"CoMarshalInterThreadInterfaceInStream"));
  auto createThread=reinterpret_cast<Handle(__stdcall *)(void*,U64,U32(__stdcall *)(void*),void*,U32,U32*)>(GetProcAddress(kernel,"CreateThread"));
  auto wait=reinterpret_cast<U32(__stdcall *)(Handle,U32)>(GetProcAddress(kernel,"WaitForSingleObject"));
  if(!initCOM||!uninitCOM||!receive||!create||!marshal||!createThread||!wait)ExitProcess(2);
  I32 result=initCOM(nullptr,2);
  text("STA_initialize_hresult=");pointer(reinterpret_cast<Handle>(static_cast<U64>(static_cast<U32>(result))));text("\n");
  if(result<0)ExitProcess(3);
  void *original=nullptr; result=create(nullptr,1,&original);if(result<0)ExitProcess(4);
  result=marshal(&streamIID,original,&marshalled);
  text("STA_marshal_hresult=");pointer(reinterpret_cast<Handle>(static_cast<U64>(static_cast<U32>(result))));text("\n");
  if(result<0){releaseObject(original);uninitCOM();ExitProcess(5);}
  Handle thread=createThread(nullptr,0,worker,nullptr,0,nullptr);
  if(!thread)ExitProcess(6);
  // Pump the real STA window messages while the MTA retrieves its proxy.
  struct Msg {Handle hwnd;U32 message;U64 wparam;I64 lparam;U32 time;I32 x,y;U32 priv;};
  Handle user=LoadLibraryW(L"user32.dll");
  auto peek=reinterpret_cast<I32(__stdcall *)(Msg*,Handle,U32,U32,U32)>(GetProcAddress(user,"PeekMessageW"));
  auto dispatch=reinterpret_cast<I64(__stdcall *)(const Msg*)>(GetProcAddress(user,"DispatchMessageW"));
  U32 elapsed=0;
  while(wait(thread,10)==258 && elapsed++<500){Msg msg={};while(peek(&msg,nullptr,0,0,1))dispatch(&msg);}
  if(wait(thread,0)!=0){text("COM_WINDOW_TEST_TIMEOUT\n");ExitProcess(7);}
  releaseObject(original);uninitCOM();
  text(workerResult?"COM_STA_MTA_WINDOW=FAIL\n":"COM_STA_MTA_WINDOW=PASS\n");
  ExitProcess(workerResult);
}
