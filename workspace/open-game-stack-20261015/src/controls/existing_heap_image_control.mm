#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include "../../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKBufferHeapReadPlan.h"
#include <cstdio>
#include <stdexcept>
@interface ImageHeap:NSObject
@end
@implementation ImageHeap
- (MTLHeapType)type{return MTLHeapTypePlacement;}
- (NSUInteger)size{return 1u<<24;}
@end
@interface ImageResource:NSObject {
@public id parentHeap,parent;NSUInteger offset,bytes;MTLTextureUsage flags;MTLStorageMode storage;
}
@end
@implementation ImageResource
- (BOOL)conformsToProtocol:(Protocol*)p{return protocol_isEqual(p,@protocol(MTLTexture))?:[super conformsToProtocol:p];}
- (id)heap{return parentHeap;}
- (id)parentTexture{return parent;}
- (id)buffer{return nil;}
- (NSUInteger)heapOffset{return offset;}
- (NSUInteger)allocatedSize{return bytes;}
- (NSUInteger)sampleCount{return 1;}
- (MTLTextureType)textureType{return MTLTextureType2D;}
- (MTLTextureUsage)usage{return flags;}
- (MTLStorageMode)storageMode{return storage;}
- (BOOL)isAliasable{return NO;}
@end
static unsigned checks=0;
static void need(bool b,const char*why){++checks;if(!b)throw std::runtime_error(why);}
int main(){@autoreleasepool{try{
 auto h=[ImageHeap new],other=[ImageHeap new];std::vector<ImageResource*>owned;
 auto make=[&](id heap,NSUInteger offset,MTLTextureUsage flags,id parent=nil){auto t=[ImageResource new];t->parentHeap=heap;t->offset=offset;t->bytes=4096;t->flags=flags;t->parent=parent;t->storage=MTLStorageModePrivate;owned.push_back(t);return t;};
 std::vector<id<MTLResource>>base,extra,all;
 for(unsigned i=0;i<128;++i)base.push_back((id<MTLResource>)make(h,i*4096,MTLTextureUsageShaderRead));
 auto root=make(h,128*4096,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget|MTLTextureUsageShaderWrite|MTLTextureUsagePixelFormatView);
 for(unsigned i=0;i<128;++i)extra.push_back((id<MTLResource>)make(h,0,root->flags,root));
 all=base;all.insert(all.end(),extra.begin(),extra.end());
 {BufferHeapReadPlan p(all,true);need(p.eligibleGroupCount(2)==1,"new heap introduced");need(p.baselineEligibleResourceCount(2)==128,"baseline gate broadened");need(p.eligibleResourceCount(2)==256,"same-parent coverage absent");need(p.preciseResourceCount(2)==0,"same-parent view remained precise");need(p.eligibleResourceCount(129)==0,"extra images changed group threshold");}
 {BufferHeapReadPlan p(extra,true);need(p.groups.empty()&&p.preciseResourceCount(2)==128,"attachment-only heap gained declaration");}
 auto shortBase=all;shortBase.erase(shortBase.begin());{BufferHeapReadPlan p(shortBase,true);need(p.baselineEligibleResourceCount(2)==127,"128-child admission gate broadened");need(p.eligibleResourceCount(2)==255,"coverage fixture missing");}
 auto rejected=[&](ImageResource*t){auto v=all;v.push_back((id<MTLResource>)t);BufferHeapReadPlan p(v,true);need(p.eligibleResourceCount(2)==256,"invalid extra altered baseline coverage");need(p.preciseResourceCount(2)==1,"invalid extra did not stay precise");need(p.eligibleGroupCount(2)==1,"invalid extra introduced a heap");};
 rejected(make(other,0,root->flags));
 rejected(make(h,4096,root->flags)); // Different physical owner overlaps a baseline allocation.
 auto unknown=make(h,130*4096,root->flags);unknown->bytes=0;rejected(unknown);
 auto wrongParent=make(h,0,root->flags,make(other,0,root->flags));rejected(wrongParent);
 auto cycle=make(h,0,root->flags);cycle->parent=cycle;rejected(cycle);
 auto atomic=make(h,132*4096,root->flags|MTLTextureUsageShaderAtomic);rejected(atomic);
 auto shared=make(h,133*4096,root->flags);shared->storage=MTLStorageModeShared;rejected(shared);
 auto nested=make(h,0,root->flags,(id)extra[0]);rejected(nested);
 for(auto t:owned)[t release];[h release];[other release];printf("{\"passed\":true,\"CPUOnly\":true,\"checks\":%u,\"baselineGatePreserved\":true,\"noAdditionalHeapDeclarations\":true,\"overlapAndUnknownRangesRejected\":true}\n",checks);return 0;
}catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
