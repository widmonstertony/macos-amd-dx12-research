// Windows x64 WSI companion to the verified native Cocoa DXGI Present probe.
// Standard user32 HWND + DXGI APIs only. No CRT/SDK installation required.
// D3D12/DXGI COM ABI: Microsoft MIT DirectX-Headers; user32 declarations
// independently checked against Wine's public include/winuser.h.
#define mainCRTStartup unused_capability_entry
#include "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/d3d12_probe.cpp"
#undef mainCRTStartup
#define D3D12_GRAPHICS_BASE_INCLUDED
#define mainCRTStartup unused_graphics_entry
#include "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/graphics-probe/d3d12_graphics_probe.cpp"
#undef mainCRTStartup

using I64 = long long;
using WndProc = I64 (__stdcall *)(Handle,U32,U64,I64);
struct WClass { U32 Size,Style; WndProc Proc; I32 ClassExtra,WindowExtra; Handle Instance,Icon,Cursor,Background; const wchar_t *Menu,*Name; Handle SmallIcon; };
struct WPoint { I32 X,Y; };
struct WMessage { Handle Window; U32 Message; U64 WParam; I64 LParam; U32 Time; WPoint Point; };
static_assert(sizeof(WClass)==80 && sizeof(WMessage)==48,"Windows x64 user32 ABI");
extern "C" {
__declspec(dllimport) unsigned short __stdcall RegisterClassExW(const WClass *);
__declspec(dllimport) Handle __stdcall CreateWindowExW(U32,const wchar_t *,const wchar_t *,U32,I32,I32,I32,I32,Handle,Handle,Handle,void *);
__declspec(dllimport) I64 __stdcall DefWindowProcW(Handle,U32,U64,I64);
__declspec(dllimport) I32 __stdcall DestroyWindow(Handle);
__declspec(dllimport) I32 __stdcall ShowWindow(Handle,I32);
__declspec(dllimport) I32 __stdcall UpdateWindow(Handle);
__declspec(dllimport) I32 __stdcall PeekMessageW(WMessage *,Handle,U32,U32,U32);
__declspec(dllimport) I32 __stdcall TranslateMessage(const WMessage *);
__declspec(dllimport) I64 __stdcall DispatchMessageW(const WMessage *);
}

static I64 __stdcall presentation_proc(Handle hwnd,U32 message,U64 wparam,I64 lparam) {
    return DefWindowProcW(hwnd,message,wparam,lparam);
}
static void pump_messages() {
    WMessage message={};
    while(PeekMessageW(&message,nullptr,0,0,1)) {TranslateMessage(&message);DispatchMessageW(&message);}
}
static bool wait_fence(Com *fence,U64 target) {
    for(U32 i=0;i<500;++i) {
        U64 current=method<U64 (__stdcall *)(Com *)>(fence,8)(fence);
        if(current==~U64(0)) return false;
        if(current>=target) return true;
        pump_messages();Sleep(10);
    }
    return false;
}
struct WSwapDesc { U32 Width,Height,Format; I32 Stereo; U32 SampleCount,SampleQuality,Usage,BufferCount,Scaling,SwapEffect,AlphaMode,Flags; };
static_assert(sizeof(WSwapDesc)==48,"DXGI_SWAP_CHAIN_DESC1 ABI");
static const Guid W_IID_Factory2={0x50c83a1c,0xe072,0x4c48,{0x87,0xb0,0x36,0x30,0xfa,0x36,0xa6,0xd0}};
static const Guid W_IID_SwapChain3={0x94d99bdb,0xf1f8,0x4ab0,{0xb2,0x36,0x7d,0xa0,0x17,0x0e,0xda,0xb1}};

static void format_matrix(Com *factory,Com *device,Handle hwnd) {
    Com *queue=nullptr;QueueDesc desc={0,0,0,0};
    HR h=method<HR (__stdcall *)(Com *,const QueueDesc *,const Guid *,Com **)>(device,8)(device,&desc,&IID_Queue,&queue);
    hr("format_matrix.CreateQueue",h);if(h<0)return;
    U32 formats[]={87,28,24,10};
    for(U32 f:formats) {
        WSwapDesc sd={64,64,f,0,1,0,0x20,2,0,4,3,0};Com *swap=nullptr;
        text("format_matrix.format=");number(f);text("\n");
        h=method<HR (__stdcall *)(Com *,Com *,Handle,const WSwapDesc *,const void *,Com *,Com **)>(factory,15)(factory,queue,hwnd,&sd,nullptr,nullptr,&swap);
        hr("format_matrix.CreateSwapChainForHwnd",h);release(swap);pump_messages();
    }
    release(queue);
}

static bool window_presentation(Handle d3d12,Com *factory,Com *device,Handle hwnd) {
    Com *blob=nullptr,*errors=nullptr,*root=nullptr,*pso=nullptr,*heap=nullptr;
    Com *queue=nullptr,*allocator=nullptr,*list=nullptr,*list7=nullptr,*swap=nullptr,*swap3=nullptr,*backbuffer=nullptr,*readback=nullptr,*fence=nullptr;
    bool pass=false;
    auto need=[](const char *name,HR value) {hr(name,value);return value>=0;};
    {
        auto serialize=reinterpret_cast<HR (__stdcall *)(const GRootSignatureDesc *,U32,Com **,Com **)>(GetProcAddress(d3d12,"D3D12SerializeRootSignature"));
        GRootSignatureDesc rootDesc={};
        if(!serialize || !need("presentation.SerializeEmptyRoot",serialize(&rootDesc,1,&blob,&errors))) goto cleanup;
        void *rootData=method<void *(__stdcall *)(Com *)>(blob,3)(blob);Size rootBytes=method<Size (__stdcall *)(Com *)>(blob,4)(blob);
        if(!need("presentation.CreateRootSignature",method<HR (__stdcall *)(Com *,U32,const void *,Size,const Guid *,Com **)>(device,16)(device,0,rootData,rootBytes,&G_IID_Root,&root))) goto cleanup;
        GGraphicsPipeline pipeline={};
        pipeline.Root=root;pipeline.VS={graphics_vs_dxil,sizeof(graphics_vs_dxil)};pipeline.PS={graphics_ps_dxil,sizeof(graphics_ps_dxil)};
        for(U32 i=0;i<8;++i) pipeline.Blend.Targets[i]={0,0,2,1,1,2,1,1,5,15};
        pipeline.SampleMask=~U32(0);pipeline.Rasterizer={3,1,0,0,0,0,1,0,0,0,0};pipeline.DepthStencil.DepthFunc=8;
        pipeline.DepthStencil.Front=pipeline.DepthStencil.Back={1,1,1,8};pipeline.TopologyType=3;pipeline.NumTargets=1;pipeline.TargetFormats[0]=87;pipeline.SampleCount=1;
        if(!need("presentation.CreateGraphicsPSO",method<HR (__stdcall *)(Com *,const GGraphicsPipeline *,const Guid *,Com **)>(device,10)(device,&pipeline,&G_IID_PSO,&pso))) goto cleanup;
        QueueDesc queueDesc={0,0,0,0};
        if(!need("presentation.CreateQueue",method<HR (__stdcall *)(Com *,const QueueDesc *,const Guid *,Com **)>(device,8)(device,&queueDesc,&IID_Queue,&queue))) goto cleanup;
        WSwapDesc swapDesc={64,64,87,0,1,0,0x20,2,0,4,3,0};
        if(!need("presentation.CreateSwapChainForHwnd",method<HR (__stdcall *)(Com *,Com *,Handle,const WSwapDesc *,const void *,Com *,Com **)>(factory,15)(factory,queue,hwnd,&swapDesc,nullptr,nullptr,&swap))) goto cleanup;
        if(!need("presentation.QuerySwapChain3",method<HR (__stdcall *)(Com *,const Guid *,Com **)>(swap,0)(swap,&W_IID_SwapChain3,&swap3))) goto cleanup;
        U32 index=method<U32 (__stdcall *)(Com *)>(swap3,36)(swap3);text("presentation.CurrentBackBufferIndex=");number(index);text("\n");
        if(!need("presentation.GetBuffer",method<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(swap,9)(swap,index,&IID_Resource,&backbuffer))) goto cleanup;
        GHeapDesc heapDesc={2,1,0,0};
        if(!need("presentation.CreateRTVHeap",method<HR (__stdcall *)(Com *,const GHeapDesc *,const Guid *,Com **)>(device,14)(device,&heapDesc,&G_IID_DescriptorHeap,&heap))) goto cleanup;
        GCpuHandle rtv={};method<GCpuHandle *(__stdcall *)(Com *,GCpuHandle *)>(heap,9)(heap,&rtv);
        if(!rtv.Ptr) goto cleanup;
        method<void (__stdcall *)(Com *,Com *,const void *,GCpuHandle)>(device,20)(device,backbuffer,nullptr,rtv);
        if(!need("presentation.CreateAllocator",method<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(device,9)(device,0,&IID_Allocator,&allocator))) goto cleanup;
        if(!need("presentation.CreateList",method<HR (__stdcall *)(Com *,U32,U32,Com *,Com *,const Guid *,Com **)>(device,12)(device,0,0,allocator,pso,&IID_CommandList,&list))) goto cleanup;
        if(!need("presentation.QueryList7",method<HR (__stdcall *)(Com *,const Guid *,Com **)>(list,0)(list,&IID_CommandList7,&list7))) goto cleanup;
        HeapProperties readHeap={3,0,0,1,1};ResourceDesc readDesc={1,0,16384,1,1,1,0,1,0,1,0};
        if(!need("presentation.CreateReadback",method<HR (__stdcall *)(Com *,const HeapProperties *,U32,const ResourceDesc *,U32,const void *,const Guid *,Com **)>(device,27)(device,&readHeap,0,&readDesc,0x400,nullptr,&IID_Resource,&readback))) goto cleanup;
        if(!need("presentation.CreateFence",method<HR (__stdcall *)(Com *,U64,U32,const Guid *,Com **)>(device,36)(device,0,0,&IID_Fence,&fence))) goto cleanup;
        GTextureBarrier prepare={0,0x40,0x80000000u,8,0,2,backbuffer,{0,1,0,1,0,1},0};GBarrierGroup group={1,1,&prepare};
        auto barrier=method<void (__stdcall *)(Com *,U32,const GBarrierGroup *)>(list7,80);barrier(list7,1,&group);
        method<void (__stdcall *)(Com *,Com *)>(list,30)(list,root);GViewport viewport={0,0,64,64,0,1};GRect rect={0,0,64,64};
        method<void (__stdcall *)(Com *,U32,const GViewport *)>(list,21)(list,1,&viewport);method<void (__stdcall *)(Com *,U32,const GRect *)>(list,22)(list,1,&rect);
        method<void (__stdcall *)(Com *,U32)>(list,20)(list,4);method<void (__stdcall *)(Com *,U32,const GCpuHandle *,I32,const GCpuHandle *)>(list,46)(list,1,&rtv,0,nullptr);
        method<void (__stdcall *)(Com *,U32,U32,U32,U32)>(list,12)(list,3,1,0,0);text("presentation.DrawInstanced=fullscreen triangle XY gradient\n");
        GTextureBarrier toCopy={0x40,0x200,8,0x800,2,7,backbuffer,{0,1,0,1,0,1},0};group.Textures=&toCopy;barrier(list7,1,&group);
        GCopyLocation source={};source.Resource=backbuffer;GCopyLocation dest={};dest.Resource=readback;dest.Type=1;dest.Placed={0,{87,64,64,1,256}};
        method<void (__stdcall *)(Com *,const GCopyLocation *,U32,U32,U32,const GCopyLocation *,const void *)>(list,16)(list,&dest,0,0,0,&source,nullptr);
        GTextureBarrier toPresent={0x200,0,0x800,0,7,0,backbuffer,{0,1,0,1,0,1},0};group.Textures=&toPresent;barrier(list7,1,&group);
        if(!need("presentation.Close",method<HR (__stdcall *)(Com *)>(list,9)(list))) goto cleanup;
        method<void (__stdcall *)(Com *,U32,Com *const *)>(queue,10)(queue,1,&list);
        if(!need("presentation.SignalBeforePresent",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,1)) || !wait_fence(fence,1)) goto cleanup;
        Range readRange={0,16384},noWrite={0,0};void *mapped=nullptr;
        if(!need("presentation.MapBackBufferReadback",method<HR (__stdcall *)(Com *,U32,const Range *,void **)>(readback,8)(readback,0,&readRange,&mapped))) goto cleanup;
        U32 mismatches=0;
        for(U32 y=0;y<64;++y) for(U32 x=0;x<64;++x) {
            auto *pixel=static_cast<const unsigned char *>(mapped)+y*256+x*4;
            U32 expected=73u|(((y*5+29)&255)<<8)|(((x*3+17)&255)<<16)|(255u<<24),actual=U32(pixel[0])|(U32(pixel[1])<<8)|(U32(pixel[2])<<16)|(U32(pixel[3])<<24);
            if(actual!=expected) {if(mismatches<8) {text("presentation.backbuffer_mismatch.x=");number(x);text(" y=");number(y);text(" expected=");hex(expected);text(" actual=");hex(actual);text("\n");}++mismatches;}
        }
        method<void (__stdcall *)(Com *,U32,const Range *)>(readback,9)(readback,0,&noWrite);text("presentation.backbuffer_pixels=4096 mismatches=");number(mismatches);text("\n");
        if(mismatches) goto cleanup;
        if(!need("presentation.DXGI_Present",method<HR (__stdcall *)(Com *,U32,U32)>(swap,8)(swap,1,0))) goto cleanup;
        if(!need("presentation.SignalAfterPresent",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,2)) || !wait_fence(fence,2)) goto cleanup;
        text("presentation.FenceAfterPresent.completed_value=");number(method<U64 (__stdcall *)(Com *)>(fence,8)(fence));text("\n");
        text("presentation.WINDOW_VISIBLE_INTERVAL=5 seconds; external compositor verification required\n");
        for(U32 i=0;i<500;++i) {pump_messages();Sleep(10);}
        pass=true;
    }
cleanup:
    {
        HR removed=method<HR (__stdcall *)(Com *)>(device,37)(device);hr("presentation.DeviceRemovedReason",removed);if(removed<0) pass=false;
    }
    text("presentation.gpu_api_result=");text(pass?"PASS\n":"FAIL\n");
    text("presentation.scope=standard Windows HWND+DXGI Present+4096 pixel readback; compositor image NOT verified by EXE; not game/conformance\n");
    release(list7);release(list);release(allocator);release(swap3);release(swap);release(backbuffer);release(readback);release(queue);release(fence);release(heap);release(pso);release(root);release(errors);release(blob);
    return pass;
}

extern "C" __declspec(noreturn) void mainCRTStartup() {
    text("D3D12_PRESENTATION_PROBE_VERSION=1\nABI=Windows x64; original DXIL VS+PS; standard user32+DXGI\n");
    Handle kernel32=LoadLibraryW(L"kernel32.dll");
    auto getModule=reinterpret_cast<Handle (__stdcall *)(const wchar_t *)>(GetProcAddress(kernel32,"GetModuleHandleW"));
    Handle instance=getModule?getModule(nullptr):nullptr;
    WClass cls={};cls.Size=sizeof(cls);cls.Proc=presentation_proc;cls.Instance=instance;cls.Name=L"D3D12IntelPresentationProbe";
    if(!RegisterClassExW(&cls)) {text("presentation.RegisterClass.failed_error=");number(GetLastError());text("\n");ExitProcess(10);}
    Handle hwnd=CreateWindowExW(0,cls.Name,L"D3D12 Intel presentation probe - standard DXGI Present",0x10cf0000,140,140,288,320,nullptr,nullptr,instance,nullptr);
    if(!hwnd) {text("presentation.CreateWindow.failed_error=");number(GetLastError());text("\n");ExitProcess(11);}
    ShowWindow(hwnd,5);UpdateWindow(hwnd);pump_messages();text("presentation.CreateWindow=OK\n");
    Handle dxgi=LoadLibraryW(L"dxgi.dll"),d3d12=LoadLibraryW(L"d3d12.dll");module("DXGI.module",dxgi);module("D3D12.module",d3d12);
    if(!dxgi || !d3d12) {DestroyWindow(hwnd);ExitProcess(2);}
    auto createFactory=reinterpret_cast<HR (__stdcall *)(U32,const Guid *,Com **)>(GetProcAddress(dxgi,"CreateDXGIFactory2"));
    auto createDevice=reinterpret_cast<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(GetProcAddress(d3d12,"D3D12CreateDevice"));
    if(!createFactory || !createDevice) {DestroyWindow(hwnd);ExitProcess(3);}
    Com *factory=nullptr;HR result=createFactory(0,&W_IID_Factory2,&factory);hr("presentation.CreateFactory2",result);if(result<0) {DestroyWindow(hwnd);ExitProcess(4);}
    bool pass=false;
    for(U32 i=0;i<16;++i) {
        Com *adapter=nullptr;result=method<HR (__stdcall *)(Com *,U32,Com **)>(factory,12)(factory,i,&adapter);if(result<0) break;
        AdapterDesc1 desc={};result=method<HR (__stdcall *)(Com *,AdapterDesc1 *)>(adapter,10)(adapter,&desc);if(result<0||desc.VendorId!=0x1002) {release(adapter);continue;}
        text("presentation.adapter=");wide(desc.Description);text("\n");Com *device=nullptr;result=createDevice(adapter,0xb000,&IID_Device,&device);hr("presentation.CreateDevice",result);
        if(result>=0&&device) {format_matrix(factory,device,hwnd);pass=window_presentation(d3d12,factory,device,hwnd);release(device);}release(adapter);break;
    }
    release(factory);DestroyWindow(hwnd);ExitProcess(pass?0:5);
}
