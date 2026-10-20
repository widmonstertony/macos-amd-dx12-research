#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// This probes Metal capabilities and one explicit fence dependency. It does not
// implement D3D12 Enhanced Barriers or establish compatibility with any game.
static NSDictionary *testFence(id<MTLDevice> device) {
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "kernel void write_value(device uint *p [[buffer(0)]]) { p[0] = 41; }\n"
        "kernel void read_value(device uint *p [[buffer(0)]]) { p[0] += 1; }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return @{ @"passed": @NO, @"error": error.localizedDescription ?: @"shader compilation failed" };
    id<MTLComputePipelineState> write = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"write_value"] error:&error];
    id<MTLComputePipelineState> read = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_value"] error:&error];
    id<MTLBuffer> buffer = [device newBufferWithLength:sizeof(uint32_t)
        options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
    id<MTLFence> fence = [device newFence];
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!write || !read || !buffer || !fence || !queue)
        return @{ @"passed": @NO, @"error": error.localizedDescription ?: @"resource or fence creation failed" };
    *(uint32_t *)buffer.contents = 0;
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLComputeCommandEncoder> first = [commands computeCommandEncoder];
    [first setComputePipelineState:write];
    [first setBuffer:buffer offset:0 atIndex:0];
    [first dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [first updateFence:fence];
    [first endEncoding];
    id<MTLComputeCommandEncoder> second = [commands computeCommandEncoder];
    [second waitForFence:fence];
    [second setComputePipelineState:read];
    [second setBuffer:buffer offset:0 atIndex:0];
    [second dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [second endEncoding];
    [commands commit];
    [commands waitUntilCompleted];
    uint32_t actual = *(uint32_t *)buffer.contents;
    return @{ @"passed": @(commands.status == MTLCommandBufferStatusCompleted && actual == 42),
              @"expected": @42, @"actual": @(actual),
              @"commandBufferStatus": @(commands.status),
              @"error": commands.error.localizedDescription ?: @"" };
}

int main(void) {
    @autoreleasepool {
        NSMutableArray *results = [NSMutableArray array];
        for (id<MTLDevice> device in MTLCopyAllDevices()) {
            NSMutableDictionary *entry = [@{
                @"name": device.name,
                @"registryID": @(device.registryID),
                @"mac2": @([device supportsFamily:MTLGPUFamilyMac2]),
                @"metal3": @([device supportsFamily:MTLGPUFamilyMetal3]),
                @"apple7": @([device supportsFamily:MTLGPUFamilyApple7]),
                @"argumentBuffersTier": @(device.argumentBuffersSupport == MTLArgumentBuffersTier2 ? 2 : 1),
                @"unifiedMemory": @(device.hasUnifiedMemory),
                @"maxBufferBytes": @(device.maxBufferLength),
                @"recommendedWorkingSetBytes": @(device.recommendedMaxWorkingSetSize),
                @"dynamicLibraries": @(device.supportsDynamicLibraries),
                @"functionPointers": @(device.supportsFunctionPointers),
                @"raytracing": @(device.supportsRaytracing),
                @"readWriteTextureTier": @(device.readWriteTextureSupport),
                @"fenceComputeTest": testFence(device)
            } mutableCopy];
            if (@available(macOS 26.0, *)) {
                entry[@"metal4"] = @([device supportsFamily:MTLGPUFamilyMetal4]);
            }
            id<MTLBuffer> addressBuffer = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            entry[@"bufferGPUAddressNonzero"] = @(addressBuffer && addressBuffer.gpuAddress != 0);
            [results addObject:entry];
        }
        NSDictionary *report = @{ @"schema": @1, @"devices": results,
            @"scope": @"Metal feature query and two-encoder fence test; not a D3D12 conformance test" };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return results.count ? 0 : 2;
    }
}
