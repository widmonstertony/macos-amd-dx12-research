#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>

// Compile/link only: does not dispatch game shaders or open a game/prefix.
// Source files are supplied explicitly; generated game sources stay local.
int main(int argc, const char** argv) { @autoreleasepool {
    if (argc != 3) return 2;
    NSError* error = nil;
    NSDictionary* input = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:@(argv[1])] options:0 error:&error];
    if (!input) return 3;
    id<MTLDevice> device = nil;
    NSArray* devices = MTLCopyAllDevices();
    for (id<MTLDevice> candidate in devices)
        if ([candidate.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = candidate;
    if (!device) return 4;
    NSMutableArray* rows = [NSMutableArray array];
    NSArray* stages = @[@"object", @"mesh", @"fragment"];
    for (unsigned math = 0; math < 3; ++math) for (unsigned invariant = 0; invariant < 2; ++invariant) {
        @autoreleasepool {
            NSMutableArray* functions = [NSMutableArray array];
            NSError* failure = nil;
            NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
            for (unsigned index = 0; index < 3; ++index) {
                NSDictionary* stage = input[@"functions"][stages[index]];
                NSString* source = [NSString stringWithContentsOfFile:stage[@"source"]
                    encoding:NSUTF8StringEncoding error:&failure];
                if (!source) break;
                MTLCompileOptions* options = [MTLCompileOptions new];
                options.languageVersion = MTLLanguageVersion4_0;
                bool fast = math == 1 || (math == 2 && index == 2);
                options.mathMode = fast ? MTLMathModeFast : MTLMathModeSafe;
                options.mathFloatingPointFunctions = fast ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
                options.preserveInvariance = invariant && index < 2;
                id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&failure];
                [options release];
                id<MTLFunction> function = library ? [library newFunctionWithName:stage[@"entry"]] : nil;
                [library release];
                if (!function) break;
                [functions addObject:function]; [function release];
            }
            id<MTLRenderPipelineState> pipeline = nil;
            if (functions.count == 3) {
                MTLMeshRenderPipelineDescriptor* descriptor = [MTLMeshRenderPipelineDescriptor new];
                descriptor.objectFunction = functions[0]; descriptor.meshFunction = functions[1]; descriptor.fragmentFunction = functions[2];
                // The supplied fixture is depth-only. Refuse other descriptors
                // rather than silently replacing attachment compatibility.
                NSString* text = input[@"descriptorText"];
                if (![text containsString:@"depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm"] ||
                    ![text containsString:@"stencilAttachmentPixelFormat = MTLPixelFormatInvalid"]) return 5;
                descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
                descriptor.rasterSampleCount = 1;
                pipeline = [device newRenderPipelineStateWithMeshDescriptor:descriptor
                    options:MTLPipelineOptionNone reflection:nil error:&failure];
                [descriptor release];
            }
            NSDictionary* row = @{@"mathVariant":@(math), @"preserveObjectMeshInvariance":@(invariant),
                @"functionCount":@(functions.count), @"pipelineCreated":@(pipeline != nil),
                @"elapsedSeconds":@([NSDate timeIntervalSinceReferenceDate] - started),
                @"error":failure.localizedDescription ?: @"", @"errorCode":@(failure.code)};
            [rows addObject:row];
            NSData* line = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
            fwrite(line.bytes,1,line.length,stdout); puts(""); fflush(stdout);
            [pipeline release];
        }
    }
    NSDictionary* report = @{@"device":device.name, @"cases":rows, @"GPUWorkDispatched":@NO,
        @"exactOriginalCompilerOptionsKnown":@NO, @"gameCompatibilityProven":@NO};
    NSData* result = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    bool saved = [result writeToFile:@(argv[2]) options:NSDataWritingAtomic error:&error];
    [devices release];
    return saved ? 0 : 6;
} }
