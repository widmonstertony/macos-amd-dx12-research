#include "MVKMeshLinkDifferential.h"
#include <cstdio>
#include <cstring>

// Owned deliberately invalid interface verifies failure preservation. The
// correct interface then renders/readbacks real GPU pixels. No game inputs.
int main(int argc,const char** argv) { @autoreleasepool {
    if (argc!=2) return 2;setenv("MVK_AMD_LINK_DIFFERENTIAL_CAPTURE","1",1);
    id<MTLDevice> device=nil;NSArray* devices=MTLCopyAllDevices();
    for (id<MTLDevice> d in devices) if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device=d;
    if (!device) return 3;
    NSString* head=@"#include <metal_stdlib>\n#include <metal_mesh>\nusing namespace metal;struct Payload{float4 color;};struct V{float4 p[[position]];float4 c[[user(locn3)]];};struct P{};using M=metal::mesh<V,P,3,1,topology::triangle>;\n";
    NSArray* sources=@[
        [head stringByAppendingString:@"[[object]]void obj(object_data Payload&payload[[payload]],mesh_grid_properties grid){payload.color=float4(.25,.5,.75,1);grid.set_threadgroups_per_grid(uint3(1));}"],
        [head stringByAppendingString:@"[[mesh]]void msh(M out,const object_data Payload&payload[[payload]]){float2 xy[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};for(uint i=0;i<3;i++){V v;v.p=float4(xy[i],0,1);v.c=payload.color;out.set_vertex(i,v);out.set_index(i,i);}P p={};out.set_primitive(0,p);out.set_primitive_count(1);}"],
        @"#include <metal_stdlib>\nusing namespace metal;struct Bad{float4 c[[user(locn9)]];};fragment float4 frag(Bad in[[stage_in]]){return in.c;}"
    ];
    NSArray* names=@[@"obj",@"msh",@"frag"];NSMutableArray* functions=[NSMutableArray array];
    for (unsigned i=0;i<3;i++) {
        MTLCompileOptions* o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion4_0;o.mathMode=MTLMathModeSafe;o.mathFloatingPointFunctions=MTLMathFloatingPointFunctionsPrecise;
        NSError* error=nil;id<MTLLibrary> library=[device newLibraryWithSource:sources[i] options:o error:&error];
        id<MTLFunction> f=[library newFunctionWithName:names[i]];
        if (!f) return 4;f.label=names[i];
        objc_setAssociatedObject(f,mvkMeshContextKey(),mvkMeshCompileContext(sources[i],o,true),OBJC_ASSOCIATION_RETAIN);
        [functions addObject:f];[f release];[library release];[o release];
    }
    MTLMeshRenderPipelineDescriptor* descriptor=[MTLMeshRenderPipelineDescriptor new];
    descriptor.objectFunction=functions[0];descriptor.meshFunction=functions[1];descriptor.fragmentFunction=functions[2];
    descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;descriptor.maxTotalThreadsPerObjectThreadgroup=1;descriptor.maxTotalThreadsPerMeshThreadgroup=1;
    NSError* originalError=nil;id<MTLRenderPipelineState> invalid=[device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&originalError];
    if (invalid || ![originalError.localizedDescription containsString:@"fragment input"]) return 5;
    NSMutableArray* rows=[NSMutableArray array];uint64_t operation=mvkLinkOperationBegin(@"owned-control",@"negative-interface");
    mvkDiagnoseMeshLink(device,descriptor,nullptr,^(NSDictionary* row){[rows addObject:row];});mvkLinkOperationEnd(operation);
    unsigned count=(unsigned)rows.count;
    mvkDiagnoseMeshLink(device,descriptor,nullptr,^(NSDictionary* row){[rows addObject:row];});
    bool preserved=count==17 && rows.count==count && !invalid;
    for (NSDictionary* row in rows) preserved &= ![row[@"created"] boolValue] && [row[@"error"] containsString:@"fragment input"] && [row[@"activeAtStart"] count]==1;
    if (!preserved || mvkLinkOperationSnapshot().count) return 6;
    NSString* correct=[head stringByAppendingString:@"fragment float4 frag(V in[[stage_in]]){return in.c;}"];
    MTLCompileOptions* options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion4_0;
    NSError* error=nil;id<MTLLibrary> library=[device newLibraryWithSource:correct options:options error:&error];
    id<MTLFunction> fragment=[library newFunctionWithName:@"frag"];descriptor.fragmentFunction=fragment;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
    if (!pipeline) return 7;
    MTLTextureDescriptor* td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> texture=[device newTextureWithDescriptor:td];id<MTLBuffer> read=[device newBufferWithLength:2048 options:MTLResourceStorageModeShared];memset(read.contents,0xcd,2048);
    MTLRenderPassDescriptor* rp=[MTLRenderPassDescriptor renderPassDescriptor];rp.colorAttachments[0].texture=texture;rp.colorAttachments[0].loadAction=MTLLoadActionClear;rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLRenderCommandEncoder> encoder=[cb renderCommandEncoderWithDescriptor:rp];
    [encoder setRenderPipelineState:pipeline];[encoder drawMeshThreadgroups:MTLSizeMake(1,1,1) threadsPerObjectThreadgroup:MTLSizeMake(1,1,1) threadsPerMeshThreadgroup:MTLSizeMake(1,1,1)];[encoder endEncoding];
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];[blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:read destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048];[blit endEncoding];[cb commit];[cb waitUntilCompleted];
    unsigned badPixels=0;unsigned char expected[]={64,128,191,255};
    for (unsigned y=0;y<8;y++) for (unsigned x=0;x<8;x++) if (memcmp((char*)read.contents+y*256+x*4,expected,4)) ++badPixels;
    NSDictionary* result=@{@"passed":@(preserved && !badPixels && cb.status==MTLCommandBufferStatusCompleted),@"negativeControlOriginalFailurePreserved":@(preserved),@"diagnosticLinks":@(count),@"onceOnlyVerified":@(rows.count==count),@"diagnostics":rows,@"checkedPixels":@64,@"badPixels":@(badPixels),@"commandStatus":@(cb.status),@"gameCompatibilityProven":@NO};
    NSData* output=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];[output writeToFile:@(argv[1]) options:NSDataWritingAtomic error:nil];
    printf("diagnostic-links=%u pixels=64 mismatches=%u preserved=%d\n",count,badPixels,preserved);
    [pipeline release];[fragment release];[library release];[options release];[descriptor release];[read release];[texture release];[queue release];[devices release];
    return [result[@"passed"] boolValue] ? 0 : 8;
} }
