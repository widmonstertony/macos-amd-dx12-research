// Public Metal GPU-output control for the bounded all-draw timestamp mode.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fstream>
#include <stdexcept>
#include "MVKGPUTimestampTrace.h"

static void need(bool value, const char* message) {
    if (!value) { throw std::runtime_error(message); }
}

int main(int argc, const char** argv) {
    @autoreleasepool {
        try {
            need(argc == 2, "report path required");
            id<MTLDevice> device = nil;
            for (id<MTLDevice> candidate in MTLCopyAllDevices()) {
                if ([candidate.name containsString:@"5600M"]) { device = candidate; break; }
            }
            need(device != nil, "Radeon Pro 5600M required");

            NSError* error = nil;
            NSString* source = @"#include <metal_stdlib>\n"
                               "using namespace metal;\n"
                               "vertex float4 vs(uint i [[vertex_id]]) {\n"
                               "  const float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};\n"
                               "  return float4(p[i],0,1);\n"
                               "}\n"
                               "fragment float4 fs() { return float4(1,0,0,1); }\n";
            id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
            need(library != nil, error.localizedDescription.UTF8String ?: "library failed");
            id<MTLFunction> vertex = [library newFunctionWithName:@"vs"];
            id<MTLFunction> fragment = [library newFunctionWithName:@"fs"];
            MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
            descriptor.vertexFunction = vertex;
            descriptor.fragmentFunction = fragment;
            descriptor.label = @"all-draw-control";
            descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
            need(pipeline != nil, error.localizedDescription.UTF8String ?: "pipeline failed");

            MTLTextureDescriptor* textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
            textureDescriptor.usage = MTLTextureUsageRenderTarget;
            textureDescriptor.storageMode = MTLStorageModePrivate;
            id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
            id<MTLBuffer> readback = [device newBufferWithLength:256 * 32 options:MTLResourceStorageModeShared];
            id<MTLCommandQueue> queue = [device newCommandQueue];
            id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
            NSMutableDictionary* record = [NSMutableDictionary dictionary];
            mvkBeginGPUTimestamps(record, commandBuffer, 0);

            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLRenderCommandEncoder> render = [commandBuffer renderCommandEncoderWithDescriptor:pass];
            [render setRenderPipelineState:pipeline];
            mvkSampleGPUTimestamp(record, render, @"graphics-pipeline", pipeline.label);
            mvkSampleGPUTimestamp(record, render, @"draw", @"pipeline=all-draw-control;vertices=3;instances=1");
            [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            mvkSampleGPUTimestamp(record, render, @"encoder-end", @"all-draw-control");
            [render endEncoding];

            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(32, 32, 1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * 32];
            [blit endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
            need(commandBuffer.status == MTLCommandBufferStatusCompleted, "GPU render failed");

            const uint8_t* pixel = (const uint8_t*)readback.contents + 16 * 256 + 16 * 4;
            const bool outputPassed = pixel[2] > 240 && pixel[1] < 8 && pixel[0] < 8 && pixel[3] > 240;
            record[@"nativeCompleted"] = @YES;
            NSDictionary* timestamps = mvkSnapshotGPUTimestamps(record);
            NSArray* samples = timestamps[@"samples"];
            const bool drawSamplePresent = [samples indexesOfObjectsPassingTest:^BOOL(NSDictionary* row, NSUInteger, BOOL*) {
                return [row[@"kind"] isEqualToString:@"draw"] && [row[@"valid"] boolValue] && [row[@"timestamp"] unsignedLongLongValue] > 0;
            }].count == 1;
            const bool countersPassed = [timestamps[@"enabled"] boolValue] &&
                                        [timestamps[@"CPUResolveSucceeded"] boolValue] &&
                                        [timestamps[@"allDraws"] boolValue] &&
                                        [timestamps[@"capacity"] unsignedIntegerValue] == 512 &&
                                        samples.count == 3 && drawSamplePresent;
            mvkEndGPUTimestamps(record);

            NSDictionary* report = @{
                @"device":device.name,
                @"GPUOutputVerified":@(outputPassed),
                @"centerPixelBGRA":@[@(pixel[0]), @(pixel[1]), @(pixel[2]), @(pixel[3])],
                @"allDrawCountersVerified":@(countersPassed),
                @"timestampTrace":timestamps,
                @"counterBudgetReleased":@(mvkGPUTimestampInFlight() == 0),
                @"passed":@(outputPassed && countersPassed && mvkGPUTimestampInFlight() == 0)
            };
            NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
            need([data writeToFile:@(argv[1]) atomically:YES], "report write failed");
            printf("%s\n", [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);

            [readback release]; [texture release]; [queue release]; [pipeline release];
            [descriptor release]; [fragment release]; [vertex release]; [library release];
            return [report[@"passed"] boolValue] ? 0 : 3;
        } catch (const std::exception& error) {
            fprintf(stderr, "ERROR %s\n", error.what());
            return 2;
        }
    }
}
