#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKBufferHeapReadPlan.h"
#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKTexelWriteResidency.h"
#include <stdexcept>
#include <cstdio>
@interface OwnedHeap:NSObject
- (MTLHeapType)type; - (NSUInteger)size;
@end
@implementation OwnedHeap
- (MTLHeapType)type{return MTLHeapTypePlacement;}
- (NSUInteger)size{return 4096;}
@end
@interface OwnedResource:NSObject {
@public id parentHeap,backing;bool texture,view,aliasable;
 MTLTextureType texType;MTLTextureUsage flags;MTLStorageMode storage;
 NSUInteger offset,bytes;
}
@end
@implementation OwnedResource
- (BOOL)conformsToProtocol:(Protocol*)p{return protocol_isEqual(p,@protocol(MTLTexture))?texture:[super conformsToProtocol:p];}
- (id)heap{return parentHeap;}
- (id)buffer{return backing;}
- (id)parentTexture{return view?self:nil;}
- (MTLTextureType)textureType{return texType;}
- (MTLTextureUsage)usage{return flags;}
- (MTLStorageMode)storageMode{return storage;}
- (NSUInteger)sampleCount{return 1;}
- (BOOL)isAliasable{return aliasable;}
- (NSUInteger)heapOffset{return offset;}
- (NSUInteger)allocatedSize{return bytes;}
@end
static unsigned checks=0;
static void need(bool ok,const char*s){++checks;if(!ok)throw std::runtime_error(s);}
int main(){@autoreleasepool{try{
 auto heap=[OwnedHeap new];auto other=[OwnedHeap new];std::vector<OwnedResource*>owned;
 auto make=[&](bool texture,id parent,NSUInteger offset,NSUInteger bytes){auto r=[OwnedResource new];r->texture=texture;r->parentHeap=heap;r->backing=parent;r->offset=offset;r->bytes=bytes;r->storage=MTLStorageModePrivate;r->texType=MTLTextureTypeTextureBuffer;r->flags=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;owned.push_back(r);return r;};
 auto a=make(false,nil,0,1024),b=make(false,nil,2048,1024);std::vector<id<MTLResource>> views;
 for(unsigned i=0;i<128;++i)views.push_back((id<MTLResource>)make(true,i<64?a:b,0,0));
 {BufferHeapReadPlan p(views,true);need(p.eligibleResourceCount(2)==128,"same-buffer views must share valid readonly heap residency");need(p.preciseResourceCount(2)==0,"valid parent-backed views unexpectedly precise");}
 auto overlap=make(false,nil,512,1024),v=make(true,overlap,0,0);auto withOverlap=views;withOverlap.push_back((id<MTLResource>)v);
 {BufferHeapReadPlan p(withOverlap,true);need(p.eligibleResourceCount(2)==0,"different overlapping physical buffers must remain precise");need(p.preciseResourceCount(2)==129,"overlap fallback lost resources");}
 a->bytes=0;{BufferHeapReadPlan p(views,true);need(p.eligibleResourceCount(2)==0,"unknown physical range must remain precise");}a->bytes=1024;
 for(unsigned i=0;i<128;++i)need(mvkTexelWriteResidencyResource(views[i],(id<MTLHeap>)heap)==(id<MTLResource>)(i<64?a:b),"valid typed-view physical owner not selected");
 need(mvkTexelWriteResidencyResource((id<MTLResource>)a,(id<MTLHeap>)heap)==(id<MTLResource>)a,"ordinary buffer identity changed");
 auto ownerTest=(OwnedResource*)views[0];
 ownerTest->flags|=MTLTextureUsageShaderAtomic;need(mvkTexelWriteResidencyResource(views[0],(id<MTLHeap>)heap)==views[0],"atomic view owner changed");ownerTest->flags=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
 ownerTest->parentHeap=other;need(mvkTexelWriteResidencyResource(views[0],(id<MTLHeap>)heap)==views[0],"view heap mismatch admitted");ownerTest->parentHeap=heap;
 a->storage=MTLStorageModeShared;need(mvkTexelWriteResidencyResource(views[0],(id<MTLHeap>)heap)==views[0],"shared parent admitted");a->storage=MTLStorageModePrivate;
 need(mvkTexelWriteResidencyResource(views[0],nil)==views[0],"heapless owner changed");
 auto first=(OwnedResource*)views[0];
 need(BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"heap-backed readonly texel view rejected");
 first->flags|=MTLTextureUsageRenderTarget;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"render attachments must stay precise");first->flags=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
 first->flags|=MTLTextureUsageShaderAtomic;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"unqualified atomic usage must stay precise");first->flags=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
 first->parentHeap=other;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"view/parent heap mismatch must reject");first->parentHeap=heap;
 first->backing=nil;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"missing backing must reject");first->backing=a;
 first->storage=MTLStorageModeShared;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"nonprivate view must reject");first->storage=MTLStorageModePrivate;
 first->view=true;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"parent texture views remain excluded");first->view=false;
 first->texType=MTLTextureType2D;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"buffer-backed 2D fallback must not gain support");first->backing=nil;need(!BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"writable ordinary 2D remains precise");
 first->flags=MTLTextureUsageShaderRead;need(BufferHeapReadPlan::canPrepareSampledTexture(views[0]),"previous readonly 2D path lost");
 for(auto r:owned)[r release];[heap release];[other release];printf("{\"passed\":true,\"checks\":%u,\"viewCount\":128,\"distinctBackingBuffers\":2}\n",checks);return 0;
}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
