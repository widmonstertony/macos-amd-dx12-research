// Native WSI interoperability probe. Only the MIT UTM GFXT host service TUs
// are linked: no UTM COM hooks, private D3DMetal flags or Metal swizzles.
// GFXT is a third-party reconstructed ABI, not an Apple-documented native API.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <ImageIO/ImageIO.h>
#include <atomic>
#include <string>
#include "d3dmetal-native-source/src/dmn_gfxt.h"
#include "d3dmetal-native-source/src/dmn_private.h"
#include "d3dmetal-native-source/src/dmn_window_internal.h"

// Cocoa's legacy MacTypes already defines Size, Handle and wide. Rename only
// the independent handwritten probe identifiers; do not touch platform types.
#define Size PresentationSize
#define Handle PresentationHandle
#define wide presentation_wide

#define mainCRTStartup presentation_unused_capability_entry
#define main presentation_unused_capability_host
#include "../direct_d3d12_probe.mm"
#undef main
#undef mainCRTStartup
#define D3D12_GRAPHICS_BASE_INCLUDED
#define mainCRTStartup presentation_unused_graphics_entry
#include "../graphics-probe/d3d12_graphics_probe.cpp"
#undef mainCRTStartup

// The service subset needs only this path getter. The full initializer that
// touches private flags and installs hooks is intentionally not linked.
static std::string presentation_resources;
const std::string& dmn_framework_resources_dir() { return presentation_resources; }

static std::atomic<unsigned int> acquired_drawables{0}, presented_drawables{0};
static std::atomic<double> presented_time{0.0};
@interface ProbeMetalLayer : CAMetalLayer {
    id<CAMetalDrawable> captured_;
}
- (id<CAMetalDrawable>)copyCapturedDrawable;
@end
@implementation ProbeMetalLayer
- (id<CAMetalDrawable>)nextDrawable {
    id<CAMetalDrawable> drawable = [super nextDrawable];
    if (drawable) {
        @synchronized(self) { [captured_ release]; captured_ = [drawable retain]; }
        acquired_drawables.fetch_add(1);
        // Observe the compositor's real presented callback; never present here.
        [drawable addPresentedHandler:^(id<MTLDrawable> displayed) {
            presented_time.store(displayed.presentedTime);
            presented_drawables.fetch_add(1);
        }];
    }
    return drawable;
}
- (id<CAMetalDrawable>)copyCapturedDrawable { @synchronized(self) { return [captured_ retain]; } }
- (void)dealloc { [captured_ release]; [super dealloc]; }
@end

@interface ProbeSurfaceView : NSView
@end
@implementation ProbeSurfaceView
- (BOOL)isOpaque { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer *)makeBackingLayer { return [ProbeMetalLayer layer]; }
- (void)updateLayer {}
@end

static void pump_cocoa() {
    @autoreleasepool {
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
    [NSApp updateWindows];
    [CATransaction flush];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    }
}

static bool capture_own_window_control(NSWindow *window,bool gradient=false) {
    // Legacy public CoreGraphics API, resolved dynamically for diagnostics on
    // the installed macOS 26 runtime. Scope is EXACTLY our own window ID; no
    // capture-access request, other app/window capture or global setting.
    auto capture=reinterpret_cast<CGImageRef (*)(CGRect,CGWindowListOption,CGWindowID,CGWindowImageOption)>(dlsym(RTLD_DEFAULT,"CGWindowListCreateImage"));
    if(!capture) {text("presentation.WINDOW_CAPTURE=public legacy API unavailable\n");return false;}
    CGImageRef image=capture(CGRectNull,kCGWindowListOptionIncludingWindow,(CGWindowID)window.windowNumber,kCGWindowImageBoundsIgnoreFraming|kCGWindowImageNominalResolution);
    if(!image) {text("presentation.WINDOW_CAPTURE=no image (permission/API limitation); no permission requested\n");return false;}
    size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image);auto *pixels=static_cast<unsigned char *>(calloc(width*height,4));
    CGColorSpaceRef colors=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(pixels,width,height,8,width*4,colors,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    if(!context) {CGColorSpaceRelease(colors);CGImageRelease(image);free(pixels);return false;}
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
    unsigned char *center=pixels+(height/2)*width*4+(width/2)*4;
    fprintf(stdout,"presentation.WINDOW_CAPTURE.width=%zu height=%zu center_RGBA=%u,%u,%u,%u\n",width,height,center[0],center[1],center[2],center[3]);fflush(stdout);
    // Pure-native baseline's constant color. Allow display color-conversion
    // error; this is a compositor-image check, not the byte-exact GPU check.
    bool nativeColor=center[0]>=20 && center[0]<=35 && center[1]>=65 && center[1]<=90 && center[2]>=165 && center[2]<=195 && center[3]>=250;
    if(gradient) {
        size_t contentHeight=(size_t)(window.contentView.bounds.size.height*width/window.contentView.bounds.size.width+0.5);
        size_t contentTop=height>contentHeight?height-contentHeight:0;
        U32 matches[2]={0,0};
        for(U32 sy=8;sy<64;sy+=16) for(U32 sx=8;sx<64;sx+=16) {
            size_t px=(size_t)((sx+0.5)*width/64),py=(size_t)(contentTop+(sy+0.5)*contentHeight/64);
            if(px>=width||py>=height) continue;
            U32 expected[3]={(sx*3+17)&255,(sy*5+29)&255,73};
            for(U32 orientation=0;orientation<2;++orientation) {
                size_t row=orientation?height-1-py:py;const unsigned char *sample=pixels+(row*width+px)*4;
                bool near=sample[3]>=250;
                for(U32 c=0;c<3;++c) {I32 delta=I32(sample[c])-I32(expected[c]);if(delta < -12 || delta > 12) near=false;}
                if(near) ++matches[orientation];
            }
        }
        fprintf(stdout,"presentation.WINDOW_CAPTURE.gradient_samples=16 matching_top_origin=%u matching_bottom_origin=%u\n",matches[0],matches[1]);fflush(stdout);
        nativeColor=matches[0]==16||matches[1]==16;
    }
    if(const char *output=getenv("PRESENTATION_CAPTURE_PATH")) {
        CFURLRef url=CFURLCreateFromFileSystemRepresentation(nullptr,reinterpret_cast<const UInt8 *>(output),strlen(output),false);
        CGImageDestinationRef destination=CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,nullptr);
        if(destination) {CGImageDestinationAddImage(destination,image,nullptr);text(CGImageDestinationFinalize(destination)?"presentation.WINDOW_CAPTURE.png_saved=1\n":"presentation.WINDOW_CAPTURE.png_saved=0\n");CFRelease(destination);}CFRelease(url);
    }
    CGContextRelease(context);CGColorSpaceRelease(colors);CGImageRelease(image);free(pixels);return nativeColor;
}

// Separate native-only baseline: no D3DMetal or GFXT initialization. It tests
// whether this exact Cocoa/Metal layer setup can confirm physical presentation.
static bool pure_metal_control(ProbeMetalLayer *layer,NSWindow *window) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=NO;
    id<CAMetalDrawable> drawable=[layer nextDrawable];
    if(!drawable) {text("presentation.PURE_METAL_CONTROL=no drawable\n");[device release];return false;}
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> buffer=[queue commandBuffer];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0.1,0.3,0.7,1);
    id<MTLRenderCommandEncoder> encoder=[buffer renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];
    [buffer presentDrawable:drawable];[buffer commit];[buffer waitUntilCompleted];
    for(U32 i=0;i<300 && !presented_drawables.load();++i) {pump_cocoa();Sleep(10);}
    fprintf(stdout,"presentation.PURE_METAL_CONTROL.command_status=%lu callbacks=%u time=%.9f\n",(unsigned long)buffer.status,presented_drawables.load(),presented_time.load());fflush(stdout);
    for(U32 i=0;i<20;++i) {pump_cocoa();Sleep(10);}
    bool screenColor=capture_own_window_control(window);
    fprintf(stdout,"presentation.PURE_METAL_CONTROL.current_drawable_time=%.9f compositor_image_expected_color=%d\n",drawable.presentedTime,screenColor);fflush(stdout);
    bool ok=buffer.status==MTLCommandBufferStatusCompleted && presented_drawables.load() && screenColor;
    [queue release];[device release];return ok;
}

struct PSwapChainDesc { U32 Width, Height, Format; I32 Stereo; U32 SampleCount, SampleQuality, Usage, BufferCount, Scaling, SwapEffect, AlphaMode, Flags; };
static_assert(sizeof(PSwapChainDesc) == 48, "DXGI_SWAP_CHAIN_DESC1 ABI");
static const Guid P_IID_Factory2 = {0x50c83a1c,0xe072,0x4c48,{0x87,0xb0,0x36,0x30,0xfa,0x36,0xa6,0xd0}};
static const Guid P_IID_SwapChain3 = {0x94d99bdb,0xf1f8,0x4ab0,{0xb2,0x36,0x7d,0xa0,0x17,0x0e,0xda,0xb1}};

static bool presentation_smoke(Com *factory, Com *device, void *hwnd, ProbeMetalLayer *layer,NSWindow *window) {
    Com *blob = nullptr, *errors = nullptr, *root = nullptr, *pso = nullptr, *heap = nullptr;
    Com *queue = nullptr, *allocator = nullptr, *list = nullptr, *list7 = nullptr, *swap = nullptr, *swap3 = nullptr, *backbuffer = nullptr, *readback = nullptr, *fence = nullptr;
    bool pass = false;
    auto need = [](const char *name, HR value) { hr(name, value); return value >= 0; };
    {
        auto serialize = reinterpret_cast<HR (__stdcall *)(const GRootSignatureDesc *, U32, Com **, Com **)>(GetProcAddress(native_module, "D3D12SerializeRootSignature"));
        GRootSignatureDesc desc = {};
        if (!serialize || !need("presentation.SerializeEmptyRoot", serialize(&desc, 1, &blob, &errors))) goto cleanup;
        void *data = method<void *(__stdcall *)(Com *)>(blob, 3)(blob); Size bytes = method<Size (__stdcall *)(Com *)>(blob, 4)(blob);
        if (!need("presentation.CreateRootSignature", method<HR (__stdcall *)(Com *, U32, const void *, Size, const Guid *, Com **)>(device, 16)(device, 0, data, bytes, &G_IID_Root, &root))) goto cleanup;
        GGraphicsPipeline pipeline = {};
        pipeline.Root = root; pipeline.VS = {graphics_vs_dxil, sizeof(graphics_vs_dxil)}; pipeline.PS = {graphics_ps_dxil, sizeof(graphics_ps_dxil)};
        for (U32 i = 0; i < 8; ++i) pipeline.Blend.Targets[i] = {0,0,2,1,1,2,1,1,5,15};
        pipeline.SampleMask = ~U32(0); pipeline.Rasterizer = {3,1,0,0,0,0,1,0,0,0,0}; pipeline.DepthStencil.DepthFunc = 8;
        pipeline.DepthStencil.Front = pipeline.DepthStencil.Back = {1,1,1,8}; pipeline.TopologyType = 3;
        pipeline.NumTargets = 1; pipeline.TargetFormats[0] = 87; pipeline.SampleCount = 1; // BGRA8_UNORM.
        if (!need("presentation.CreateGraphicsPSO", method<HR (__stdcall *)(Com *, const GGraphicsPipeline *, const Guid *, Com **)>(device, 10)(device, &pipeline, &G_IID_PSO, &pso))) goto cleanup;
        QueueDesc queueDesc = {0,0,0,0};
        if (!need("presentation.CreateQueue", method<HR (__stdcall *)(Com *, const QueueDesc *, const Guid *, Com **)>(device, 8)(device, &queueDesc, &IID_Queue, &queue))) goto cleanup;
        PSwapChainDesc swapDesc = {64,64,87,0,1,0,0x20,2,0,4,3,0}; // RT_OUTPUT, FLIP_DISCARD, IGNORE alpha.
        if (!need("presentation.CreateSwapChainForHwnd", method<HR (__stdcall *)(Com *, Com *, void *, const PSwapChainDesc *, const void *, Com *, Com **)>(factory, 15)(factory, queue, hwnd, &swapDesc, nullptr, nullptr, &swap))) goto cleanup;
        if (!need("presentation.QuerySwapChain3", method<HR (__stdcall *)(Com *, const Guid *, Com **)>(swap, 0)(swap, &P_IID_SwapChain3, &swap3))) goto cleanup;
        U32 index = method<U32 (__stdcall *)(Com *)>(swap3, 36)(swap3);
        text("presentation.CurrentBackBufferIndex="); number(index); text("\n");
        if (!need("presentation.GetBuffer", method<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(swap, 9)(swap, index, &IID_Resource, &backbuffer))) goto cleanup;
        GHeapDesc heapDesc = {2,1,0,0};
        if (!need("presentation.CreateRTVHeap", method<HR (__stdcall *)(Com *, const GHeapDesc *, const Guid *, Com **)>(device, 14)(device, &heapDesc, &G_IID_DescriptorHeap, &heap))) goto cleanup;
        GCpuHandle rtv = {}; method<GCpuHandle *(__stdcall *)(Com *, GCpuHandle *)>(heap, 9)(heap, &rtv);
        if (!rtv.Ptr) { text("presentation.error=zero RTV handle\n"); goto cleanup; }
        method<void (__stdcall *)(Com *, Com *, const void *, GCpuHandle)>(device, 20)(device, backbuffer, nullptr, rtv);
        if (!need("presentation.CreateAllocator", method<HR (__stdcall *)(Com *, U32, const Guid *, Com **)>(device, 9)(device, 0, &IID_Allocator, &allocator))) goto cleanup;
        if (!need("presentation.CreateList", method<HR (__stdcall *)(Com *, U32, U32, Com *, Com *, const Guid *, Com **)>(device, 12)(device, 0, 0, allocator, pso, &IID_CommandList, &list))) goto cleanup;
        if (!need("presentation.QueryList7", method<HR (__stdcall *)(Com *, const Guid *, Com **)>(list, 0)(list, &IID_CommandList7, &list7))) goto cleanup;
        HeapProperties readHeap = {3,0,0,1,1}; ResourceDesc readDesc = {1,0,16384,1,1,1,0,1,0,1,0};
        if (!need("presentation.CreateReadback", method<HR (__stdcall *)(Com *, const HeapProperties *, U32, const ResourceDesc *, U32, const void *, const Guid *, Com **)>(device, 27)(device, &readHeap, 0, &readDesc, 0x400, nullptr, &IID_Resource, &readback))) goto cleanup;
        if (!need("presentation.CreateFence", method<HR (__stdcall *)(Com *, U64, U32, const Guid *, Com **)>(device, 36)(device, 0,0,&IID_Fence,&fence))) goto cleanup;
        GTextureBarrier prepare = {0,0x40,0x80000000u,8,0,2,backbuffer,{0,1,0,1,0,1},0}; GBarrierGroup group = {1,1,&prepare};
        auto barrier = method<void (__stdcall *)(Com *, U32, const GBarrierGroup *)>(list7,80);
        barrier(list7,1,&group);
        method<void (__stdcall *)(Com *, Com *)>(list,30)(list,root);
        GViewport viewport = {0,0,64,64,0,1}; GRect rect = {0,0,64,64};
        method<void (__stdcall *)(Com *, U32, const GViewport *)>(list,21)(list,1,&viewport);
        method<void (__stdcall *)(Com *, U32, const GRect *)>(list,22)(list,1,&rect);
        method<void (__stdcall *)(Com *, U32)>(list,20)(list,4);
        method<void (__stdcall *)(Com *, U32, const GCpuHandle *, I32, const GCpuHandle *)>(list,46)(list,1,&rtv,0,nullptr);
        method<void (__stdcall *)(Com *, U32,U32,U32,U32)>(list,12)(list,3,1,0,0);
        text("presentation.DrawInstanced=fullscreen triangle XY gradient\n");
        GTextureBarrier toCopy = {0x40,0x200,8,0x800,2,7,backbuffer,{0,1,0,1,0,1},0}; group.Textures = &toCopy; barrier(list7,1,&group);
        GCopyLocation source = {}; source.Resource = backbuffer;
        GCopyLocation dest = {}; dest.Resource = readback; dest.Type = 1; dest.Placed = {0,{87,64,64,1,256}};
        method<void (__stdcall *)(Com *, const GCopyLocation *, U32,U32,U32,const GCopyLocation *,const void *)>(list,16)(list,&dest,0,0,0,&source,nullptr);
        GTextureBarrier toPresent = {0x200,0,0x800,0,7,0,backbuffer,{0,1,0,1,0,1},0}; group.Textures = &toPresent; barrier(list7,1,&group);
        if (!need("presentation.Close",method<HR (__stdcall *)(Com *)>(list,9)(list))) goto cleanup;
        method<void (__stdcall *)(Com *, U32,Com *const *)>(queue,10)(queue,1,&list);
        if (!need("presentation.SignalBeforePresent",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,1))) goto cleanup;
        bool completed = false;
        for(U32 i=0;i<500;++i) { U64 value=method<U64 (__stdcall *)(Com *)>(fence,8)(fence); if(value==~U64(0)) goto cleanup; if(value>=1) {completed=true;break;} pump_cocoa(); Sleep(10); }
        if(!completed) {text("presentation.error=render fence timeout\n");goto cleanup;}
        Range readRange={0,16384},noWrite={0,0};void *mapped=nullptr;
        if(!need("presentation.MapBackBufferReadback",method<HR (__stdcall *)(Com *,U32,const Range *,void **)>(readback,8)(readback,0,&readRange,&mapped))) goto cleanup;
        U32 backMismatches=0;
        for(U32 y=0;y<64;++y) for(U32 x=0;x<64;++x) {
            auto *pixel=static_cast<const unsigned char *>(mapped)+y*256+x*4;
            if(pixel[0]!=73 || pixel[1]!=((y*5+29)&255) || pixel[2]!=((x*3+17)&255) || pixel[3]!=255) ++backMismatches;
        }
        method<void (__stdcall *)(Com *,U32,const Range *)>(readback,9)(readback,0,&noWrite);
        text("presentation.backbuffer_pixels=4096 mismatches=");number(backMismatches);text("\n");
        if(backMismatches) goto cleanup;
        if(!need("presentation.DXGI_Present",method<HR (__stdcall *)(Com *,U32,U32)>(swap,8)(swap,1,0))) goto cleanup;
        // Standard D3D12 frame loops signal the queue after Present. This also
        // supplies an explicit completion boundary for its deferred GPU work.
        if(!need("presentation.SignalAfterPresent",method<HR (__stdcall *)(Com *,Com *,U64)>(queue,14)(queue,fence,2))) goto cleanup;
        for(U32 i=0;i<500 && !presented_drawables.load();++i) {pump_cocoa();Sleep(10);}
        text("presentation.actual_drawables_acquired=");number(acquired_drawables.load());text(" presented_callbacks=");number(presented_drawables.load());text("\n");
        fprintf(stdout,"presentation.compositor_presented_time=%.9f\n",presented_time.load());fflush(stdout);
        U64 afterPresentFence=method<U64 (__stdcall *)(Com *)>(fence,8)(fence);
        text("presentation.FenceAfterPresent.completed_value=");number(afterPresentFence);text("\n");
        // presentedTime is 0 even for this machine's genuine native baseline
        // with a verified blue compositor image. Require image+pixels instead.
        bool callbackObserved=presented_drawables.load()>0;
        if(!callbackObserved) text("presentation.diagnostic=presented callback not observed; compositor image will independently verify standard Present\n");
        id<CAMetalDrawable> drawable=[layer copyCapturedDrawable];
        if(!drawable) {text("presentation.error=no captured drawable\n");goto cleanup;}
        id<MTLTexture> actualTexture=drawable.texture;
        text("presentation.actual_drawable.width=");number(actualTexture.width);text(" height=");number(actualTexture.height);text(" pixelFormat=");number(actualTexture.pixelFormat);text("\n");
        if(actualTexture.width!=64 || actualTexture.height!=64 || actualTexture.pixelFormat!=MTLPixelFormatBGRA8Unorm) { [drawable release]; goto cleanup; }
        id<MTLDevice> actualDevice=actualTexture.device;
        id<MTLCommandQueue> actualQueue=[actualDevice newCommandQueue];
        id<MTLBuffer> actualReadback=[actualDevice newBufferWithLength:16384 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command=[actualQueue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
        [blit copyFromTexture:actualTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,64,1) toBuffer:actualReadback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:16384];
        [blit endEncoding];[command commit];[command waitUntilCompleted];
        if(command.status!=MTLCommandBufferStatusCompleted) {fprintf(stderr,"presentation.drawable_blit_error=%s\n",command.error.description.UTF8String);[actualReadback release];[actualQueue release];[drawable release];goto cleanup;}
        U32 drawableMismatches=0;
        for(U32 y=0;y<64;++y) for(U32 x=0;x<64;++x) {
            auto *pixel=static_cast<const unsigned char *>(actualReadback.contents)+y*256+x*4;
            U32 expected=73u|(((y*5+29)&255)<<8)|(((x*3+17)&255)<<16)|(255u<<24);
            U32 actual=U32(pixel[0])|(U32(pixel[1])<<8)|(U32(pixel[2])<<16)|(U32(pixel[3])<<24);
            if((((x==0||x==63)&&(y==0||y==63))||(x==32&&y==32))) {text("presentation.drawable_pixel.x=");number(x);text(" y=");number(y);text(" expected_BGRA=");hex(expected);text(" actual_BGRA=");hex(actual);text("\n");}
            if(actual!=expected) {if(drawableMismatches<8) {text("presentation.drawable_mismatch.x=");number(x);text(" y=");number(y);text(" actual=");hex(actual);text(" expected=");hex(expected);text("\n");}++drawableMismatches;}
        }
        [actualReadback release];[actualQueue release];[drawable release];
        text("presentation.actual_acquired_drawable_pixels=4096 mismatches=");number(drawableMismatches);text("\n");
        bool screenshotGradient=capture_own_window_control(window,true);
        text("presentation.confirmed_compositor_window_gradient=");number(screenshotGradient);text("\n");
        // Explicit opt-in negative/control diagnosis only: ask Cocoa/Metal to
        // present the real acquired drawable. This must NEVER turn the normal
        // DXGI result into PASS; it isolates the native compositor path.
        if(!callbackObserved && getenv("PRESENTATION_MANUAL_CONTROL")) {
            id<CAMetalDrawable> control=[layer copyCapturedDrawable];
            if(control) {
                text("presentation.MANUAL_CONTROL=calling actual CAMetalDrawable present; NOT DXGI success\n");
                [control present];
                for(U32 i=0;i<300 && !presented_drawables.load();++i) {pump_cocoa();Sleep(10);}
                fprintf(stdout,"presentation.MANUAL_CONTROL.callbacks=%u presented_time=%.9f\n",presented_drawables.load(),presented_time.load());fflush(stdout);
                [control release];
            }
        }
        // A matching image captured from our visible window is independent,
        // positive compositor proof. In this D3DMetal path the presented
        // observer does not fire, even though the standard Present displays
        // the exact gradient. Do not manufacture a callback or substitute a
        // manually presented frame. Both byte-exact GPU images and the window
        // image were checked BEFORE the optional negative-control present.
        pass=drawableMismatches==0 && screenshotGradient && afterPresentFence>=2;
    }
cleanup:
    {
        HR removed=method<HR (__stdcall *)(Com *)>(device,37)(device);
        hr("presentation.DeviceRemovedReason",removed);
        if(removed<0) pass=false;
    }
    text("presentation.result=");text(pass?"PASS\n":"FAIL\n");
    text("presentation.scope=standard DXGI swapchain/Present, actual window compositor image+drawable pixel readback; callback diagnostic only; GFXT third-party ABI; Apple7 classification simulated; software residency shim; not game/conformance\n");
    release(list7);release(list);release(allocator);release(swap3);release(swap);release(backbuffer);release(readback);release(queue);release(fence);release(heap);release(pso);release(root);release(errors);release(blob);
    return pass;
}

static int run_presentation(int argc,char **argv) {
    @autoreleasepool {
        if(argc!=2) {fprintf(stderr,"usage: native_presentation_host <unchanged D3DMetal binary>\n");return 64;}
        if(getenv("DMN_PRESENT_FALLBACK")) {
            text("presentation.error=DMN_PRESENT_FALLBACK must be unset for standard Present verification\n");
            return 71;
        }
        NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(140,140,256,256) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        [window setTitle:@"D3D12 Intel presentation probe — actual DXGI Present"];
        // Only this temporary diagnostic window joins the current/fullscreen
        // space. Do not mutate the user's Desktop/Spaces or app preferences.
        window.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
        window.level=NSFloatingWindowLevel;
        ProbeSurfaceView *surface=[[ProbeSurfaceView alloc] initWithFrame:NSMakeRect(0,0,256,256)];
        window.contentView=surface;surface.wantsLayer=YES;
        ProbeMetalLayer *layer=[(ProbeMetalLayer *)surface.layer retain];layer.contentsScale=1;layer.drawableSize=CGSizeMake(64,64);
        [surface release];
        [window makeKeyAndOrderFront:nil];[window orderFrontRegardless];[NSApp activateIgnoringOtherApps:YES];pump_cocoa();
        for(U32 i=0;i<150 && !(window.occlusionState&NSWindowOcclusionStateVisible);++i) {pump_cocoa();Sleep(20);}
        fprintf(stdout,"presentation.COCOA.visible=%d occlusion_visible=%d window_number=%ld view_hidden=%d layer_hidden=%d superlayer=%p\n",window.isVisible,(window.occlusionState&NSWindowOcclusionStateVisible)!=0,(long)window.windowNumber,window.contentView.isHidden,layer.hidden,(void*)layer.superlayer);fflush(stdout);
        if(getenv("PRESENTATION_PURE_METAL_CONTROL")) {
            bool control=pure_metal_control(layer,window);[window orderOut:nil];[layer release];[window release];return control?0:5;
        }
        dmn_window_t hostWindow=dmn_window_create_for_layer(layer);dmn_window_set_size(hostWindow,64,64,1);
        void *hwnd=dmn_window_get_hwnd(hostWindow);
        // UTM's caller-layer backend ordinarily has no NSView and supplies a
        // dummy view. This layer really belongs to our Cocoa window, so bind
        // the actual retained content view for GetViewForHWND/visibility.
        DmnWindow *hostState=dmn_window_lookup(hwnd);
        if(!hostState) return 69;
        hostState->view=[window.contentView retain];
        native_module_path=argv[1];native_module=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
        if(!native_module) {fprintf(stderr,"dlopen=%s\n",dlerror());return 65;}
        presentation_resources=std::string(argv[1]);presentation_resources.resize(presentation_resources.find_last_of('/'));presentation_resources+="/Resources";
        auto init=reinterpret_cast<void (*)(GFXTOSInterface *)>(dlsym(native_module,"GFXT_Initialize"));
        if(!init) {text("presentation.error=no public GFXT_Initialize export\n");return 66;}
        // The process-lifetime OS service object uses only the open UTM source.
        DmnGFXT *host=new DmnGFXT();init(host);dmn_swapchain_prepare_dummy_view();
        text("PRESENTATION_HOST=native Cocoa/CAMetalLayer; original D3DMetal; UTM MIT GFXT service subset; NO COM hooks/private flags\n");
        auto createFactory=reinterpret_cast<HR (__stdcall *)(U32,const Guid *,Com **)>(GetProcAddress(native_module,"CreateDXGIFactory2"));
        auto createDevice=reinterpret_cast<HR (__stdcall *)(Com *,U32,const Guid *,Com **)>(GetProcAddress(native_module,"D3D12CreateDevice"));
        if(!createFactory||!createDevice) return 67;
        Com *factory=nullptr;HR result=createFactory(0,&P_IID_Factory2,&factory);hr("presentation.CreateFactory2",result);if(result<0)return 68;
        bool pass=false;
        for(U32 i=0;i<16;++i) {
            Com *adapter=nullptr;result=method<HR (__stdcall *)(Com *,U32,Com **)>(factory,12)(factory,i,&adapter);if(result<0)break;
            AdapterDesc1 desc={};result=method<HR (__stdcall *)(Com *,AdapterDesc1 *)>(adapter,10)(adapter,&desc);
            if(result<0||desc.VendorId!=0x1002) {release(adapter);continue;}
            text("presentation.adapter=");wide(desc.Description);text("\n");
            Com *device=nullptr;result=createDevice(adapter,0xb000,&IID_Device,&device);hr("presentation.CreateDevice",result);
            if(result>=0&&device) {pass=presentation_smoke(factory,device,hwnd,layer,window);release(device);}release(adapter);break;
        }
        release(factory);for(U32 i=0;i<30;++i) {pump_cocoa();Sleep(10);}
        [window orderOut:nil];dmn_window_destroy(hostWindow);[layer release];[window release];
        return pass?0:5;
    }
}

int main(int argc,char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        // A real AppKit run loop, not just a never-running NSApplication with
        // manually polled events. The test still owns only its temporary UI.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100000000),dispatch_get_main_queue(),^{
            int code=run_presentation(argc,argv);fflush(stdout);fflush(stderr);_exit(code);
        });
        [NSApp run];
        return 70;
    }
}
