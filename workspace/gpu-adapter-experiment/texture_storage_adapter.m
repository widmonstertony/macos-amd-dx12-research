#import "texture_storage_adapter.h"
#include <stdlib.h>
#include <string.h>

static NSLock *textureLock;
static NSHashTable *convertedTextures;
static uint64_t convertedCount, synchronizationCount, privateDepthCount;
static BOOL TSIsDepthStencil(MTLPixelFormat format) {
  switch(format) {
    case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float:
    case MTLPixelFormatStencil8: case MTLPixelFormatDepth24Unorm_Stencil8:
    case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatX32_Stencil8:
    case MTLPixelFormatX24_Stencil8: return YES;
    default: return NO;
  }
}
static BOOL TSIsEnabled(void) {
  const char *mode = getenv("GPU_ADAPTER_TEXTURE_MODE");
  return mode && !strcmp(mode, "managed");
}
static void TSInitialize(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    textureLock = [NSLock new];
    convertedTextures = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
  });
}
MTLTextureDescriptor *TSPrepareDeviceTextureDescriptor(id<MTLDevice> device, MTLTextureDescriptor *requested) {
  if (!TSIsEnabled() || device.hasUnifiedMemory) return requested;
  if (TSIsDepthStencil(requested.pixelFormat) &&
      (requested.storageMode == MTLStorageModeShared || requested.storageMode == MTLStorageModeManaged)) {
    // Discrete Mac depth/stencil is GPU-only. Managed is illegal too; keep
    // format, dimensions, samples, usage and all actual GPU content intact.
    // This does NOT implement CPU Map/replaceRegion on a depth/stencil image.
    if(requested.usage & MTLTextureUsageShaderWrite)
      [NSException raise:NSInternalInconsistencyException format:@"Depth/stencil ShaderWrite fallback is not implemented"];
    MTLTextureDescriptor *prepared=[requested copy];
    prepared.storageMode=MTLStorageModePrivate;
    prepared.hazardTrackingMode=MTLHazardTrackingModeTracked;
    fprintf(stderr,"TEXTURE_STORAGE gpuOnlyDepthStencil requestedMode=%lu actualPrivate format=%lu dimensions=%lux%lu usage=0x%lx CPU_MAP_NOT_IMPLEMENTED\n",(unsigned long)requested.storageMode,(unsigned long)prepared.pixelFormat,(unsigned long)prepared.width,(unsigned long)prepared.height,(unsigned long)prepared.usage);
    return prepared;
  }
  if (requested.storageMode != MTLStorageModeShared) return requested;
  if (requested.textureType == MTLTextureType2DMultisample || requested.textureType == MTLTextureType2DMultisampleArray) {
    [NSException raise:NSInternalInconsistencyException format:@"Managed fallback does not cover CPU-visible multisample textures"];
  }
  MTLTextureDescriptor *prepared = [requested copy];
  prepared.storageMode = MTLStorageModeManaged;
  // The additional synchronization blit must be ordered against earlier work.
  // Native hazard tracking also retains the valid client's explicit fences.
  prepared.hazardTrackingMode = MTLHazardTrackingModeTracked;
  if (getenv("GPU_ADAPTER_VERBOSE")) fprintf(stderr, "TEXTURE_STORAGE requestedShared actualManaged trackedHazards dimensions=%lux%lux%lu format=%lu usage=0x%lx EXPERIMENTAL_CPU_GPU_SYNCHRONIZATION\n",
    (unsigned long)prepared.width, (unsigned long)prepared.height, (unsigned long)prepared.depth,
    (unsigned long)prepared.pixelFormat, (unsigned long)prepared.usage);
  return prepared;
}
void TSRegisterConvertedTexture(id<MTLTexture> texture, MTLTextureDescriptor *requested) {
  if (!TSIsEnabled() || !texture) return;
  if(TSIsDepthStencil(requested.pixelFormat) && texture.storageMode==MTLStorageModePrivate &&
      (requested.storageMode==MTLStorageModeShared || requested.storageMode==MTLStorageModeManaged)) {
    TSInitialize();[textureLock lock];++privateDepthCount;[textureLock unlock];return;
  }
  if (requested.storageMode != MTLStorageModeShared || texture.storageMode != MTLStorageModeManaged) return;
  TSInitialize();
  [textureLock lock]; [convertedTextures addObject:texture]; ++convertedCount; [textureLock unlock];
}
void TSEncodeManagedTextureSynchronization(id<MTLCommandBuffer> nativeBuffer, NSArray *retainedAllocations) {
  if (!TSIsEnabled()) return;
  TSInitialize();
  NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray array];
  [textureLock lock];
  for (id allocation in retainedAllocations) if ([convertedTextures containsObject:allocation]) [textures addObject:allocation];
  [textureLock unlock];
  if (!textures.count) return;
  id<MTLBlitCommandEncoder> encoder = [nativeBuffer blitCommandEncoder];
  if (!encoder) [NSException raise:NSInternalInconsistencyException format:@"Cannot encode managed texture synchronization"];
  encoder.label = @"Intel DX12 compatibility: actual Managed GPU-to-CPU synchronization";
  for (id<MTLTexture> texture in textures) [encoder synchronizeResource:texture];
  [encoder endEncoding];
  [textureLock lock]; synchronizationCount += textures.count; [textureLock unlock];
  // CPU replaceRegion on a Managed texture is native Metal's CPU-to-GPU upload.
  // This command supplies the other direction before completion callbacks.
  // Conservatively synchronizes every converted live resource in the snapshot;
  // correctness prototype, not a claim of game-scale performance.
}
NSDictionary *TSTextureStorageStatistics(void) {
  TSInitialize(); [textureLock lock];
  NSDictionary *stats = @{@"convertedTextures": @(convertedCount), @"liveConvertedTextures": @(convertedTextures.count), @"nativeTextureSynchronizations": @(synchronizationCount), @"gpuOnlyPrivateDepthStencilTextures":@(privateDepthCount)};
  [textureLock unlock]; return stats;
}
