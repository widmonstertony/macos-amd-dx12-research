/* Isolated compiler timing only. Never dispatches an extracted game shader. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 3 && argc != 5) return 2;
    @autoreleasepool {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        id<MTLDevice> device = nil;
        for (id<MTLDevice> candidate in devices)
            if ([candidate.name isEqualToString:@"AMD Radeon Pro 5600M"]) device = candidate;
        if (!device) return 3;
        const char *mode = argc == 5 ? argv[3] : "plain";
        bool seed = strcmp(mode, "seed") == 0;
        bool load = strcmp(mode, "load") == 0;
        bool miss = strcmp(mode, "miss") == 0;
        bool seedAfter = strcmp(mode, "seed-after") == 0;
        if (!seed && !load && !miss && !seedAfter && strcmp(mode, "plain")) return 2;
        NSError *error = nil;
        NSString *source = [NSString stringWithContentsOfFile:
            [NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:&error];
        if (!source) return 4;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion4_0;
        const char* math = getenv("MVK_PROFILE_MATH");
        bool fast = math && !strcmp(math, "fast");
        options.mathMode = fast ? MTLMathModeFast : MTLMathModeSafe;
        options.mathFloatingPointFunctions = fast ? MTLMathFloatingPointFunctionsFast : MTLMathFloatingPointFunctionsPrecise;
        options.preserveInvariance = NO;
        auto start = std::chrono::steady_clock::now();
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        auto libraryEnd = std::chrono::steady_clock::now();
        fprintf(stdout, "libraryCreated=%d\n", library != nil); fflush(stdout);
        id<MTLFunction> function = library ? [library newFunctionWithName:@"main0"] : nil;
        MTLComputePipelineDescriptor *descriptor = [MTLComputePipelineDescriptor new];
        if (function) descriptor.computeFunction = function;
        descriptor.maxTotalThreadsPerThreadgroup = 64;
        id<MTLBinaryArchive> archive = nil;
        BOOL archiveAdded = NO, archiveSerialized = NO;
        if (function && argc == 5 && !seedAfter) {
            MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
            NSURL *archiveURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]];
            if (load) archiveDescriptor.url = archiveURL;
            archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
            [archiveDescriptor release];
            if (archive) {
                descriptor.binaryArchives = @[archive];
                if (seed) {
                    archiveAdded = [archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error];
                    if (archiveAdded && ![[NSFileManager defaultManager] fileExistsAtPath:archiveURL.path])
                        archiveSerialized = [archive serializeToURL:archiveURL error:&error];
                }
            }
        }
        auto archiveEnd = std::chrono::steady_clock::now();
        id<MTLComputePipelineState> pipeline = function ?
            [device newComputePipelineStateWithDescriptor:descriptor
                options:(load || miss) ? MTLPipelineOptionFailOnBinaryArchiveMiss : MTLPipelineOptionNone
                                               reflection:nil error:&error] : nil;
        auto end = std::chrono::steady_clock::now();
        double postPipelineArchiveMS = 0;
        if (pipeline && seedAfter) {
            MTLBinaryArchiveDescriptor *archiveDescriptor = [MTLBinaryArchiveDescriptor new];
            archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
            [archiveDescriptor release];
            descriptor.binaryArchives = archive ? @[archive] : @[];
            archiveAdded = archive && [archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error];
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[4]]];
            if (archiveAdded && ![[NSFileManager defaultManager] fileExistsAtPath:url.path])
                archiveSerialized = [archive serializeToURL:url error:&error];
            postPipelineArchiveMS = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - end).count();
        }
        double libraryMS = std::chrono::duration<double, std::milli>(libraryEnd - start).count();
        double archiveMS = std::chrono::duration<double, std::milli>(archiveEnd - libraryEnd).count();
        double pipelineMS = std::chrono::duration<double, std::milli>(end - archiveEnd).count();
        NSDictionary *result = @{@"device":device.name, @"libraryCreated":@(library != nil),
            @"pipelineCreated":@(pipeline != nil), @"libraryMilliseconds":@(libraryMS),
            @"pipelineMilliseconds":@(pipelineMS), @"GPUExecuted":@NO,
            @"archiveMilliseconds":@(archiveMS), @"archiveAdded":@(archiveAdded),
            @"archiveSerialized":@(archiveSerialized), @"archiveHitRequired":@(load || miss),
            @"postPipelineArchiveMilliseconds":@(postPipelineArchiveMS),
            @"nativeCompilationTaskLimit":@(device.maximumConcurrentCompilationTaskCount),
            @"nativeMaximizeCompilation":@(device.shouldMaximizeConcurrentCompilation),
            @"configurationMatchesGameVerified":@NO, @"mathMode":fast ? @"fast" : @"safe",
            @"error":error.localizedDescription ?: @""};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result
                                                     options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
        fprintf(stdout, "pipelineCreated=%d libraryMS=%.3f pipelineMS=%.3f\n",
                pipeline != nil, libraryMS, pipelineMS);
        [pipeline release]; [descriptor release]; [function release]; [library release];
        [archive release]; [options release]; [devices release];
        return pipeline ? 0 : 1;
    }
}
