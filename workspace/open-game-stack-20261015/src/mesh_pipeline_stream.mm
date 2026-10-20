#include "metal_link_repro_common.h"
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <atomic>

static id<MTLLibrary> asynchronousLibrary(id<MTLDevice> device, NSString* source,
        MTLCompileOptions* options, NSError** outputError) {
    dispatch_semaphore_t complete=dispatch_semaphore_create(0);
    __block id<MTLLibrary> result=nil;
    __block NSError* failure=nil;
    @synchronized(device) {
        [device newLibraryWithSource:source options:options completionHandler:^(id<MTLLibrary> library, NSError* error) {
            result=[library retain]; failure=[error retain]; dispatch_semaphore_signal(complete);
        }];
    }
    dispatch_semaphore_wait(complete,DISPATCH_TIME_FOREVER);
    dispatch_release(complete);
    if (outputError) *outputError=[failure autorelease]; else [failure release];
    return result;
}

static id<MTLRenderPipelineState> asynchronousPipeline(id<MTLDevice> device,
        MTLRenderPipelineDescriptor* descriptor, NSError** outputError) {
    dispatch_semaphore_t complete=dispatch_semaphore_create(0);
    __block id<MTLRenderPipelineState> result=nil;
    __block NSError* failure=nil;
    @synchronized(device) {
        [device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id<MTLRenderPipelineState> state, NSError* error) {
            result=[state retain]; failure=[error retain]; dispatch_semaphore_signal(complete);
        }];
    }
    dispatch_semaphore_wait(complete,DISPATCH_TIME_FOREVER);
    dispatch_release(complete);
    if (outputError) *outputError=[failure autorelease]; else [failure release];
    return result;
}

static NSUInteger enumValue(NSString* name) {
#define ENTRY(x) @#x:@(x)
    static NSDictionary* values = @{
        ENTRY(MTLPixelFormatInvalid), ENTRY(MTLPixelFormatDepth16Unorm), ENTRY(MTLPixelFormatDepth32Float), ENTRY(MTLPixelFormatDepth32Float_Stencil8),
        ENTRY(MTLPixelFormatR16Uint),ENTRY(MTLPixelFormatR8Uint),ENTRY(MTLPixelFormatR8Unorm),ENTRY(MTLPixelFormatRG16Float),
        ENTRY(MTLPixelFormatRG11B10Float),ENTRY(MTLPixelFormatRGBA32Float),ENTRY(MTLPixelFormatRGBA16Unorm),ENTRY(MTLPixelFormatRGBA16Float),
        ENTRY(MTLPixelFormatRGBA8Unorm_sRGB),ENTRY(MTLPixelFormatBGRA8Unorm),ENTRY(MTLPixelFormatBGRA8Unorm_sRGB),ENTRY(MTLPixelFormatRGB10A2Unorm),
        ENTRY(MTLVertexFormatUInt),ENTRY(MTLVertexFormatFloat3),ENTRY(MTLVertexFormatHalf4),ENTRY(MTLVertexFormatUChar4Normalized),
        ENTRY(MTLVertexFormatUChar4),ENTRY(MTLVertexFormatUChar4Normalized_BGRA),ENTRY(MTLVertexFormatFloat4),ENTRY(MTLVertexFormatFloat2),
        ENTRY(MTLVertexFormatChar4Normalized),ENTRY(MTLVertexFormatHalf2),ENTRY(MTLVertexStepFunctionPerInstance),ENTRY(MTLVertexStepFunctionPerVertex),
        ENTRY(MTLBlendFactorDestinationAlpha),ENTRY(MTLBlendFactorOne),ENTRY(MTLBlendFactorOneMinusDestinationAlpha),
        ENTRY(MTLBlendFactorOneMinusSourceAlpha),ENTRY(MTLBlendFactorSourceAlpha),ENTRY(MTLBlendFactorZero),ENTRY(MTLBlendOperationAdd)};
#undef ENTRY
    NSNumber* value=values[name];
    if (!value) throw std::runtime_error(std::string("Unknown public enum: ")+name.UTF8String);
    return value.unsignedIntegerValue;
}

static MTLRenderPipelineDescriptor* vertexDescriptor(NSDictionary* item, NSDictionary* functions) {
    MTLRenderPipelineDescriptor* d=[[MTLRenderPipelineDescriptor new] autorelease];
    d.vertexFunction=functions[item[@"functions"][@"vertex"][@"sourceSHA256"]];
    NSDictionary* fragment=item[@"functions"][@"fragment"];
    d.fragmentFunction=fragment ? functions[fragment[@"sourceSHA256"]] : nil;
    d.depthAttachmentPixelFormat=(MTLPixelFormat)enumValue(item[@"depth"]);
    d.stencilAttachmentPixelFormat=(MTLPixelFormat)enumValue(item[@"stencil"]);
    d.rasterSampleCount=[item[@"rasterSamples"] unsignedIntegerValue];
    d.rasterizationEnabled=[item[@"rasterization"] boolValue];
    d.alphaToCoverageEnabled=[item[@"alphaToCoverage"] boolValue]; d.alphaToOneEnabled=[item[@"alphaToOne"] boolValue];
    NSString* topology=item[@"topology"];
    if ([topology isEqualToString:@"Triangle"]) d.inputPrimitiveTopology=MTLPrimitiveTopologyClassTriangle;
    else if ([topology isEqualToString:@"Line"]) d.inputPrimitiveTopology=MTLPrimitiveTopologyClassLine;
    else if ([topology isEqualToString:@"Point"]) d.inputPrimitiveTopology=MTLPrimitiveTopologyClassPoint;
    else if (![topology isEqualToString:@"Unspecified"]) throw std::runtime_error("Unsupported topology");
    for (NSDictionary* a in item[@"colors"]) {
        MTLRenderPipelineColorAttachmentDescriptor* color=d.colorAttachments[[a[@"index"] unsignedIntegerValue]];
        color.pixelFormat=(MTLPixelFormat)enumValue(a[@"pixelFormat"]);color.blendingEnabled=[a[@"blending"] boolValue];
        color.sourceRGBBlendFactor=(MTLBlendFactor)enumValue(a[@"sourceRGB"]);color.sourceAlphaBlendFactor=(MTLBlendFactor)enumValue(a[@"sourceAlpha"]);
        color.destinationRGBBlendFactor=(MTLBlendFactor)enumValue(a[@"destinationRGB"]);color.destinationAlphaBlendFactor=(MTLBlendFactor)enumValue(a[@"destinationAlpha"]);
        color.rgbBlendOperation=(MTLBlendOperation)enumValue(a[@"rgbOperation"]);color.alphaBlendOperation=(MTLBlendOperation)enumValue(a[@"alphaOperation"]);
        NSString* mask=a[@"writeMask"]; MTLColorWriteMask bits=MTLColorWriteMaskNone;
        if ([mask containsString:@"R"]) bits|=MTLColorWriteMaskRed;if ([mask containsString:@"G"]) bits|=MTLColorWriteMaskGreen;
        if ([mask containsString:@"B"]) bits|=MTLColorWriteMaskBlue;if ([mask containsString:@"A"]) bits|=MTLColorWriteMaskAlpha;
        color.writeMask=bits;
    }
    if ([item[@"vertexBuffers"] count]) {
        MTLVertexDescriptor* vertices=[MTLVertexDescriptor vertexDescriptor];
        for (NSDictionary* b in item[@"vertexBuffers"]) {
            NSUInteger index=[b[@"index"] unsignedIntegerValue];MTLVertexBufferLayoutDescriptor* layout=vertices.layouts[index];
            layout.stepFunction=(MTLVertexStepFunction)enumValue(b[@"stepFunction"]);layout.stepRate=[b[@"stepRate"] unsignedIntegerValue];
            layout.stride=[b[@"stride"] isEqualToString:@"dynamic"] ? MTLBufferLayoutStrideDynamic : [b[@"stride"] unsignedIntegerValue];
            for (NSDictionary* a in b[@"attributes"]) {
                MTLVertexAttributeDescriptor* attribute=vertices.attributes[[a[@"index"] unsignedIntegerValue]];
                attribute.bufferIndex=index;attribute.offset=[a[@"offset"] unsignedIntegerValue];attribute.format=(MTLVertexFormat)enumValue(a[@"format"]);
            }
        }
        d.vertexDescriptor=vertices;
    }
    return d;
}

// Replays supplied ordinary graphics links alongside one depth-only mesh
// fixture. No game or GPU command dispatch. Public descriptor fields are
// reconstructed; unknown source specialization was excluded by the builder.
int main(int argc,const char** argv) { @autoreleasepool { try {
    if (argc!=6) return 2;
    NSDictionary* targetInput=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
    NSArray* vertices=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[2])] options:0 error:nil];
    NSString* mode=@(argv[3]);bool interleaved=[mode containsString:@"interleaved"];bool allNativeGated=[mode containsString:@"all-native-gated"];unsigned workers=(unsigned)strtoul(argv[4],nullptr,10);
    if (!targetInput || !vertices || !workers || workers>8) return 3;
    NSArray* devices=MTLCopyAllDevices();id<MTLDevice> device=nil;
    for (id<MTLDevice> d in devices) if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device=d;
    if (!device) return 4;
    NSMutableArray* libraries=[NSMutableArray array];NSError* error=nil;
    NSArray* target=targetFunctions(device,targetInput,libraries,&error);if (target.count!=3) return 5;
    NSMutableDictionary* sources=[NSMutableDictionary dictionary];
    for (NSDictionary* item in vertices) for (NSDictionary* f in [item[@"functions"] allValues]) sources[f[@"sourceSHA256"]]=f;
    NSMutableDictionary* functions=[NSMutableDictionary dictionary];NSMutableArray* rows=[NSMutableArray array];
    NSArray* keys=[sources allKeys];dispatch_semaphore_t slots=dispatch_semaphore_create(workers);
    if (!interleaved) dispatch_apply(keys.count,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i) { @autoreleasepool {
        dispatch_semaphore_wait(slots,DISPATCH_TIME_FOREVER);NSDictionary* item=sources[keys[i]];NSError* failure=nil;
        NSString* source=[NSString stringWithContentsOfFile:item[@"source"] encoding:NSUTF8StringEncoding error:&failure];
        id<MTLLibrary> library=source ? [device newLibraryWithSource:source options:compileOptions(item[@"compileProvenance"]) error:&failure] : nil;
        id<MTLFunction> f=library ? [library newFunctionWithName:item[@"entry"]] : nil;
        if (f.functionConstantsDictionary.count) { [f release];f=nil; }
        @synchronized(functions) {
            if (f) functions[keys[i]]=f;if (library) [libraries addObject:library];
            if (functions.count%64==0) { fprintf(stderr,"prepared %lu/%lu functions\n",(unsigned long)functions.count,(unsigned long)keys.count);fflush(stderr); }
        }
        [f release];[library release];dispatch_semaphore_signal(slots);
    }});
    if (!interleaved && functions.count!=keys.count) { fprintf(stderr,"library/function preparation failed %lu/%lu\n",(unsigned long)functions.count,(unsigned long)keys.count);return 6; }
    fprintf(stderr,"prepared %lu distinct functions; linking %lu graphics fixtures\n",(unsigned long)keys.count,(unsigned long)vertices.count);fflush(stderr);
    // Validate all enum/layout inputs before entering asynchronous blocks.
    for (NSDictionary* item in vertices) (void)vertexDescriptor(item,functions);
    NSMutableArray* work=[NSMutableArray array];
    for (NSUInteger i=0;i<vertices.count;i++) { [work addObject:vertices[i]]; if (i%8==0) [work addObject:[NSNull null]]; }
    bool allGated=[mode containsString:@"all-gated"] || allNativeGated;
    std::atomic<int> libraryActive{0};auto* activeLibraries=&libraryActive;
    dispatch_semaphore_t linkGate=dispatch_semaphore_create(1);
    dispatch_apply(work.count,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i) { @autoreleasepool {
        dispatch_semaphore_wait(slots,DISPATCH_TIME_FOREVER);bool mesh=work[i]==[NSNull null];
        if (allNativeGated) dispatch_semaphore_wait(linkGate,DISPATCH_TIME_FOREVER);
        NSDictionary* selectedFunctions=functions;
        NSMutableDictionary* lazyFunctions=nil;
        bool ready=true;
        if (interleaved && !mesh) {
            lazyFunctions=[NSMutableDictionary dictionary];
            for (NSDictionary* item in [work[i][@"functions"] allValues]) { @autoreleasepool {
                NSError* compileError=nil;
                NSString* source=[NSString stringWithContentsOfFile:item[@"source"] encoding:NSUTF8StringEncoding error:&compileError];
                activeLibraries->fetch_add(1);
                id<MTLLibrary> library=source ? asynchronousLibrary(device,source,compileOptions(item[@"compileProvenance"]),&compileError) : nil;
                id<MTLFunction> f=library ? [library newFunctionWithName:item[@"entry"]] : nil;
                if (f) (void)f.functionConstantsDictionary.allValues;
                activeLibraries->fetch_sub(1);
                if (f) lazyFunctions[item[@"sourceSHA256"]]=f;else ready=false;
                [f release];[library release];
            }}
            selectedFunctions=lazyFunctions;
        }
        if (!allNativeGated && (mesh || allGated)) dispatch_semaphore_wait(linkGate,DISPATCH_TIME_FOREVER);
        int concurrentLibraryPreparations=activeLibraries->load();
        NSError* failure=nil;id<MTLRenderPipelineState> state=nil;
        if (mesh) {
            MTLMeshRenderPipelineDescriptor* d=[MTLMeshRenderPipelineDescriptor new];
            d.objectFunction=target[0];d.meshFunction=target[1];d.fragmentFunction=target[2];d.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
            state=[device newRenderPipelineStateWithMeshDescriptor:d options:MTLPipelineOptionNone reflection:nil error:&failure];[d release];
        } else if (ready) state=interleaved
            ? asynchronousPipeline(device,vertexDescriptor(work[i],selectedFunctions),&failure)
            : [device newRenderPipelineStateWithDescriptor:vertexDescriptor(work[i],selectedFunctions) options:MTLPipelineOptionNone reflection:nil error:&failure];
        if (mesh || allGated) dispatch_semaphore_signal(linkGate);
        NSDictionary* row=@{@"workIndex":@(i),@"mesh":@(mesh),@"sourceSequence":mesh ? @(-1) : work[i][@"sequence"],@"concurrentLibraryPreparations":@(concurrentLibraryPreparations),@"created":@(state!=nil),@"error":failure.localizedDescription ?: @""};
        @synchronized(rows) { [rows addObject:row]; if (!state || rows.count%64==0) { fprintf(stderr,"linked %lu/%lu mesh=%d created=%d %s\n",(unsigned long)rows.count,(unsigned long)work.count,mesh,state!=nil,failure.localizedDescription.UTF8String ?: "");fflush(stderr); } }
        [state release];dispatch_semaphore_signal(slots);
    }});
    unsigned meshFailures=0,vertexFailures=0,meshRequests=0;
    for (NSDictionary* row in rows) { if ([row[@"mesh"] boolValue]) { ++meshRequests;if (![row[@"created"] boolValue]) ++meshFailures; } else if (![row[@"created"] boolValue]) ++vertexFailures; }
    NSDictionary* report=@{@"mode":mode,@"interleavedLibraryPreparation":@(interleaved),@"asynchronousOrdinaryLibraries":@(interleaved),@"asynchronousOrdinaryPipelines":@(interleaved),@"allNativeOperationsGated":@(allNativeGated),@"workers":@(workers),@"sourceFunctions":@(keys.count),@"vertexRequests":@(vertices.count),
        @"meshRequests":@(meshRequests),@"meshFailures":@(meshFailures),@"vertexFailures":@(vertexFailures),@"rows":rows,
        @"GPUWorkDispatched":@NO,@"descriptorStateApproximate":@YES,@"compilerProfilesFromActualFunctionTrace":@YES};
    NSData* output=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];bool saved=[output writeToFile:@(argv[5]) options:NSDataWritingAtomic error:nil];
    printf("vertices=%lu meshes=%u vertexFailures=%u meshFailures=%u\n",(unsigned long)vertices.count,meshRequests,vertexFailures,meshFailures);
    dispatch_release(linkGate);dispatch_release(slots);[devices release];return saved ? 0 : 7;
} catch (const std::exception& error) { fprintf(stderr,"input error: %s\n",error.what());return 8; } } }
