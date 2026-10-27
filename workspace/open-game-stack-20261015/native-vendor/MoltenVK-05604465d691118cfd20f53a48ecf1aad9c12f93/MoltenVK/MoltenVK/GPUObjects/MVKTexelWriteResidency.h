// A private texture-buffer view uses its MTLBuffer allocation. Ordinary images,
// heapless/shared views, atomics and mismatched parents retain exact residency.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static inline id<MTLResource> mvkTexelWriteResidencyResource(id<MTLResource> resource,id<MTLHeap> heap) {
    if (!heap || ![resource conformsToProtocol:@protocol(MTLTexture)]) return resource;
    auto texture=static_cast<id<MTLTexture>>(resource);
    const auto allowed=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsagePixelFormatView;
    if (texture.textureType!=MTLTextureTypeTextureBuffer || texture.sampleCount!=1 ||
        texture.storageMode!=MTLStorageModePrivate || texture.parentTexture ||
        !(texture.usage&MTLTextureUsageShaderWrite) || (texture.usage&~allowed) || texture.heap!=heap) return resource;
    id<MTLBuffer> parent=texture.buffer;
    if (!parent || parent.storageMode!=MTLStorageModePrivate || parent.heap!=heap) return resource;
    return parent;
}
