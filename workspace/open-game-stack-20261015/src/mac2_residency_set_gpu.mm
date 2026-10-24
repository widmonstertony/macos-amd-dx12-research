#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fstream>
#include <stdexcept>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

int main(int argc, const char** argv) {
    @autoreleasepool {
        try {
            require(argc == 2, "report path required");
            id<MTLDevice> device = nil;
            for (id<MTLDevice> candidate in MTLCopyAllDevices()) {
                if ([candidate.name containsString:@"5600M"]) {
                    device = [candidate retain];
                    break;
                }
            }
            require(device != nil, "Radeon Pro 5600M not found");
            require([device supportsFamily:MTLGPUFamilyMac2], "5600M did not expose Mac2 family");
            require([device respondsToSelector:@selector(newResidencySetWithDescriptor:error:)],
                    "MTLDevice residency-set API unavailable");

            NSError* error = nil;
            MTLResidencySetDescriptor* descriptor = [MTLResidencySetDescriptor new];
            descriptor.label = @"Mac2 residency validation";
            descriptor.initialCapacity = 4;
            id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:descriptor error:&error];
            [descriptor release];
            if (!residency || error) {
                fprintf(stderr, "RESIDENCY_ERROR domain=%s code=%ld description=%s\n",
                        error.domain.UTF8String ?: "(none)", (long)error.code,
                        error.localizedDescription.UTF8String ?: "(none)");
            }
            require(residency != nil && error == nil, "newResidencySet failed on Mac2");

            NSString* source = @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct Args { device uint* value [[id(0)]]; device uint* result [[id(1)]]; };\n"
                "kernel void residency_step(constant Args& a [[buffer(0)]]) {\n"
                "  uint v = a.value[0]; a.result[0] = v * 3u + 1u; a.value[0] = v + 1u;\n"
                "}\n";
            id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
            require(library != nil && error == nil, "Metal library compilation failed");
            id<MTLFunction> function = [library newFunctionWithName:@"residency_step"];
            id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
            require(pipeline != nil && error == nil, "compute pipeline creation failed");
            id<MTLArgumentEncoder> argumentEncoder = [function newArgumentEncoderWithBufferIndex:0];
            id<MTLBuffer> arguments = [device newBufferWithLength:argumentEncoder.encodedLength
                                                          options:MTLResourceStorageModeShared];
            id<MTLBuffer> value = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
            id<MTLBuffer> result = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
            require(arguments && value && result, "buffer allocation failed");
            *(uint32_t*)value.contents = 41;
            *(uint32_t*)result.contents = 0;
            [argumentEncoder setArgumentBuffer:arguments offset:0];
            [argumentEncoder setBuffer:value offset:0 atIndex:0];
            [argumentEncoder setBuffer:result offset:0 atIndex:1];

            // Both resources are reached only through the argument buffer.  The
            // encoder deliberately emits no useResource call.  Residency is
            // supplied by the Mac2 residency set, as MoltenVK does per queue.
            [residency addAllocation:(id<MTLAllocation>)value];
            [residency addAllocation:(id<MTLAllocation>)result];
            [residency commit];
            id<MTLCommandQueue> queue = [device newCommandQueue];
            require(queue != nil, "command queue creation failed");
            require([queue respondsToSelector:@selector(addResidencySet:)],
                    "MTLCommandQueue residency-set API unavailable");
            [queue addResidencySet:residency];
            id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:arguments offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            [encoder endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];

            uint32_t valueAfter = *(uint32_t*)value.contents;
            uint32_t resultAfter = *(uint32_t*)result.contents;
            bool passed = commandBuffer.status == MTLCommandBufferStatusCompleted &&
                          valueAfter == 42 && resultAfter == 124;
            std::ofstream report(argv[1]);
            report << "{\"passed\":" << (passed ? "true" : "false")
                   << ",\"device\":\"Radeon Pro 5600M\""
                   << ",\"supportsMac2\":true"
                   << ",\"residencySetCreated\":true"
                   << ",\"encoderUseResourceCalls\":0"
                   << ",\"valueAfter\":" << valueAfter
                   << ",\"resultAfter\":" << resultAfter
                   << ",\"commandBufferStatus\":" << commandBuffer.status
                   << "}\n";

            [queue removeResidencySet:residency];
            [result release];
            [value release];
            [arguments release];
            [argumentEncoder release];
            [pipeline release];
            [function release];
            [library release];
            [residency release];
            [device release];
            return passed ? 0 : 3;
        } catch (const std::exception& exception) {
            fprintf(stderr, "ERROR %s\n", exception.what());
            return 2;
        }
    }
}
