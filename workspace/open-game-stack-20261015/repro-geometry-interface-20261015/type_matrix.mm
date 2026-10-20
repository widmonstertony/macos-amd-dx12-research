#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstdlib>

// Compilation-only control; never launches the game or submits GPU commands.
static NSString* substitute(NSString* source, NSString* name, NSString* replacement) {
    NSString* pattern = [NSString stringWithFormat:@"\\b%@\\b",[NSRegularExpression escapedPatternForString:name]];
    return [source stringByReplacingOccurrencesOfString:pattern withString:replacement
        options:NSRegularExpressionSearch range:NSMakeRange(0,source.length)];
}
int main(int argc,const char** argv) { @autoreleasepool {
    if (argc != 7) return 2;
    unsigned mode = strtoul(argv[1],nullptr,10);
    NSString* output = @(argv[2]);
    [[NSFileManager defaultManager] createDirectoryAtPath:output
        withIntermediateDirectories:YES attributes:nil error:nil];
    id<MTLDevice> device = nil;
    for (id<MTLDevice> d in MTLCopyAllDevices())
        if ([d.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = d;
    if (!device) return 3;
    NSMutableArray* functions = [NSMutableArray array];
    NSMutableArray* stages = [NSMutableArray array];
    for (unsigned i=0;i<3;i++) {
        NSError* error = nil;
        NSString* source = [NSString stringWithContentsOfFile:@(argv[i+3])
            encoding:NSUTF8StringEncoding error:&error];
        if (!source) return 4;
        NSMutableSet* types = [NSMutableSet set];
        NSArray* patterns = @[@"(?m)^\\s*(?:struct|class|enum(?:\\s+class)?)\\s+([A-Za-z_][A-Za-z0-9_]*)",
            @"(?m)^\\s*using\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*="];
        for (NSString* pattern in patterns) {
            NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            for (NSTextCheckingResult* match in [expression matchesInString:source options:0 range:NSMakeRange(0,source.length)])
                [types addObject:[source substringWithRange:[match rangeAtIndex:1]]];
        }
        NSString* prefix = [NSString stringWithFormat:@"matrix_m%u_s%u_",mode,i];
        for (NSString* type in [[types allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
            bool io = [type hasPrefix:@"main0_"];
            bool payload = [type isEqualToString:@"Payload"] || [type isEqualToString:@"spvGSVertex"];
            bool stream = [type isEqualToString:@"spvMeshStream"] || [type isEqualToString:@"mesh_stream_t"];
            bool selected = mode==2 || mode==3 || (mode==4 && io) ||
                (mode==5 && payload) || (mode==6 && stream) ||
                (mode==7 && !io && !payload && !stream);
            if (selected) source=substitute(source,type,[prefix stringByAppendingString:type]);
        }
        NSString* entry = @"main0";
        if (mode==1 || mode==2) {
            entry=[prefix stringByAppendingString:entry];source=substitute(source,@"main0",entry);
        }
        [source writeToFile:[output stringByAppendingPathComponent:[NSString stringWithFormat:@"stage-%u.metal",i]]
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
        MTLCompileOptions* options = [MTLCompileOptions new];
        options.languageVersion=MTLLanguageVersion4_0;
        options.mathMode=MTLMathModeSafe;
        options.mathFloatingPointFunctions=MTLMathFloatingPointFunctionsPrecise;
        options.preserveInvariance=i==1;
        id<MTLLibrary> library=[device newLibraryWithSource:source options:options error:&error];
        id<MTLFunction> function=[library newFunctionWithName:entry];
        [stages addObject:@{@"created":@(function!=nil),@"error":error.localizedDescription?:@"",
            @"entry":entry,@"stage":@(i)}];
        if (!function) break;
        [functions addObject:function];
    }
    NSError* error=nil;id<MTLRenderPipelineState> pipeline=nil;
    if (functions.count==3) {
        MTLMeshRenderPipelineDescriptor* descriptor=[MTLMeshRenderPipelineDescriptor new];
        descriptor.objectFunction=functions[0];descriptor.meshFunction=functions[1];descriptor.fragmentFunction=functions[2];
        descriptor.depthAttachmentPixelFormat=MTLPixelFormatDepth16Unorm;
        pipeline=[device newRenderPipelineStateWithMeshDescriptor:descriptor
            options:MTLPipelineOptionNone reflection:nil error:&error];
    }
    NSDictionary* result=@{@"mode":@(mode),@"pipelineCreated":@(pipeline!=nil),
        @"error":error.localizedDescription?:@"",@"stages":stages,
        @"GPUCommandsSubmitted":@NO,@"device":device.name};
    NSData* json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[output stringByAppendingPathComponent:@"output.json"] atomically:YES];
    fwrite(json.bytes,1,json.length,stdout);puts("");return pipeline?0:5;
}}
