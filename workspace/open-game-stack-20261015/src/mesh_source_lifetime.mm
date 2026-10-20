#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>

// Legal public-API lifetime control. Never dereferences a released object.
// Recreates the production inner autorelease pools instead of keeping source
// strings alive until the final pipeline link as earlier controls did.
int main(int argc,const char** argv) { @autoreleasepool {
    if (argc!=4) return 2;
    NSDictionary* input=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
    unsigned mask=(unsigned)strtoul(argv[2],nullptr,10);bool keepSource=mask&1,keepLibrary=mask&2;
    NSArray* devices=MTLCopyAllDevices();id<MTLDevice> device=nil;
    for (id<MTLDevice> d in devices) if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device=d;
    if (!input || !device || mask>3) return 3;
    NSMutableArray* functions=[NSMutableArray array];NSMutableArray* sources=[NSMutableArray array];NSMutableArray* libraries=[NSMutableArray array];
    NSMutableArray* lengths=[NSMutableArray array];
    for (NSString* stage in @[@"object",@"mesh",@"fragment"]) { @autoreleasepool {
        NSDictionary* item=input[@"functions"][stage];NSData* data=[NSData dataWithContentsOfFile:item[@"source"]];
        // initWithUTF8String matches MoltenVK's std::string -> NSString path.
        NSMutableData* terminated=[data mutableCopy];unsigned char zero=0;[terminated appendBytes:&zero length:1];
        NSString* source=[[NSString alloc] initWithUTF8String:(const char*)terminated.bytes];[terminated release];
        [lengths addObject:@(data.length)];if (keepSource) [sources addObject:source];
        NSDictionary* p=item[@"compileProvenance"];MTLCompileOptions* options=[MTLCompileOptions new];
        options.languageVersion=(MTLLanguageVersion)[p[@"languageVersion"] unsignedIntegerValue];
        options.fastMathEnabled=[p[@"fastMathEnabled"] boolValue];
        options.mathMode=(MTLMathMode)[p[@"mathMode"] unsignedIntegerValue];
        options.mathFloatingPointFunctions=(MTLMathFloatingPointFunctions)[p[@"mathFloatingPointFunctions"] unsignedIntegerValue];
        options.preserveInvariance=[p[@"preserveInvariance"] boolValue];
        options.optimizationLevel=(MTLLibraryOptimizationLevel)[p[@"optimizationLevel"] unsignedIntegerValue];
        NSError* error=nil;id<MTLLibrary> library=[device newLibraryWithSource:source options:options error:&error];
        id<MTLFunction> function=[library newFunctionWithName:item[@"entry"]];
        if (!function) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 4; }
        (void)function.functionConstantsDictionary.allValues;function.label=nil;function.label=item[@"label"];
        [functions addObject:function];if (keepLibrary) [libraries addObject:library];
        [function release];[library release];[options release];[source release];
    }}
    // Exercise allocator reuse with owned live data, without accessing freed
    // memory or changing any native compiler object after submission.
    NSMutableArray* churn=[NSMutableArray array];
    for (unsigned round=0;round<64;round++) for (NSNumber* length in lengths) {
        NSMutableData* data=[NSMutableData dataWithLength:length.unsignedIntegerValue+1];memset(data.mutableBytes,'X',length.unsignedIntegerValue);
        NSString* string=[[NSString alloc] initWithUTF8String:(const char*)data.bytes];[churn addObject:string];[string release];[churn addObject:data];
    }
    MTLMeshRenderPipelineDescriptor* descriptor=[MTLMeshRenderPipelineDescriptor new];
    descriptor.objectFunction=functions[0];descriptor.meshFunction=functions[1];descriptor.fragmentFunction=functions[2];
    descriptor.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;descriptor.rasterSampleCount=1;
    NSError* error=nil;id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
    NSDictionary* result=@{@"keepSource":@(keepSource),@"keepLibrary":@(keepLibrary),@"pipelineCreated":@(pipeline!=nil),@"error":error.localizedDescription ?: @"",@"GPUWorkDispatched":@NO,@"descriptorStateApproximate":@YES};
    NSData* output=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];[output writeToFile:@(argv[3]) options:NSDataWritingAtomic error:nil];
    printf("keepSource=%d keepLibrary=%d created=%d error=%s\n",keepSource,keepLibrary,pipeline!=nil,error.localizedDescription.UTF8String ?: "");
    [pipeline release];[descriptor release];[devices release];return 0;
} }
