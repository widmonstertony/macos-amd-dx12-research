// Public Microsoft D3D12 API and ABI only; own texture/sampler/CBV shaders.
// Reuses validated root capability/graphics structures, not Apple internals.
#ifndef D3D12_GRAPHICS_BASE_INCLUDED
#define mainCRTStartup descriptor_unused_capability_entry
#include "../d3d12_probe.cpp"
#undef mainCRTStartup
#define D3D12_GRAPHICS_BASE_INCLUDED
#endif
#define mainCRTStartup descriptor_unused_graphics_entry
#include "../graphics-probe/d3d12_graphics_probe.cpp"
#undef mainCRTStartup
#include "descriptor_shaders_dxil.h"

struct DRange { U32 Type, Count, Register, Space, Offset; };
struct DTable { U32 Count; const DRange *Ranges; };
struct DRootParameter { U32 Type; union { DTable Table; U64 Reserved[2]; }; U32 Visibility; };
struct DGpuHandle { U64 Ptr; };
struct DCBV { U64 Address; U32 Bytes; };
struct DSRV { U32 Format, Dimension, Mapping; union { U64 Reserved[3]; struct { U32 Mip, Levels, Plane; float MinLOD; } Texture2D; }; };
struct DSampler { U32 Filter, U, V, W; float Bias; U32 Anisotropy, Comparison; float Border[4], MinLOD, MaxLOD; };
static_assert(sizeof(DRootParameter) == 32 && sizeof(DRange) == 20 && sizeof(DSRV) == 40 && sizeof(DCBV) == 16 && sizeof(DSampler) == 52,"descriptor ABI");

static U32 expected_pixel(U32 x,U32 y) {
  U32 u = (x+17)&63, v = (y*3+5)&63;
  U32 r = ((u*7+v*3+11)&255), g = ((u*5+v*9+19)&255), b = ((u^(v*13))+47)&255;
  return ((r+29)&255) | (((g+61)&255)<<8) | ((b^0x5a)<<16) | 0xff000000u;
}
static bool descriptor_smoke(Com *device,Handle d3d12) {
  Com *blob=nullptr,*errors=nullptr,*root=nullptr,*pso=nullptr,*rtvHeap=nullptr,*resourceHeap=nullptr,*samplerHeap=nullptr;
  Com *queue=nullptr,*allocator=nullptr,*list=nullptr,*list7=nullptr,*target=nullptr,*input=nullptr,*upload=nullptr,*constants=nullptr,*readback=nullptr,*fence=nullptr;
  bool pass=false;
  auto need=[](const char *name,HR value) { hr(name,value); return value>=0; };
  {
    auto serialize=reinterpret_cast<HR (__stdcall *)(const GRootSignatureDesc *,U32,Com **,Com **)>(GetProcAddress(d3d12,"D3D12SerializeRootSignature"));
    if (!serialize) { text("descriptor.error=no serializer\n"); goto cleanup; }
    DRange resources[2]={{0,1,0,0,0},{2,1,0,0,1}}, samplers[1]={{3,1,0,0,0}};
    DRootParameter parameters[2]={}; parameters[0].Table={2,resources}; parameters[1].Table={1,samplers};
    parameters[0].Visibility=parameters[1].Visibility=5;
    GRootSignatureDesc rootDesc={2,parameters,0,nullptr,0};
    if (!need("descriptor.SerializeRootSignature",serialize(&rootDesc,1,&blob,&errors))) { if(errors) text(static_cast<const char *>(method<void *(__stdcall *)(Com *)>(errors,3)(errors))); goto cleanup; }
    void *rootData=method<void *(__stdcall *)(Com *)>(blob,3)(blob); Size rootBytes=method<Size (__stdcall *)(Com *)>(blob,4)(blob);
    if (!need("descriptor.CreateRootSignature",method<HR (__stdcall *)(Com *,U32,const void *,Size,const Guid *,Com **)>(device,16)(device,0,rootData,rootBytes,&G_IID_Root,&root))) goto cleanup;
    GGraphicsPipeline pipeline={}; pipeline.Root=root; pipeline.VS={descriptor_vs_dxil,sizeof(descriptor_vs_dxil)}; pipeline.PS={descriptor_ps_dxil,sizeof(descriptor_ps_dxil)};
    for (U32 i=0;i<8;++i) pipeline.Blend.Targets[i]={0,0,2,1,1,2,1,1,5,15};
    pipeline.SampleMask=0xffffffffu; pipeline.Rasterizer={3,1,0,0,0,0,1,0,0,0,0};
    pipeline.DepthStencil.DepthFunc=8; pipeline.DepthStencil.Front=pipeline.DepthStencil.Back={1,1,1,8};
    pipeline.TopologyType=3; pipeline.NumTargets=1; pipeline.TargetFormats[0]=28; pipeline.SampleCount=1;
    if (!need("descriptor.CreateGraphicsPipelineState",method<HR (__stdcall *)(Com *,const GGraphicsPipeline *,const Guid *,Com **)>(device,10)(device,&pipeline,&G_IID_PSO,&pso))) goto cleanup;
    auto createHeap=method<HR (__stdcall *)(Com *,const GHeapDesc *,const Guid *,Com **)>(device,14);
    GHeapDesc rtvDesc={2,1,0,0}, resourceDesc={0,2,1,0}, samplerDesc={1,1,1,0};
    if (!need("descriptor.CreateRTVHeap",createHeap(device,&rtvDesc,&G_IID_DescriptorHeap,&rtvHeap)) ||
        !need("descriptor.CreateShaderVisibleResourceHeap",createHeap(device,&resourceDesc,&G_IID_DescriptorHeap,&resourceHeap)) ||
        !need("descriptor.CreateShaderVisibleSamplerHeap",createHeap(device,&samplerDesc,&G_IID_DescriptorHeap,&samplerHeap))) goto cleanup;
    GCpuHandle rtv={},resourceCPU={},samplerCPU={}; DGpuHandle resourceGPU={},samplerGPU={};
    method<GCpuHandle *(__stdcall *)(Com *,GCpuHandle *)>(rtvHeap,9)(rtvHeap,&rtv);
    method<GCpuHandle *(__stdcall *)(Com *,GCpuHandle *)>(resourceHeap,9)(resourceHeap,&resourceCPU);
    method<GCpuHandle *(__stdcall *)(Com *,GCpuHandle *)>(samplerHeap,9)(samplerHeap,&samplerCPU);
    method<DGpuHandle *(__stdcall *)(Com *,DGpuHandle *)>(resourceHeap,10)(resourceHeap,&resourceGPU);
    method<DGpuHandle *(__stdcall *)(Com *,DGpuHandle *)>(samplerHeap,10)(samplerHeap,&samplerGPU);
    U32 increment=method<U32 (__stdcall *)(Com *,U32)>(device,15)(device,0);
    text("descriptor.resource_increment="); number(increment); text(" shader_visible_GPU_handles_nonzero="); number(resourceGPU.Ptr && samplerGPU.Ptr); text("\n");
    if (!rtv.Ptr || !resourceCPU.Ptr || !samplerCPU.Ptr || !resourceGPU.Ptr || !samplerGPU.Ptr || !increment) goto cleanup;
    QueueDesc queueDesc={0,0,0,0};
    if (!need("descriptor.CreateQueue",method<HR (__stdcall *)(Com *,const QueueDesc *,const Guid *,Com **)>(device,8)(device,&queueDesc,&IID_Queue,&queue)) ||
        !need("descriptor.CreateAllocator",method<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(device,9)(device,0,&IID_Allocator,&allocator)) ||
        !need("descriptor.CreateList",method<HR (__stdcall *)(Com *,U32,U32,Com *,Com *,const Guid *,Com **)>(device,12)(device,0,0,allocator,pso,&IID_CommandList,&list)) ||
        !need("descriptor.QueryList7",method<HR (__stdcall *)(Com *,const Guid *,Com **)>(list,0)(list,&IID_CommandList7,&list7))) goto cleanup;
    auto createResource=method<HR (__stdcall *)(Com *,const HeapProperties *,U32,const ResourceDesc *,U32,const void *,const Guid *,Com **)>(device,27);
    HeapProperties gpuHeap={1,0,0,1,1}, uploadHeap={2,0,0,1,1}, readHeap={3,0,0,1,1};
    ResourceDesc targetDesc={3,0,64,64,1,1,28,1,0,0,1}, inputDesc=targetDesc; inputDesc.Flags=0;
    ResourceDesc largeBuffer={1,0,16384,1,1,1,0,1,0,1,0}, constantBuffer=largeBuffer; constantBuffer.Width=256;
    if (!need("descriptor.CreateTarget",createResource(device,&gpuHeap,0,&targetDesc,0,nullptr,&IID_Resource,&target)) ||
        !need("descriptor.CreateSRVTexture",createResource(device,&gpuHeap,0,&inputDesc,0,nullptr,&IID_Resource,&input)) ||
        !need("descriptor.CreateTextureUpload",createResource(device,&uploadHeap,0,&largeBuffer,0xac3,nullptr,&IID_Resource,&upload)) ||
        !need("descriptor.CreateConstantUpload",createResource(device,&uploadHeap,0,&constantBuffer,0xac3,nullptr,&IID_Resource,&constants)) ||
        !need("descriptor.CreateReadback",createResource(device,&readHeap,0,&largeBuffer,0x400,nullptr,&IID_Resource,&readback))) goto cleanup;
    method<void (__stdcall *)(Com *,Com *,const void *,GCpuHandle)>(device,20)(device,target,nullptr,rtv);
    DSRV srv={}; srv.Format=28; srv.Dimension=4; srv.Mapping=5768; srv.Texture2D.Levels=1;
    method<void (__stdcall *)(Com *,Com *,const DSRV *,GCpuHandle)>(device,18)(device,input,&srv,resourceCPU);
    U64 constantAddress=method<U64 (__stdcall *)(Com *)>(constants,11)(constants);
    DCBV cbv={constantAddress,256}; GCpuHandle cbvCPU={resourceCPU.Ptr+increment};
    method<void (__stdcall *)(Com *,const DCBV *,GCpuHandle)>(device,17)(device,&cbv,cbvCPU);
    DSampler sampler={0,3,3,3,0,1,8,{0,0,0,0},0,0};
    method<void (__stdcall *)(Com *,const DSampler *,GCpuHandle)>(device,22)(device,&sampler,samplerCPU);
    text("descriptor.CreatedViews=SRV(t0),CBV(b0),point-clampSampler(s0); no root GPUVA binding\n");
    GPlacedFootprint footprint={}; U32 rows=0; U64 rowBytes=0,totalBytes=0;
    method<void (__stdcall *)(Com *,const ResourceDesc *,U32,U32,U64,GPlacedFootprint *,U32 *,U64 *,U64 *)>(device,38)(device,&inputDesc,0,1,0,&footprint,&rows,&rowBytes,&totalBytes);
    if (footprint.Footprint.Pitch!=256 || rows!=64 || rowBytes!=256 || totalBytes>16384) goto cleanup;
    void *mapped=nullptr; Range noRead={0,0}, written={0,16384};
    if (!need("descriptor.MapTextureUpload",method<HR (__stdcall *)(Com *,U32,const Range *,void **)>(upload,8)(upload,0,&noRead,&mapped))) goto cleanup;
    for (U32 y=0;y<64;++y) for (U32 x=0;x<64;++x) {
      unsigned char *pixel=static_cast<unsigned char *>(mapped)+y*256+x*4;
      pixel[0]=static_cast<unsigned char>((x*7+y*3+11)&255); pixel[1]=static_cast<unsigned char>((x*5+y*9+19)&255);
      pixel[2]=static_cast<unsigned char>(((x^(y*13))+47)&255); pixel[3]=255;
    }
    method<void (__stdcall *)(Com *,U32,const Range *)>(upload,9)(upload,0,&written);
    if (!need("descriptor.MapConstants",method<HR (__stdcall *)(Com *,U32,const Range *,void **)>(constants,8)(constants,0,&noRead,&mapped))) goto cleanup;
    static_cast<U32 *>(mapped)[0]=29; static_cast<U32 *>(mapped)[1]=61; static_cast<U32 *>(mapped)[2]=0x5a; static_cast<U32 *>(mapped)[3]=17;
    Range constantsWritten={0,16}; method<void (__stdcall *)(Com *,U32,const Range *)>(constants,9)(constants,0,&constantsWritten);
    if (!need("descriptor.CreateFence",method<HR (__stdcall *)(Com *,U64,U32,const Guid *,Com **)>(device,36)(device,0,0,&IID_Fence,&fence))) goto cleanup;
    GTextureBarrier uploadPrepare={0,0x200,0x80000000u,0x400,0,8,input,{0,1,0,1,0,1},0}; GBarrierGroup uploadGroup={1,1,&uploadPrepare};
    method<void (__stdcall *)(Com *,U32,const GBarrierGroup *)>(list7,80)(list7,1,&uploadGroup);
    GCopyLocation uploadLocation={}; uploadLocation.Resource=upload; uploadLocation.Type=1; uploadLocation.Placed=footprint;
    GCopyLocation inputLocation={}; inputLocation.Resource=input; inputLocation.Type=0;
    method<void (__stdcall *)(Com *,const GCopyLocation *,U32,U32,U32,const GCopyLocation *,const void *)>(list,16)(list,&inputLocation,0,0,0,&uploadLocation,nullptr);
    GTextureBarrier drawBarriers[2]={{0x200,0x10,0x400,0x80,8,6,input,{0,1,0,1,0,1},0},{0,0x40,0x80000000u,8,0,2,target,{0,1,0,1,0,1},0}};
    GBarrierGroup drawGroup={1,2,drawBarriers}; method<void (__stdcall *)(Com *,U32,const GBarrierGroup *)>(list7,80)(list7,1,&drawGroup);
    method<void (__stdcall *)(Com *,Com *)>(list,30)(list,root); Com *heaps[2]={resourceHeap,samplerHeap};
    method<void (__stdcall *)(Com *,U32,Com *const *)>(list,28)(list,2,heaps);
    method<void (__stdcall *)(Com *,U32,DGpuHandle)>(list,32)(list,0,resourceGPU);
    method<void (__stdcall *)(Com *,U32,DGpuHandle)>(list,32)(list,1,samplerGPU);
    GViewport viewport={0,0,64,64,0,1}; GRect rect={0,0,64,64};
    method<void (__stdcall *)(Com *,U32,const GViewport *)>(list,21)(list,1,&viewport); method<void (__stdcall *)(Com *,U32,const GRect *)>(list,22)(list,1,&rect);
    method<void (__stdcall *)(Com *,U32)>(list,20)(list,4); method<void (__stdcall *)(Com *,U32,const GCpuHandle *,I32,const GCpuHandle *)>(list,46)(list,1,&rtv,0,nullptr);
    const float clear[4]={0,0,0,0}; method<void (__stdcall *)(Com *,GCpuHandle,const float *,U32,const GRect *)>(list,48)(list,rtv,clear,0,nullptr);
    method<void (__stdcall *)(Com *,U32,U32,U32,U32)>(list,12)(list,3,1,0,0);
    GTextureBarrier finish={0x40,0x200,8,0x800,2,7,target,{0,1,0,1,0,1},0}; GBarrierGroup finishGroup={1,1,&finish};
    method<void (__stdcall *)(Com *,U32,const GBarrierGroup *)>(list7,80)(list7,1,&finishGroup);
    GCopyLocation targetLocation={}; targetLocation.Resource=target; GCopyLocation readLocation={}; readLocation.Resource=readback; readLocation.Type=1; readLocation.Placed=footprint;
    method<void (__stdcall *)(Com *,const GCopyLocation *,U32,U32,U32,const GCopyLocation *,const void *)>(list,16)(list,&readLocation,0,0,0,&targetLocation,nullptr);
    if (!need("descriptor.Close",method<HR (__stdcall *)(Com *)>(list,9)(list))) goto cleanup;
    method<void (__stdcall *)(Com *,U32,Com *const *)>(queue,10)(queue,1,&list);
    if (!need("descriptor.Signal",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,1))) goto cleanup;
    bool completed=false; for (U32 retry=0;retry<500;++retry) { U64 value=method<U64 (__stdcall *)(Com *)>(fence,8)(fence); if (value==~U64(0)) goto cleanup; if (value>=1) { completed=true; break; } Sleep(10); }
    if (!completed) { text("descriptor.error=fence timeout\n"); goto cleanup; }
    Range readRange={0,16384},noWrite={0,0}; if (!need("descriptor.MapReadback",method<HR (__stdcall *)(Com *,U32,const Range *,void **)>(readback,8)(readback,0,&readRange,&mapped))) goto cleanup;
    U32 mismatches=0; for (U32 y=0;y<64;++y) for (U32 x=0;x<64;++x) {
      const auto *pixel=static_cast<const unsigned char *>(mapped)+y*256+x*4;
      U32 actual=U32(pixel[0])|(U32(pixel[1])<<8)|(U32(pixel[2])<<16)|(U32(pixel[3])<<24),expected=expected_pixel(x,y);
      if (((x==0||x==63)&&(y==0||y==63)) || (x==32&&y==32) || (actual!=expected&&mismatches<8)) { text("descriptor.pixel.x="); number(x); text(" y="); number(y); text(" expected="); hex(expected); text(" actual="); hex(actual); text("\n"); }
      if (actual!=expected) ++mismatches;
    }
    method<void (__stdcall *)(Com *,U32,const Range *)>(readback,9)(readback,0,&noWrite);
    text("descriptor.compared_pixels=4096 mismatches="); number(mismatches); text("\n"); pass=mismatches==0;
  }
cleanup:
  hr("descriptor.DeviceRemovedReason",method<HR (__stdcall *)(Com *)>(device,37)(device));
  text("descriptor.result="); text(pass?"PASS\n":"FAIL\n");
  text("descriptor.scope=actual SRV texture upload, shader-visible CBV/SRV and sampler tables, SM6.0 VS/PS, 4096 sampled-and-CBV-modified pixels, Enhanced Texture Barriers, CPU readback; Apple7 classification simulated; managed and public-pass adapters; not game/conformance\n");
  release(list7); release(list); release(allocator); release(queue); release(fence); release(target); release(input); release(upload); release(constants); release(readback);
  release(rtvHeap); release(resourceHeap); release(samplerHeap); release(pso); release(root); release(errors); release(blob); return pass;
}
extern "C" __declspec(noreturn) void mainCRTStartup() {
  text("D3D12_DESCRIPTOR_PROBE_VERSION=1\n"); Handle dxgi=LoadLibraryW(L"dxgi.dll"),d3d12=LoadLibraryW(L"d3d12.dll");
  auto createFactory=reinterpret_cast<HR (__stdcall *)(const Guid *,Com **)>(GetProcAddress(dxgi,"CreateDXGIFactory1"));
  auto createDevice=reinterpret_cast<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(GetProcAddress(d3d12,"D3D12CreateDevice"));
  if (!dxgi||!d3d12||!createFactory||!createDevice) ExitProcess(2);
  Com *factory=nullptr; if (createFactory(&IID_Factory1,&factory)<0) ExitProcess(3);
  U32 tested=0,passed=0;
  for (U32 index=0;index<16;++index) {
    Com *adapter=nullptr; HR result=method<HR (__stdcall *)(Com *,U32,Com **)>(factory,12)(factory,index,&adapter); if (result<0) break;
    AdapterDesc1 desc={}; result=method<HR (__stdcall *)(Com *,AdapterDesc1 *)>(adapter,10)(adapter,&desc);
    if (result<0||desc.VendorId!=0x1002) { release(adapter); continue; }
    text("descriptor.realAdapter="); wide(desc.Description); text("\n"); Com *device=nullptr;
    result=createDevice(adapter,0xb000,&IID_Device,&device); hr("descriptor.D3D12CreateDevice",result);
    if (result>=0&&device) { ++tested; if (descriptor_smoke(device,d3d12)) ++passed; release(device); } release(adapter);
  }
  release(factory); text("descriptor.amd_tested="); number(tested); text(" passed="); number(passed); text("\n"); ExitProcess(tested&&passed==tested?0:5);
}
