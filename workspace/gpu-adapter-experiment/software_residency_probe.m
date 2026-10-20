#import "software_residency_adapter.h"
#import "texture_storage_adapter.h"
#include <stdint.h>
#include <unistd.h>
#include <stdlib.h>

static NSDictionary *setCallbackProbe(id<MTLDevice> device) {
  __block BOOL deallocatorCalled = NO, reenteredSet = NO;
  id<MTLResidencySet> set = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:nil];
  __weak id<MTLResidencySet> weakSet = set;
  @autoreleasepool {
    void *memory = NULL;
    size_t length = (size_t)getpagesize();
    if (posix_memalign(&memory, length, length) != 0) return @{@"passed":@NO,@"error":@"posix_memalign"};
    id<MTLBuffer> resource = [device newBufferWithBytesNoCopy:memory length:length options:MTLResourceStorageModeShared deallocator:^(void *pointer, NSUInteger bytes) {
      (void)bytes;
      // A final-release callback must be able to call back into the set. This
      // would deadlock if commit drops the previous snapshot under its lock.
      reenteredSet = weakSet.allocationCount == 0;
      deallocatorCalled = YES; free(pointer);
    }];
    if (!resource) { free(memory); return @{@"passed":@NO,@"error":@"newBufferWithBytesNoCopy"}; }
    [set addAllocation:resource]; [set commit]; resource = nil;
  }
  @autoreleasepool { [set removeAllAllocations]; [set commit]; }
  // Exercise concurrent request/end state transitions without concurrent GPU
  // work, then explicitly end to establish an unambiguous final state.
  dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^(size_t index) {
    if (index & 1) [set requestResidency]; else [set endResidency];
  });
  [set endResidency];
  return @{@"passed":@(deallocatorCalled && reenteredSet),@"deallocatorCalled":@(deallocatorCalled),
    @"callbackReenteredSetWithoutDeadlock":@(reenteredSet),@"concurrentRequestEndCalls":@64};
}

static NSDictionary *managedTextureProbe(id<MTLDevice> device) {
  const char *mode = getenv("GPU_ADAPTER_TEXTURE_MODE");
  if (!mode || strcmp(mode,"managed")) return @{@"enabled":@NO,@"passed":@YES};
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void texture_copy(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 tid [[thread_position_in_grid]]) { output.write(input.read(tid).bgra, tid); }\n";
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  id<MTLComputePipelineState> pipeline = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"texture_copy"] error:&error] : nil;
  if (!pipeline) return @{@"enabled":@YES,@"passed":@NO,@"error":error.localizedDescription ?: @"texture compute pipeline"};
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
  descriptor.storageMode = MTLStorageModeShared;
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> input = [device newTextureWithDescriptor:descriptor];
  id<MTLTexture> output = [device newTextureWithDescriptor:descriptor];
  if (!input || !output) return @{@"enabled":@YES,@"passed":@NO,@"error":@"shared-to-managed texture allocation"};
  uint8_t upload[4*4*4], download[4*4*4];
  for (NSUInteger pixel = 0; pixel < 16; ++pixel) {
    upload[pixel*4] = 17; upload[pixel*4+1] = 83; upload[pixel*4+2] = 201; upload[pixel*4+3] = 255;
  }
  [input replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:upload bytesPerRow:16];
  id<MTLCommandBuffer> commands = [[device newCommandQueue] commandBufferWithUnretainedReferences];
  id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
  [encoder setComputePipelineState:pipeline];
  id<MTLTexture> textures[2] = {input,output};
  [encoder setTextures:textures withRange:NSMakeRange(0,2)];
  [encoder dispatchThreads:MTLSizeMake(4,4,1) threadsPerThreadgroup:MTLSizeMake(4,4,1)];
  [encoder endEncoding]; encoder = nil;
  [commands commit]; [commands waitUntilCompleted];
  // No probe-authored synchronization blit or GPU->buffer copy: the adapter
  // must supply the genuine Managed GPU->CPU synchronization at submission.
  [output getBytes:download bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
  NSUInteger mismatches = 0;
  for (NSUInteger pixel = 0; pixel < 16; ++pixel) {
    if (download[pixel*4] != 201 || download[pixel*4+1] != 83 || download[pixel*4+2] != 17 || download[pixel*4+3] != 255) ++mismatches;
  }
  return @{@"enabled":@YES,@"passed":@(commands.status == MTLCommandBufferStatusCompleted && !mismatches && input.storageMode == MTLStorageModeManaged && output.storageMode == MTLStorageModeManaged),
    @"requestedStorageMode":@0,@"actualInputStorageMode":@(input.storageMode),@"actualOutputStorageMode":@(output.storageMode),
    @"CPUReplaceRegionUpload":@YES,@"GPUWriteThenCPUGetBytes":@YES,@"arrayTextureBinding":@YES,@"mismatchedPixels":@(mismatches),
    @"expectedRGBA":@[@201,@83,@17,@255],@"actualRGBA":@[@(download[0]),@(download[1]),@(download[2]),@(download[3])],
    @"commandBufferStatus":@(commands.status),@"error":commands.error.localizedDescription ?: @""};
}

static NSDictionary *computeProbe(id<MTLDevice> device) {
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Args { device uint *out; };\n"
    "kernel void indirect_write(constant Args &args [[buffer(0)]], uint tid [[thread_position_in_grid]]) { args.out[tid] = tid * 3 + 7; }\n";
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  id<MTLComputePipelineState> pipeline = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"indirect_write"] error:&error] : nil;
  if (!pipeline) return @{@"passed":@NO,@"error":error.localizedDescription ?: @"compute pipeline"};
  MTLHeapDescriptor *heapDescriptor = [MTLHeapDescriptor new];
  heapDescriptor.size = 65536;
  heapDescriptor.storageMode = MTLStorageModePrivate;
  id<MTLHeap> heap = [device newHeapWithDescriptor:heapDescriptor];
  id<MTLBuffer> output = [heap newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
  id<MTLBuffer> arguments = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLBuffer> readback = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  if (!heap || !output || !arguments || !readback) return @{@"passed":@NO,@"error":@"heap/resource allocation"};
  *(uint64_t *)arguments.contents = output.gpuAddress;
  id<MTLResidencySet> set = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
  [set addAllocation:arguments]; [set commit];
  uint64_t committedSize = set.allocatedSize;
  [set removeAllocation:arguments];
  BOOL pendingSemantics = set.allocationCount == 0 && ![set containsAllocation:arguments] && set.allocatedSize == committedSize;
  [set commit];
  [set addAllocation:heap]; [set addAllocation:arguments]; [set addAllocation:readback];
  [set commit]; [set requestResidency];
  id<MTLCommandQueue> queue = [device newCommandQueue];
  [queue addResidencySet:set];
  id<MTLCommandBuffer> commands = [queue commandBufferWithUnretainedReferences];
  [commands useResidencySet:set];
  id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
  [encoder setComputePipelineState:pipeline];
  [encoder setBuffer:arguments offset:0 atIndex:0];
  // output is deliberately never directly bound and no native useResource is
  // issued by this probe: the software residency implementation must declare it.
  [encoder dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
  [encoder endEncoding]; encoder = nil;
  id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
  [blit copyFromBuffer:output sourceOffset:0 toBuffer:readback destinationOffset:0 size:4096];
  [blit endEncoding]; blit = nil;
  __weak id<MTLBuffer> weakOutput = output;
  output = nil;
  BOOL retainedBeforeSubmit = weakOutput != nil;
  [commands commit]; [commands waitUntilCompleted];
  NSUInteger mismatches = 0;
  for (uint32_t i = 0; i < 64; ++i) if (((uint32_t *)readback.contents)[i] != i*3+7) ++mismatches;
  [set endResidency]; [queue removeResidencySet:set];
  return @{@"passed":@(commands.status == MTLCommandBufferStatusCompleted && mismatches == 0 && pendingSemantics && retainedBeforeSubmit),
    @"pendingCommittedSemantics":@(pendingSemantics),@"unretainedBufferKeptAliveBeforeSubmit":@(retainedBeforeSubmit),
    @"mismatchedWords":@(mismatches),@"wordsChecked":@64,@"commandBufferStatus":@(commands.status),
    @"heapChildIndirectAddress":@YES,@"error":commands.error.localizedDescription ?: @""};
}

static NSDictionary *renderProbe(id<MTLDevice> device) {
  NSError *error = nil;
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 position [[position]]; }; struct Args { device float4 *color; };\n"
    "vertex V vertex_main(uint id [[vertex_id]]) { float2 positions[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; V out; out.position=float4(positions[id],0,1); return out; }\n"
    "fragment float4 fragment_main(V in [[stage_in]], constant Args &args [[buffer(0)]]) { return args.color[0]; }\n";
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction = [library newFunctionWithName:@"vertex_main"];
  descriptor.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
  id<MTLRenderPipelineState> pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
  if (!pipeline) return @{@"passed":@NO,@"error":error.localizedDescription ?: @"render pipeline"};
  id<MTLBuffer> color = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  float values[4] = {0.25,0.5,0.75,1.0}; memcpy(color.contents, values, sizeof(values));
  id<MTLBuffer> arguments = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  *(uint64_t *)arguments.contents = color.gpuAddress;
  MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
  textureDescriptor.storageMode = MTLStorageModePrivate;
  textureDescriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  id<MTLBuffer> readback = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> commands = [queue commandBufferWithUnretainedReferences];
  __weak id<MTLTexture> weakTexture = nil;
  id<MTLRenderCommandEncoder> encoder = nil;
  @autoreleasepool {
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
    weakTexture = texture;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    encoder = [commands renderCommandEncoderWithDescriptor:pass];
    texture = nil; pass = nil;
  }
  BOOL attachmentRetainedBeforeDraw = weakTexture != nil;
  [encoder setRenderPipelineState:pipeline];
  [encoder setFragmentBuffer:arguments offset:0 atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [encoder endEncoding]; encoder = nil;
  id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
  [blit copyFromTexture:weakTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
  [blit endEncoding]; blit = nil;
  __weak id<MTLBuffer> weakColor = color; color = nil;
  BOOL retained = weakColor != nil;
  [commands commit]; [commands waitUntilCompleted];
  uint8_t *pixel = readback.contents;
  BOOL correct = pixel[0] == 64 && pixel[1] == 128 && pixel[2] == 191 && pixel[3] == 255;
  return @{@"passed":@(commands.status == MTLCommandBufferStatusCompleted && correct && retained && attachmentRetainedBeforeDraw),
    @"actualRGBA":@[@(pixel[0]),@(pixel[1]),@(pixel[2]),@(pixel[3])],@"expectedRGBA":@[@64,@128,@191,@255],
    @"indirectFragmentColorAddress":@YES,@"unretainedColorKeptAliveBeforeSubmit":@(retained),
    @"descriptorAttachmentKeptAliveBeforeFirstDraw":@(attachmentRetainedBeforeDraw),
    @"commandBufferStatus":@(commands.status),@"error":commands.error.localizedDescription ?: @""};
}

int main(int argc, char **argv) {
  @autoreleasepool {
    id<MTLDevice> native = nil;
    for (id<MTLDevice> device in MTLCopyAllDevices()) if ([device.name containsString:@"AMD"]) native = device;
    if (!native) { fprintf(stderr,"No genuine AMD device\n"); return 2; }
    id<MTLDevice> wrapped = SRWrapMetalDeviceForSoftwareResidency(native);
    NSDictionary *callbacks = setCallbackProbe(wrapped), *compute = computeProbe(wrapped), *render = renderProbe(wrapped), *textures = managedTextureProbe(wrapped);
    NSDictionary *result = @{@"schema":@1,@"device":native.name,@"capabilitiesUnmodified":@YES,
      @"scope":@"Metal3 software residency: native validation + indirect compute/fragment resource address, heap child, pending commit and unretained command-buffer smoke tests",
      @"setCallbacks":callbacks,@"compute":compute,@"render":render,@"managedTextures":textures,
      @"textureStorageStatistics":TSTextureStorageStatistics(),@"statistics":SRSoftwareResidencyStatistics(native)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
    if (argc > 1) [data writeToFile:@(argv[1]) atomically:YES];
    return [callbacks[@"passed"] boolValue] && [compute[@"passed"] boolValue] && [render[@"passed"] boolValue] && [textures[@"passed"] boolValue] ? 0 : 3;
  }
}
