#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

using Clock = std::chrono::steady_clock;
static double elapsedMS(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
static std::string escapeJSON(NSString* value) {
    if (!value) return "";
    std::string s([value UTF8String]);
    std::string out;
    for (char c : s) {
        if (c == '\\' || c == '"') out.push_back('\\');
        if (c == '\n') { out += "\\n"; continue; }
        out.push_back(c);
    }
    return out;
}

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc != 5) {
            std::cerr << "archive_probe source.metal archive.metalar mode(seed|load|plain) output.json\n";
            return 2;
        }
        NSString* sourcePath = [NSString stringWithUTF8String:argv[1]];
        NSString* archivePath = [NSString stringWithUTF8String:argv[2]];
        NSString* mode = [NSString stringWithUTF8String:argv[3]];
        NSError* error = nil;
        NSString* source = [NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:&error];
        if (!source) { std::cerr << [[error description] UTF8String] << "\n"; return 3; }

        id<MTLDevice> device = nil;
        for (id<MTLDevice> candidate in MTLCopyAllDevices()) {
            if ([[candidate name] containsString:@"Radeon Pro 5600M"]) { device = candidate; break; }
        }
        if (!device) { std::cerr << "Exact AMD Radeon Pro 5600M unavailable\n"; return 4; }

        MTLCompileOptions* options = [MTLCompileOptions new];
        options.fastMathEnabled = NO;
        auto libraryStart = Clock::now();
        id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
        double libraryMS = elapsedMS(libraryStart);
        [options release];
        if (!library) { std::cerr << [[error description] UTF8String] << "\n"; return 5; }
        id<MTLFunction> function = [library newFunctionWithName:@"main0"];
        if (!function) { std::cerr << "main0 not found\n"; return 6; }

        id<MTLBinaryArchive> archive = nil;
        if (![mode isEqualToString:@"plain"]) {
            MTLBinaryArchiveDescriptor* archiveDesc = [MTLBinaryArchiveDescriptor new];
            if ([mode isEqualToString:@"load"]) archiveDesc.url = [NSURL fileURLWithPath:archivePath];
            auto archiveStart = Clock::now();
            archive = [device newBinaryArchiveWithDescriptor:archiveDesc error:&error];
            double archiveOpenMS = elapsedMS(archiveStart);
            [archiveDesc release];
            if (!archive) { std::cerr << [[error description] UTF8String] << "\n"; return 7; }
            std::cerr << "archiveOpenMilliseconds=" << archiveOpenMS << "\n";
        }

        MTLComputePipelineDescriptor* descriptor = [MTLComputePipelineDescriptor new];
        descriptor.computeFunction = function;
        descriptor.maxTotalThreadsPerThreadgroup = 64;
        if (archive) descriptor.binaryArchives = @[archive];

        double addMS = 0.0;
        if ([mode isEqualToString:@"seed"]) {
            auto addStart = Clock::now();
            BOOL added = [archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error];
            addMS = elapsedMS(addStart);
            if (!added) { std::cerr << [[error description] UTF8String] << "\n"; return 8; }
        }

        auto pipelineStart = Clock::now();
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithDescriptor:descriptor
                                                                                     options:MTLPipelineOptionNone
                                                                                  reflection:nil
                                                                                       error:&error];
        double pipelineMS = elapsedMS(pipelineStart);
        if (!pipeline) { std::cerr << [[error description] UTF8String] << "\n"; return 9; }

        double serializeMS = 0.0;
        if ([mode isEqualToString:@"seed"]) {
            auto serializeStart = Clock::now();
            BOOL serialized = [archive serializeToURL:[NSURL fileURLWithPath:archivePath] error:&error];
            serializeMS = elapsedMS(serializeStart);
            if (!serialized) { std::cerr << [[error description] UTF8String] << "\n"; return 10; }
        }

        std::ofstream out(argv[4]);
        out << "{\"passed\":true,\"device\":\"" << escapeJSON([device name])
            << "\",\"mode\":\"" << argv[3]
            << "\",\"libraryMilliseconds\":" << libraryMS
            << ",\"archiveAddMilliseconds\":" << addMS
            << ",\"pipelineMilliseconds\":" << pipelineMS
            << ",\"serializeMilliseconds\":" << serializeMS << "}\n";
        [pipeline release];
        [descriptor release];
        [archive release];
        [function release];
        [library release];
        return 0;
    }
}
