#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// Opt-in isolated compatibility experiment, GPU_ADAPTER_TEXTURE_MODE=managed.
// Normal device-created Shared textures on discrete AMD become real Managed
// textures. IOSurface/shared-handle/heap factories are deliberately excluded.
FOUNDATION_EXPORT MTLTextureDescriptor *TSPrepareDeviceTextureDescriptor(id<MTLDevice> device, MTLTextureDescriptor *requested);
FOUNDATION_EXPORT void TSRegisterConvertedTexture(id<MTLTexture> texture, MTLTextureDescriptor *requested);
// Invoke on the native command buffer AFTER its client encoders have ended,
// BEFORE native commit. Actual synchronizeResource blits restore CPU visibility.
FOUNDATION_EXPORT void TSEncodeManagedTextureSynchronization(id<MTLCommandBuffer> nativeBuffer, NSArray *retainedAllocations);
FOUNDATION_EXPORT NSDictionary *TSTextureStorageStatistics(void);
