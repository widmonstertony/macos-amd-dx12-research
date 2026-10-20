#import "software_residency_adapter.h"
#import "texture_storage_adapter.h"
#include <stdlib.h>
#include <string.h>
#include <objc/runtime.h>
#include <time.h>
#include <unistd.h>

// All resources are genuine Metal objects. Software sets keep pending and
// committed membership separately. Every shader execution declares indirect
// resources with native useResources/useHeaps. Command buffers hold strong
// resource snapshots until real GPU completion, including unretained buffers.
// This is conservative Metal 3 residency at execution, not physical pre-pinning
// or a Metal 4 implementation. No capability value is overridden here.

@class SRContext, SRSet, SRQueue, SRBuffer, SRHeap, SREncoder;
static BOOL SRProfileEnabled(void) {
  static BOOL enabled; static dispatch_once_t once;
  dispatch_once(&once, ^{ const char *v=getenv("GPU_ADAPTER_PERF_LOG");enabled=v&&!strcmp(v,"1"); });return enabled;
}
static BOOL SRSnapshotCacheEnabled(void) {
  const char *v=getenv("GPU_ADAPTER_SNAPSHOT_CACHE");return !v||strcmp(v,"0");
}
static uint64_t SRNow(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec;}
static BOOL SRVerbose(void) {
  static BOOL enabled; static dispatch_once_t once;
  dispatch_once(&once, ^{ const char *value = getenv("SOFTWARE_RESIDENCY_VERBOSE"); enabled = value && strcmp(value,"0") != 0; });
  return enabled;
}
static void SRTextureDiagnostics(NSString *path, MTLTextureDescriptor *descriptor) {
  static BOOL enabled; static dispatch_once_t once;
  dispatch_once(&once, ^{ const char *value = getenv("SOFTWARE_RESIDENCY_TEXTURE_LOG"); enabled = value && strcmp(value,"0") != 0; });
  if (!enabled) return;
  NSString *label = @"(MTLTextureDescriptor has no label)";
  if ([descriptor respondsToSelector:@selector(label)]) label = [(id)descriptor label] ?: @"";
  fprintf(stderr, "SOFTWARE_RESIDENCY texture path=%s label=%s storage=%lu type=%lu usage=0x%lx cpuCache=%lu resourceOptions=0x%lx pixelFormat=%lu dimensions=%lux%lux%lu levels=%lu arrayLength=%lu sampleCount=%lu\n",
    path.UTF8String, label.UTF8String, (unsigned long)descriptor.storageMode, (unsigned long)descriptor.textureType,
    (unsigned long)descriptor.usage, (unsigned long)descriptor.cpuCacheMode, (unsigned long)descriptor.resourceOptions,
    (unsigned long)descriptor.pixelFormat, (unsigned long)descriptor.width, (unsigned long)descriptor.height,
    (unsigned long)descriptor.depth, (unsigned long)descriptor.mipmapLevelCount, (unsigned long)descriptor.arrayLength,
    (unsigned long)descriptor.sampleCount);
}
static void SRRenderAttachmentDiagnostics(NSString *name, MTLRenderPassAttachmentDescriptor *attachment) {
  id<MTLTexture> texture = attachment.texture, resolve = attachment.resolveTexture;
  fprintf(stderr, "SOFTWARE_RESIDENCY renderAttachment name=%s texture=%p label=%s samples=%lu format=%lu storage=%lu usage=0x%lx dimensions=%lux%lux%lu level=%lu slice=%lu depthPlane=%lu load=%lu store=%lu storeOptions=0x%lx resolve=%p resolveSamples=%lu resolveFormat=%lu resolveLevel=%lu resolveSlice=%lu resolveDepthPlane=%lu\n",
    name.UTF8String, (__bridge void *)texture, texture.label.UTF8String ?: "", (unsigned long)texture.sampleCount,
    (unsigned long)texture.pixelFormat, (unsigned long)texture.storageMode, (unsigned long)texture.usage,
    (unsigned long)texture.width, (unsigned long)texture.height, (unsigned long)texture.depth,
    (unsigned long)attachment.level, (unsigned long)attachment.slice, (unsigned long)attachment.depthPlane,
    (unsigned long)attachment.loadAction, (unsigned long)attachment.storeAction, (unsigned long)attachment.storeActionOptions,
    (__bridge void *)resolve, (unsigned long)resolve.sampleCount, (unsigned long)resolve.pixelFormat,
    (unsigned long)attachment.resolveLevel, (unsigned long)attachment.resolveSlice, (unsigned long)attachment.resolveDepthPlane);
}
static void SRRenderPassDiagnostics(NSString *path, MTLRenderPassDescriptor *descriptor) {
  static BOOL enabled; static dispatch_once_t once;
  dispatch_once(&once, ^{ const char *value = getenv("SOFTWARE_RESIDENCY_RENDERPASS_LOG"); enabled = value && strcmp(value,"0") != 0; });
  if (!enabled) return;
  // Public getters only. In particular, do not inspect or reset any private
  // defaultColorSampleCount/defaultDepthSampleCount fields.
  fprintf(stderr, "SOFTWARE_RESIDENCY renderPass path=%s defaultRasterSampleCount=%lu renderTarget=%lux%lu arrayLength=%lu imageblockSampleLength=%lu threadgroupMemoryLength=%lu tile=%lux%lu visibilityBuffer=%p rasterizationRateMap=%p customSamplePositions=%lu supportColorAttachmentMapping=%u visibilityResultType=%ld\n",
    path.UTF8String, (unsigned long)descriptor.defaultRasterSampleCount,
    (unsigned long)descriptor.renderTargetWidth, (unsigned long)descriptor.renderTargetHeight,
    (unsigned long)descriptor.renderTargetArrayLength, (unsigned long)descriptor.imageblockSampleLength,
    (unsigned long)descriptor.threadgroupMemoryLength, (unsigned long)descriptor.tileWidth, (unsigned long)descriptor.tileHeight,
    (__bridge void *)descriptor.visibilityResultBuffer, (__bridge void *)descriptor.rasterizationRateMap,
    (unsigned long)[descriptor getSamplePositions:NULL count:0], descriptor.supportColorAttachmentMapping,
    (long)descriptor.visibilityResultType);
  for (NSUInteger i = 0; i < 8; ++i) {
    MTLRenderPassColorAttachmentDescriptor *attachment = descriptor.colorAttachments[i];
    SRRenderAttachmentDiagnostics([NSString stringWithFormat:@"color%lu",(unsigned long)i],attachment);
    MTLClearColor color = attachment.clearColor;
    fprintf(stderr, "SOFTWARE_RESIDENCY renderClear color%lu=[%g,%g,%g,%g]\n",(unsigned long)i,color.red,color.green,color.blue,color.alpha);
  }
  SRRenderAttachmentDiagnostics(@"depth",descriptor.depthAttachment);
  SRRenderAttachmentDiagnostics(@"stencil",descriptor.stencilAttachment);
  fprintf(stderr, "SOFTWARE_RESIDENCY renderDepthStencil clearDepth=%g depthResolveFilter=%lu clearStencil=%u stencilResolveFilter=%lu\n",
    descriptor.depthAttachment.clearDepth, (unsigned long)descriptor.depthAttachment.depthResolveFilter,
    descriptor.stencilAttachment.clearStencil, (unsigned long)descriptor.stencilAttachment.stencilResolveFilter);
}
@interface SRProxy : NSProxy {
@public id _native;
}
- (instancetype)initWithNative:(id)native;
- (id)srNativeObject;
@end

static id SRNative(id object) {
  if ([object respondsToSelector:@selector(srNativeObject)]) return [object srNativeObject];
  return object;
}
static void SRFail(NSString *reason) {
  fprintf(stderr, "SOFTWARE_RESIDENCY FAIL_CLOSED %s\n", reason.UTF8String);
  [NSException raise:NSInternalInconsistencyException format:@"Software residency: %@", reason];
}
static void SRCopyPublicAttachment(MTLRenderPassAttachmentDescriptor *source, MTLRenderPassAttachmentDescriptor *target) {
  target.texture = SRNative(source.texture); target.level = source.level; target.slice = source.slice; target.depthPlane = source.depthPlane;
  target.resolveTexture = SRNative(source.resolveTexture); target.resolveLevel = source.resolveLevel;
  target.resolveSlice = source.resolveSlice; target.resolveDepthPlane = source.resolveDepthPlane;
  target.loadAction = source.loadAction; target.storeAction = source.storeAction; target.storeActionOptions = source.storeActionOptions;
}
static MTLRenderPassDescriptor *SRNormalizePublicRenderPass(id<MTLDevice> genuineDevice, MTLRenderPassDescriptor *source) {
  const char *mode = getenv("GPU_ADAPTER_RENDERPASS_NORMALIZE");
  if (!mode || strcmp(mode,"1")) return source;
  if ((source.imageblockSampleLength || source.threadgroupMemoryLength || source.tileWidth || source.tileHeight) &&
      ![genuineDevice supportsFamily:MTLGPUFamilyApple4]) SRFail(@"public render-pass tile/imageblock parameters unsupported by genuine GPU");
  // Rebuild through public initializers/setters, NOT copy: a copy would carry
  // Apple-only, undocumented defaultColorSampleCount into the AMD descriptor.
  MTLRenderPassDescriptor *target = [MTLRenderPassDescriptor renderPassDescriptor];
  BOOL hasAttachments = NO;
  for (NSUInteger i = 0; i < 8; ++i) {
    MTLRenderPassColorAttachmentDescriptor *color = [MTLRenderPassColorAttachmentDescriptor new];
    SRCopyPublicAttachment(source.colorAttachments[i],color); color.clearColor = source.colorAttachments[i].clearColor;
    target.colorAttachments[i] = color; hasAttachments |= color.texture != nil;
  }
  MTLRenderPassDepthAttachmentDescriptor *depth = [MTLRenderPassDepthAttachmentDescriptor new];
  SRCopyPublicAttachment(source.depthAttachment,depth); depth.clearDepth = source.depthAttachment.clearDepth;
  depth.depthResolveFilter = source.depthAttachment.depthResolveFilter; target.depthAttachment = depth;
  MTLRenderPassStencilAttachmentDescriptor *stencil = [MTLRenderPassStencilAttachmentDescriptor new];
  SRCopyPublicAttachment(source.stencilAttachment,stencil); stencil.clearStencil = source.stencilAttachment.clearStencil;
  stencil.stencilResolveFilter = source.stencilAttachment.stencilResolveFilter; target.stencilAttachment = stencil;
  hasAttachments |= depth.texture != nil || stencil.texture != nil;
  target.visibilityResultBuffer = SRNative(source.visibilityResultBuffer);
  target.renderTargetArrayLength = source.renderTargetArrayLength;
  target.imageblockSampleLength = source.imageblockSampleLength; target.threadgroupMemoryLength = source.threadgroupMemoryLength;
  target.tileWidth = source.tileWidth; target.tileHeight = source.tileHeight;
  // Public API defines this default only for passes without attachments.
  target.defaultRasterSampleCount = hasAttachments ? 0 : source.defaultRasterSampleCount;
  target.renderTargetWidth = source.renderTargetWidth; target.renderTargetHeight = source.renderTargetHeight;
  target.rasterizationRateMap = SRNative(source.rasterizationRateMap);
  target.visibilityResultType = source.visibilityResultType; target.supportColorAttachmentMapping = source.supportColorAttachmentMapping;
  NSUInteger positionCount = [source getSamplePositions:NULL count:0];
  if (positionCount) {
    MTLSamplePosition *positions = calloc(positionCount,sizeof(MTLSamplePosition));
    if (!positions) SRFail(@"render sample-position allocation failed");
    NSUInteger copied = [source getSamplePositions:positions count:positionCount];
    if (copied != positionCount) { free(positions); SRFail(@"render sample positions changed concurrently"); }
    [target setSamplePositions:positions count:positionCount]; free(positions);
  }
  // The original public accessor was separately checked in a CPU-only probe:
  // this OS's Metal array has exactly four legal indices (0...3).
  for (NSUInteger i = 0; i < 4; ++i) {
    MTLRenderPassSampleBufferAttachmentDescriptor *attachment = [MTLRenderPassSampleBufferAttachmentDescriptor new];
    MTLRenderPassSampleBufferAttachmentDescriptor *original = source.sampleBufferAttachments[i];
    attachment.sampleBuffer = SRNative(original.sampleBuffer);
    attachment.startOfVertexSampleIndex = original.startOfVertexSampleIndex; attachment.endOfVertexSampleIndex = original.endOfVertexSampleIndex;
    attachment.startOfFragmentSampleIndex = original.startOfFragmentSampleIndex; attachment.endOfFragmentSampleIndex = original.endOfFragmentSampleIndex;
    target.sampleBufferAttachments[i] = attachment;
  }
  if (SRVerbose()) fprintf(stderr,"SOFTWARE_RESIDENCY rebuilt public renderPass hasAttachments=%u requestedDefaultRasterSamples=%lu actualDefaultRasterSamples=%lu\n",hasAttachments,(unsigned long)source.defaultRasterSampleCount,(unsigned long)target.defaultRasterSampleCount);
  return target;
}
static NSHashTable *SRStrongIdentitySet(void) {
  return [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
}
static NSHashTable *SRWeakIdentitySet(void) {
  return [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
}
@implementation SRProxy
- (instancetype)initWithNative:(id)native { _native = native; return self; }
- (id)srNativeObject { return _native; }
- (BOOL)respondsToSelector:(SEL)selector {
  return class_getInstanceMethod(object_getClass(self), selector) != NULL || [_native respondsToSelector:selector];
}
- (BOOL)conformsToProtocol:(Protocol *)protocol { return [_native conformsToProtocol:protocol]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
  // Outer tracing/classification proxies may ask us for the signature of an
  // implemented software method which the legacy native object lacks.
  Method ownMethod = class_getInstanceMethod(object_getClass(self), selector);
  if (ownMethod) return [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(ownMethod)];
  return [_native methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  // Unwrap our own proxy arguments before a native Metal method receives them.
  for (NSUInteger i = 2; i < invocation.methodSignature.numberOfArguments; ++i) {
    const char *type = [invocation.methodSignature getArgumentTypeAtIndex:i];
    while (*type && strchr("rnNoORV", *type)) ++type;
    if (*type != '@' || type[1] == '?') continue;
    __unsafe_unretained id object = nil;
    [invocation getArgument:&object atIndex:i];
    __unsafe_unretained id native = SRNative(object);
    if (native != object) [invocation setArgument:&native atIndex:i];
  }
  [invocation invokeWithTarget:_native];
}
@end

@interface SRContext : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSHashTable *registry;
@property(nonatomic, strong) NSHashTable *requestedSets;
@property(nonatomic) uint64_t declarations, completedBuffers;
@property(nonatomic) uint64_t snapshotCacheHits, snapshotCacheMisses;
@property(nonatomic) uint64_t snapshotNs, gatherNs, nativeDeclarationNs, submittedBuffers, presentRequests, nativeGPUNs;
@property(nonatomic) uint64_t captureNs, captureCalls, layoutQueryNs, layoutQueryCalls, textureSyncNs;
@property(nonatomic, strong) dispatch_source_t profileTimer;
@property(nonatomic) uint64_t generation;
@property(nonatomic) NSUInteger lastSnapshotReadOnly,lastSnapshotReadWrite,lastSnapshotHeaps,lastRegistryLive,lastContextSetCount,lastContextSetMembers,lastQueueSetCount,lastBufferSetCount,lastQueueSetMembers,lastBufferSetMembers;
@property(nonatomic) uint64_t pipelineCreationCalls,pipelineCreationFailures;
@property(nonatomic) uint64_t indexedDrawCalls,indexedDrawReturns;
@property(nonatomic) NSUInteger lastDrawType,lastDrawCount,lastDrawIndexType,lastDrawOffset,lastDrawBufferLength,lastDrawInstances,lastDrawBaseInstance;
@property(nonatomic) NSInteger lastDrawBaseVertex;
@property(nonatomic) uint64_t visibilityCalls, visibilityReturns;
@property(nonatomic) NSUInteger lastVisibilityMode,lastVisibilityOffset,lastVisibilityLength,lastVisibilityStorage,lastVisibilityType;
@property(nonatomic) BOOL lastVisibilityHasBuffer,lastVisibilityHasHeap,lastVisibilityHasPipeline,lastVisibilityColorMapping;
- (void)registerAllocation:(id)allocation;
- (NSArray *)snapshot;
- (uint64_t)generationSnapshot;
@end

@interface SRSet : NSObject<MTLResidencySet>
@property(nonatomic, strong) SRContext *context;
@property(nonatomic, strong) NSString *label;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSHashTable *pending;
@property(nonatomic, copy) NSArray *committed;
@property(nonatomic) BOOL requested;
- (NSArray *)committedSnapshot;
@end

static SRContext *SRContextForDevice(id<MTLDevice> device) {
  static NSMutableDictionary<NSNumber *, SRContext *> *contexts;
  @synchronized([SRContext class]) {
    if (!contexts) contexts = [NSMutableDictionary dictionary];
    id<MTLDevice> native = SRNative(device);
    NSNumber *key = @(native.registryID);
    SRContext *context = contexts[key];
    if (!context) {
      context = [SRContext new];
      context.device = native;
      context.lock = [NSLock new];
      context.registry = SRWeakIdentitySet();
      context.requestedSets = SRWeakIdentitySet();
      contexts[key] = context;
      if (SRProfileEnabled()) {
        context.profileTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
        dispatch_source_set_timer(context.profileTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,50000000);
        dispatch_source_set_event_handler(context.profileTimer, ^{
          [context.lock lock];
          uint64_t live=context.registry.count,submitted=context.submittedBuffers,completed=context.completedBuffers,presents=context.presentRequests;
          double snapshot=context.snapshotNs/1e6,gather=context.gatherNs/1e6,native=context.nativeDeclarationNs/1e6,gpu=context.nativeGPUNs/1e6;
          double capture=context.captureNs/1e6,layout=context.layoutQueryNs/1e6,sync=context.textureSyncNs/1e6;
          uint64_t captures=context.captureCalls,queries=context.layoutQueryCalls;
          uint64_t vc=context.visibilityCalls,vr=context.visibilityReturns;NSUInteger vm=context.lastVisibilityMode,vo=context.lastVisibilityOffset,vl=context.lastVisibilityLength,vs=context.lastVisibilityStorage,vt=context.lastVisibilityType;BOOL vb=context.lastVisibilityHasBuffer,vh=context.lastVisibilityHasHeap,vp=context.lastVisibilityHasPipeline,vmapping=context.lastVisibilityColorMapping;
          uint64_t dc=context.indexedDrawCalls,dr=context.indexedDrawReturns;NSUInteger dt=context.lastDrawType,dn=context.lastDrawCount,di=context.lastDrawIndexType,doff=context.lastDrawOffset,dl=context.lastDrawBufferLength,ds=context.lastDrawInstances,dbi=context.lastDrawBaseInstance;NSInteger dbv=context.lastDrawBaseVertex;
          uint64_t pc=context.pipelineCreationCalls,pf=context.pipelineCreationFailures;
          NSUInteger nro=context.lastSnapshotReadOnly,nrw=context.lastSnapshotReadWrite,nh=context.lastSnapshotHeaps,ng=context.lastRegistryLive,ncs=context.lastContextSetCount,ncm=context.lastContextSetMembers,nqs=context.lastQueueSetCount,nbs=context.lastBufferSetCount,nqm=context.lastQueueSetMembers,nbm=context.lastBufferSetMembers;
          [context.lock unlock];
          fprintf(stderr,"PIPELINE_STATE pid=%d monotonicNs=%llu synchronousCalls=%llu synchronousFailures=%llu NATIVE_RESULTS_UNCHANGED_ASYNC_NOT_COVERED\n",getpid(),(unsigned long long)SRNow(),(unsigned long long)pc,(unsigned long long)pf);
          fprintf(stderr,"RESOURCE_SCOPE pid=%d monotonicNs=%llu readOnlyResources=%lu readWriteResources=%lu heaps=%lu globalLiveRegistry=%lu contextRequestedSets=%lu contextCommittedMembers=%lu queueSets=%lu commandBufferSets=%lu queueCommittedMembers=%lu commandBufferCommittedMembers=%lu FULL_REGISTRY_COVERAGE_UNCHANGED_PUBLIC_METADATA_ONLY\n",getpid(),(unsigned long long)SRNow(),(unsigned long)nro,(unsigned long)nrw,(unsigned long)nh,(unsigned long)ng,(unsigned long)ncs,(unsigned long)ncm,(unsigned long)nqs,(unsigned long)nbs,(unsigned long)nqm,(unsigned long)nbm);
          if(dc)fprintf(stderr,"DRAW_STATE pid=%d monotonicNs=%llu calls=%llu returns=%llu type=%lu count=%lu indexType=%lu offset=%lu bufferLength=%lu instances=%lu baseVertex=%ld baseInstance=%lu EXACT_NATIVE_ARGUMENTS_NOT_GPU_OUTPUT\n",getpid(),(unsigned long long)SRNow(),(unsigned long long)dc,(unsigned long long)dr,(unsigned long)dt,(unsigned long)dn,(unsigned long)di,(unsigned long)doff,(unsigned long)dl,(unsigned long)ds,(long)dbv,(unsigned long)dbi);
          fprintf(stderr,"SR_PERF pid=%d monotonicNs=%llu liveAllocations=%llu submittedCBs=%llu completedCBs=%llu presentRequests=%llu snapshotMs=%.3f gatherMs=%.3f nativeDeclarationMs=%.3f completedGPUms=%.3f captureCalls=%llu captureMs=%.3f layoutQueryCalls=%llu layoutQueryMs=%.3f textureSyncCPUMs=%.3f CUMULATIVE_NOT_GAME_FPS\n",getpid(),(unsigned long long)SRNow(),(unsigned long long)live,(unsigned long long)submitted,(unsigned long long)completed,(unsigned long long)presents,snapshot,gather,native,gpu,(unsigned long long)captures,capture,(unsigned long long)queries,layout,sync);
          if(vc)fprintf(stderr,"VIS_STATE pid=%d calls=%llu returns=%llu mode=%lu offset=%lu bufferLength=%lu storage=%lu resultType=%lu hasBuffer=%u hasHeap=%u hasPipeline=%u colorMapping=%u EXACT_NATIVE_ARGUMENTS_NOT_OCCLUSION_RESULTS\n",getpid(),(unsigned long long)vc,(unsigned long long)vr,(unsigned long)vm,(unsigned long)vo,(unsigned long)vl,(unsigned long)vs,(unsigned long)vt,vb,vh,vp,vmapping);
          NSDictionary *ts=TSTextureStorageStatistics();
          fprintf(stderr,"SR_MEMORY pid=%d nativeAllocatedBytes=%llu recommendedWorkingSetBytes=%llu convertedTextures=%llu liveConvertedTextures=%llu nativeTextureSynchronizations=%llu SCOPE_NATIVE_PUBLIC_METADATA_NOT_VRAM_ONLY\n",getpid(),(unsigned long long)context.device.currentAllocatedSize,(unsigned long long)context.device.recommendedMaxWorkingSetSize,[ts[@"convertedTextures"] unsignedLongLongValue],[ts[@"liveConvertedTextures"] unsignedLongLongValue],[ts[@"nativeTextureSynchronizations"] unsignedLongLongValue]);
        });
        dispatch_resume(context.profileTimer);
      }
    }
    return context;
  }
}

static char SRNativeAllocationKindKey;
@implementation SRContext
- (void)registerAllocation:(id)allocation {
  allocation = SRNative(allocation);
  if (!allocation) return;
  BOOL resource = [allocation conformsToProtocol:@protocol(MTLResource)];
  BOOL heap = [allocation conformsToProtocol:@protocol(MTLHeap)];
  if (!resource && !heap) SRFail([NSString stringWithFormat:@"unsupported allocation class %@", [allocation class]]);
  id<MTLDevice> owner = [allocation device];
  if (owner.registryID != _device.registryID) SRFail(@"cross-device allocation");
  if (!objc_getAssociatedObject(allocation,&SRNativeAllocationKindKey)) {
    NSUInteger kind=heap?2:1;
    if (!heap && [allocation conformsToProtocol:@protocol(MTLTexture)]) {
      MTLTextureUsage usage=[(id<MTLTexture>)allocation usage];
      if ((usage&MTLTextureUsageShaderRead) && !(usage&(MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget))) kind=3;
    }
    objc_setAssociatedObject(allocation,&SRNativeAllocationKindKey,@(kind),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  [_lock lock];
  if (![_registry containsObject:allocation]) { [_registry addObject:allocation]; ++_generation; }
  [_lock unlock];
}
- (uint64_t)generationSnapshot { [_lock lock]; uint64_t value = _generation; [_lock unlock]; return value; }
- (NSArray *)snapshot {
  [_lock lock];
  NSArray *allocations = _registry.allObjects;
  NSArray<SRSet *> *requested = _requestedSets.allObjects;
  [_lock unlock];
  NSHashTable *all = SRStrongIdentitySet();
  for (id allocation in allocations) [all addObject:allocation];
  NSUInteger committedMembers=0;
  for(SRSet *set in requested){NSArray *members=set.committedSnapshot;committedMembers+=members.count;for(id allocation in members)[all addObject:allocation];}
  if(SRProfileEnabled()){[_lock lock];_lastRegistryLive=allocations.count;_lastContextSetCount=requested.count;_lastContextSetMembers=committedMembers;[_lock unlock];}
  return all.allObjects;
}
@end

@implementation SRSet
- (instancetype)init {
  if ((self = [super init])) { _lock = [NSLock new]; _pending = SRStrongIdentitySet(); _committed = @[]; }
  return self;
}
- (id<MTLDevice>)device { return _context.device; }
- (void)addAllocation:(id<MTLAllocation>)allocation {
  id real = SRNative(allocation);
  [_context registerAllocation:real];
  [_lock lock]; [_pending addObject:real]; [_lock unlock];
}
- (void)addAllocations:(const id<MTLAllocation>[])allocations count:(NSUInteger)count {
  for (NSUInteger i = 0; i < count; ++i) [self addAllocation:allocations[i]];
}
- (void)removeAllocation:(id<MTLAllocation>)allocation {
  // Metal allocations may run a caller's bytes-no-copy deallocator on their
  // final release. Never permit such client callbacks while holding our lock.
  __attribute__((objc_precise_lifetime)) id releaseAfterUnlock = SRNative(allocation);
  [_lock lock]; [_pending removeObject:releaseAfterUnlock]; [_lock unlock];
}
- (void)removeAllocations:(const id<MTLAllocation>[])allocations count:(NSUInteger)count {
  for (NSUInteger i = 0; i < count; ++i) [self removeAllocation:allocations[i]];
}
- (void)removeAllAllocations {
  __attribute__((objc_precise_lifetime)) NSArray *releaseAfterUnlock = nil;
  [_lock lock]; releaseAfterUnlock = _pending.allObjects; [_pending removeAllObjects]; [_lock unlock];
}
- (BOOL)containsAllocation:(id<MTLAllocation>)allocation {
  [_lock lock]; BOOL found = [_pending containsObject:SRNative(allocation)]; [_lock unlock]; return found;
}
- (NSArray *)allAllocations { [_lock lock]; NSArray *all = _pending.allObjects; [_lock unlock]; return all; }
- (NSUInteger)allocationCount { [_lock lock]; NSUInteger count = _pending.count; [_lock unlock]; return count; }
- (NSArray *)committedSnapshot { [_lock lock]; NSArray *all = _committed; [_lock unlock]; return all; }
- (void)commit {
  __attribute__((objc_precise_lifetime)) NSArray *releaseAfterUnlock = nil;
  [_lock lock]; releaseAfterUnlock = _committed; _committed = _pending.allObjects; [_lock unlock];
}
- (uint64_t)allocatedSize {
  NSArray *all = self.committedSnapshot;
  NSHashTable *heaps = SRStrongIdentitySet();
  for (id a in all) if ([a conformsToProtocol:@protocol(MTLHeap)]) [heaps addObject:a];
  uint64_t size = 0;
  for (id a in all) {
    if ([a conformsToProtocol:@protocol(MTLHeap)]) { size += [(id<MTLHeap>)a size]; continue; }
    id<MTLResource> resource = a;
    if (resource.heap && [heaps containsObject:resource.heap]) continue;
    size += resource.allocatedSize;
  }
  return size;
}
- (void)requestResidency {
  // Keep state and registry mutation in the same serialized transaction, so a
  // simultaneous request/end cannot leave stale global membership.
  [_context.lock lock]; [_lock lock];
  _requested = YES; [_context.requestedSets addObject:self];
  [_lock unlock]; [_context.lock unlock];
}
- (void)endResidency {
  [_context.lock lock]; [_lock lock];
  _requested = NO; [_context.requestedSets removeObject:self];
  [_lock unlock]; [_context.lock unlock];
}
@end

@interface SRQueue : SRProxy
@property(nonatomic, strong) SRContext *context;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSHashTable *sets;
- (NSArray<SRSet *> *)setsSnapshot;
@end

@interface SRDeclarationMetadata : NSObject
@property(nonatomic, strong) NSData *resources;
@property(nonatomic, strong) NSData *readOnlyResources;
@property(nonatomic, strong) NSData *heaps;
@property(nonatomic) NSUInteger resourceCount, readOnlyCount, heapCount;
@end
@implementation SRDeclarationMetadata
@end
static SRDeclarationMetadata *SRClassifySnapshot(NSArray *allocations,SRContext *context) {
  SRDeclarationMetadata *m=[SRDeclarationMetadata new];
  NSMutableData *resources=[NSMutableData dataWithLength:allocations.count*sizeof(id)],*heaps=[NSMutableData dataWithLength:allocations.count*sizeof(id)];
  NSMutableData *readOnly=[NSMutableData dataWithLength:allocations.count*sizeof(id)];
  id __unsafe_unretained *rp=(id __unsafe_unretained *)resources.mutableBytes,*hp=(id __unsafe_unretained *)heaps.mutableBytes,*rop=(id __unsafe_unretained *)readOnly.mutableBytes;
  // Borrowed pointers: the complete allocation snapshot/CB retention owns
  // every object until GPU completion. Protocol/classification is immutable;
  // aliasability is deliberately still checked at each GPU execution.
  for (__unsafe_unretained id a in allocations) {
    NSNumber *kind=objc_getAssociatedObject(a,&SRNativeAllocationKindKey);
    if(!kind){[context registerAllocation:a];kind=objc_getAssociatedObject(a,&SRNativeAllocationKindKey);}
    switch(kind.unsignedIntegerValue){
      case 1:rp[m.resourceCount++]=a;break;
      case 2:hp[m.heapCount++]=a;break;
      case 3:rop[m.readOnlyCount++]=a;break;
      default:SRFail(@"unknown validated allocation kind");
    }
  }
  m.resources=resources;m.readOnlyResources=readOnly;m.heaps=heaps;
  if(SRProfileEnabled()){[context.lock lock];context.lastSnapshotReadOnly=m.readOnlyCount;context.lastSnapshotReadWrite=m.resourceCount;context.lastSnapshotHeaps=m.heapCount;[context.lock unlock];}
  return m;
}
@interface SRSnapshotCache : NSObject
@property(nonatomic, copy) NSArray *allocations;
@property(nonatomic, strong) SRDeclarationMetadata *metadata;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t visibilityCalls, visibilityReturns;
@property(nonatomic) NSUInteger lastVisibilityMode,lastVisibilityOffset,lastVisibilityLength,lastVisibilityStorage,lastVisibilityType;
@property(nonatomic) BOOL lastVisibilityHasBuffer,lastVisibilityHasHeap,lastVisibilityHasPipeline,lastVisibilityColorMapping;
@end
@implementation SRSnapshotCache
@end

@interface SRBuffer : SRProxy
@property(nonatomic, strong) SRQueue *queue;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSHashTable *sets;
@property(nonatomic, strong) NSHashTable *retainedAllocations;
@property(nonatomic, strong) NSHashTable *retainedAuxiliaryObjects;
@property(nonatomic, strong) SRSnapshotCache *snapshotCache;
@property(nonatomic) BOOL submitted;
- (NSArray *)captureSnapshot;
- (NSArray *)captureSnapshotWithMetadata:(SRDeclarationMetadata * __autoreleasing *)metadata;
- (void)captureAllocation:(id)allocation;
- (void)captureAuxiliaryObject:(id)object;
- (void)captureRenderPass:(MTLRenderPassDescriptor *)descriptor;
@end

@interface SREncoder : SRProxy
@property(nonatomic, strong) SRBuffer *buffer;
@property(nonatomic, copy) NSString *kind;
@property(nonatomic, strong) NSHashTable *declared;
@property(nonatomic) MTLRenderStages declaredStages;
@property(nonatomic) BOOL ended;
@property(nonatomic) BOOL declaredOnce;
@property(nonatomic) uint64_t lastGeneration;
@property(nonatomic) NSUInteger visibilityLength,visibilityStorage,visibilityType;
@property(nonatomic) BOOL visibilityHasBuffer,visibilityHasHeap,pipelineBound,visibilityColorMapping;
- (void)declareBeforeExecution:(SEL)selector;
@end

static id SRNewEncoder(id native, SRBuffer *buffer, NSString *kind) {
  if (!native) return nil;
  SREncoder *encoder = [[SREncoder alloc] initWithNative:native];
  encoder.buffer = buffer; encoder.kind = kind;
  // Membership tokens only. The CB owns every declared native object, so a
  // second strong retain for each object on each encoder is unnecessary.
  encoder.declared=[NSHashTable hashTableWithOptions:NSPointerFunctionsOpaqueMemory|NSPointerFunctionsObjectPointerPersonality];
  return encoder;
}
static id SRNewBuffer(id<MTLCommandBuffer> native, SRQueue *queue) {
  if (!native) return nil;
  SRBuffer *buffer = [[SRBuffer alloc] initWithNative:native];
  buffer.queue = queue; buffer.lock = [NSLock new];
  buffer.sets = SRStrongIdentitySet(); buffer.retainedAllocations = SRStrongIdentitySet();
  buffer.retainedAuxiliaryObjects = SRStrongIdentitySet();
  buffer.snapshotCache = [SRSnapshotCache new];
  return buffer;
}
static id SRNewRenderEncoder(id native,SRBuffer *buffer,NSString *kind,MTLRenderPassDescriptor *descriptor){
  SREncoder *e=SRNewEncoder(native,buffer,kind);if(!e)return nil;
  id<MTLBuffer> visibility=SRNative(descriptor.visibilityResultBuffer);
  e.visibilityHasBuffer=visibility!=nil;e.visibilityLength=visibility.length;e.visibilityStorage=visibility.storageMode;e.visibilityType=descriptor.visibilityResultType;e.visibilityHasHeap=visibility.heap!=nil;e.visibilityColorMapping=descriptor.supportColorAttachmentMapping;
  return e;
}
static void SRRequireSoftwareSet(id set) {
  if (![set isKindOfClass:[SRSet class]]) SRFail(@"cannot mix native/foreign residency sets with software queue");
}

@implementation SRQueue
- (NSArray *)setsSnapshot { [_lock lock]; NSArray *sets = _sets.allObjects; [_lock unlock]; return sets; }
- (id<MTLCommandBuffer>)commandBuffer { return SRNewBuffer([(id<MTLCommandQueue>)_native commandBuffer], self); }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)descriptor {
  return SRNewBuffer([(id<MTLCommandQueue>)_native commandBufferWithDescriptor:descriptor], self);
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences {
  return SRNewBuffer([(id<MTLCommandQueue>)_native commandBufferWithUnretainedReferences], self);
}
- (void)addResidencySet:(id<MTLResidencySet>)set {
  SRRequireSoftwareSet(set);
  if (set.device.registryID != _context.device.registryID) SRFail(@"cross-device residency set");
  [_lock lock]; [_sets addObject:set]; [_lock unlock];
}
- (void)addResidencySets:(const id<MTLResidencySet>[])sets count:(NSUInteger)count {
  for (NSUInteger i = 0; i < count; ++i) [self addResidencySet:sets[i]];
}
- (void)removeResidencySet:(id<MTLResidencySet>)set {
  __attribute__((objc_precise_lifetime)) id releaseAfterUnlock = set;
  [_lock lock]; [_sets removeObject:releaseAfterUnlock]; [_lock unlock];
}
- (void)removeResidencySets:(const id<MTLResidencySet>[])sets count:(NSUInteger)count {
  for (NSUInteger i = 0; i < count; ++i) [self removeResidencySet:sets[i]];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  if ([NSStringFromSelector(invocation.selector) hasPrefix:@"commandBuffer"]) SRFail(@"uncovered command-buffer creation method");
  [super forwardInvocation:invocation];
}
@end

@implementation SRBuffer
- (void)captureAuxiliaryObject:(id)object {
  object = SRNative(object);
  if (!object) return;
  [_lock lock]; [_retainedAuxiliaryObjects addObject:object]; [_lock unlock];
}
- (void)captureAllocation:(id)allocation {
  uint64_t started=SRProfileEnabled()?SRNow():0;
  allocation = SRNative(allocation);
  if (!allocation) return;
  [_queue.context registerAllocation:allocation];
  [_lock lock];
  if (![_retainedAllocations containsObject:allocation]) {
    [_retainedAllocations addObject:allocation];
    // Existing retained allocations still own every cached member here.
    _snapshotCache.allocations = nil;
    _snapshotCache.metadata = nil;
  }
  [_lock unlock];
  if ([allocation conformsToProtocol:@protocol(MTLResource)]) {
    id<MTLHeap> heap = [(id<MTLResource>)allocation heap];
    if (heap) {
      [_lock lock];
      if (![_retainedAllocations containsObject:heap]) {
        [_retainedAllocations addObject:heap]; _snapshotCache.allocations = nil;_snapshotCache.metadata=nil;
      }
      [_lock unlock];
    }
  }
  if(started){[_queue.context.lock lock];++_queue.context.captureCalls;_queue.context.captureNs+=SRNow()-started;[_queue.context.lock unlock];}
}
- (NSArray *)captureSnapshot {
  return [self captureSnapshotWithMetadata:NULL];
}
- (NSArray *)captureSnapshotWithMetadata:(SRDeclarationMetadata * __autoreleasing *)metadata {
  uint64_t started=SRProfileEnabled()?SRNow():0;
  // Coverage remains the complete global live registry. Every set member was
  // registered before commit, so set membership cannot introduce an unseen
  // object without changing this generation. Within a CB, retained members
  // cannot vanish from the weak registry. Direct/foreign bindings invalidate
  // the cache above; new registrations invalidate it via this generation.
  uint64_t generation = _queue.context.generationSnapshot;
  [_lock lock];
  NSArray *cached = _snapshotCache.allocations;
  BOOL hit = SRSnapshotCacheEnabled() && cached && _snapshotCache.generation == generation;
  if(hit&&metadata){if(!_snapshotCache.metadata)_snapshotCache.metadata=SRClassifySnapshot(cached,_queue.context);*metadata=_snapshotCache.metadata;}
  [_lock unlock];
  if (hit) {
    [_queue.context.lock lock]; ++_queue.context.snapshotCacheHits;if(started)_queue.context.snapshotNs+=SRNow()-started; [_queue.context.lock unlock];
    return cached;
  }
  NSArray *registry = _queue.context.snapshot;
  NSArray *queueSets = _queue.setsSnapshot;
  [_lock lock]; NSArray *ownSets = _sets.allObjects; [_lock unlock];
  if(SRProfileEnabled()){[_queue.context.lock lock];_queue.context.lastQueueSetCount=queueSets.count;_queue.context.lastBufferSetCount=ownSets.count;[_queue.context.lock unlock];}
  NSHashTable *all = SRStrongIdentitySet();
  for (id a in registry) [all addObject:a];
  NSUInteger queueMembers=0,bufferMembers=0;
  for (SRSet *set in queueSets) {NSArray *members=set.committedSnapshot;queueMembers+=members.count;for(id a in members)[all addObject:a];}
  for (SRSet *set in ownSets) {NSArray *members=set.committedSnapshot;bufferMembers+=members.count;for(id a in members)[all addObject:a];}
  if(SRProfileEnabled()){[_queue.context.lock lock];_queue.context.lastQueueSetMembers=queueMembers;_queue.context.lastBufferSetMembers=bufferMembers;[_queue.context.lock unlock];}
  // Every registry member and every software-set allocation was already
  // unwrapped, owner-checked and registered by registerAllocation/addAllocation.
  // Re-running that full validation for every live resource on every encoder
  // adds CPU cost without changing membership. Retain the same complete union
  // and native parent heaps; do not narrow declarations or synchronization.
  NSArray *snapshot = all.allObjects;
  [_lock lock];
  for (id a in snapshot) {
    if ([_retainedAllocations containsObject:a]) continue;
    [_retainedAllocations addObject:a];
    if ([a conformsToProtocol:@protocol(MTLResource)]) {
      id<MTLHeap> heap = [(id<MTLResource>)a heap];
      if (heap) [_retainedAllocations addObject:heap];
    }
  }
  NSArray *retained = _retainedAllocations.allObjects;
  _snapshotCache.allocations = retained;
  _snapshotCache.metadata=metadata?SRClassifySnapshot(retained,_queue.context):nil;
  if(metadata)*metadata=_snapshotCache.metadata;
  // Use the generation read BEFORE the snapshot. A concurrent registration
  // forces another scan rather than being wrongly marked already captured.
  _snapshotCache.generation = generation;
  [_lock unlock];
  [_queue.context.lock lock]; ++_queue.context.snapshotCacheMisses;if(started)_queue.context.snapshotNs+=SRNow()-started; [_queue.context.lock unlock];
  return retained;
}
- (void)captureRenderPass:(MTLRenderPassDescriptor *)descriptor {
  // The native encoder copies its descriptor, but an unretained command buffer
  // does not own the descriptor's texture/buffer dependencies. Capture them
  // now, before the caller can drop the descriptor and before the first draw.
  for (NSUInteger i = 0; i < 8; ++i) {
    [self captureAllocation:descriptor.colorAttachments[i].texture];
    [self captureAllocation:descriptor.colorAttachments[i].resolveTexture];
  }
  [self captureAllocation:descriptor.depthAttachment.texture];
  [self captureAllocation:descriptor.depthAttachment.resolveTexture];
  [self captureAllocation:descriptor.stencilAttachment.texture];
  [self captureAllocation:descriptor.stencilAttachment.resolveTexture];
  [self captureAllocation:descriptor.visibilityResultBuffer];
  // Snapshot other public dependencies as well (counter sample buffers and
  // rasterization-rate map). This copy is used ONLY for lifetime, never sent
  // to the GPU; opt-in GPU normalization uses public reconstruction above.
  [self captureAuxiliaryObject:[descriptor copy]];
}
- (id<MTLCommandQueue>)commandQueue { return (id<MTLCommandQueue>)_queue; }
- (void)useResidencySet:(id<MTLResidencySet>)set {
  SRRequireSoftwareSet(set);
  if (set.device.registryID != _queue.context.device.registryID) SRFail(@"cross-device command-buffer set");
  [_lock lock]; [_sets addObject:set]; [_lock unlock];
}
- (void)useResidencySets:(const id<MTLResidencySet>[])sets count:(NSUInteger)count {
  for (NSUInteger i = 0; i < count; ++i) [self useResidencySet:sets[i]];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
  return SRNewEncoder([(id<MTLCommandBuffer>)_native computeCommandEncoder], self, @"compute");
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)type {
  return SRNewEncoder([(id<MTLCommandBuffer>)_native computeCommandEncoderWithDispatchType:type], self, @"compute");
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)descriptor {
  [self captureAuxiliaryObject:[descriptor copy]];
  return SRNewEncoder([(id<MTLCommandBuffer>)_native computeCommandEncoderWithDescriptor:descriptor], self, @"compute");
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
  SRRenderPassDiagnostics(@"renderCommandEncoder",descriptor);
  descriptor = SRNormalizePublicRenderPass(_queue.context.device,descriptor);
  SRRenderPassDiagnostics(@"renderCommandEncoder.publicNormalized",descriptor);
  [self captureRenderPass:descriptor];
  return SRNewRenderEncoder([(id<MTLCommandBuffer>)_native renderCommandEncoderWithDescriptor:descriptor], self, @"render",descriptor);
}
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
  SRRenderPassDiagnostics(@"parallelRenderCommandEncoder",descriptor);
  descriptor = SRNormalizePublicRenderPass(_queue.context.device,descriptor);
  SRRenderPassDiagnostics(@"parallelRenderCommandEncoder.publicNormalized",descriptor);
  [self captureRenderPass:descriptor];
  return SRNewRenderEncoder([(id<MTLCommandBuffer>)_native parallelRenderCommandEncoderWithDescriptor:descriptor], self, @"parallel",descriptor);
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder { return SRNewEncoder([(id<MTLCommandBuffer>)_native blitCommandEncoder], self, @"blit"); }
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)descriptor {
  [self captureAuxiliaryObject:[descriptor copy]];
  return SRNewEncoder([(id<MTLCommandBuffer>)_native blitCommandEncoderWithDescriptor:descriptor], self, @"blit");
}
- (void)commit {
  [_lock lock];
  if (_submitted) { [_lock unlock]; SRFail(@"command buffer submitted twice"); }
  _submitted = YES;
  [_lock unlock];
  // Snapshot forwarding may create an autoreleased array. Drain that local
  // ownership before submission so only the explicit GPU-completion retention
  // keeps resources alive, rather than the caller's possibly long-lived pool.
  @autoreleasepool {
    NSArray *submissionAllocations = [self captureSnapshot];
    uint64_t syncStart=SRProfileEnabled()?SRNow():0;
    TSEncodeManagedTextureSynchronization((id<MTLCommandBuffer>)_native, submissionAllocations);
    if(syncStart){[_queue.context.lock lock];_queue.context.textureSyncNs+=SRNow()-syncStart;[_queue.context.lock unlock];}
  }
  // Strong state survives until native completion even when the caller drops
  // the wrapper or asks for commandBufferWithUnretainedReferences.
  NSHashTable *keepAlive = _retainedAllocations;
  NSHashTable *auxiliaryKeepAlive = _retainedAuxiliaryObjects;
  SRSnapshotCache *snapshotCache = _snapshotCache;
  NSLock *lock = _lock;
  SRContext *context = _queue.context;
  if(SRProfileEnabled()){[context.lock lock];++context.submittedBuffers;[context.lock unlock];}
  [(id<MTLCommandBuffer>)_native addCompletedHandler:^(id<MTLCommandBuffer> native) {
    // Do not run client resource deallocators while the command-buffer lock is
    // held. Keep a temporary strong array until after unlocking.
    __attribute__((objc_precise_lifetime)) NSArray *releaseAfterUnlock = nil;
    __attribute__((objc_precise_lifetime)) NSArray *releaseAuxiliaryAfterUnlock = nil;
    __attribute__((objc_precise_lifetime)) NSArray *releaseCachedAfterUnlock = nil;
    __attribute__((objc_precise_lifetime)) SRDeclarationMetadata *releaseMetadataAfterUnlock = nil;
    [lock lock]; releaseAfterUnlock = keepAlive.allObjects; NSUInteger count = releaseAfterUnlock.count;
    releaseAuxiliaryAfterUnlock = auxiliaryKeepAlive.allObjects;
    releaseCachedAfterUnlock = snapshotCache.allocations; snapshotCache.allocations = nil;
    releaseMetadataAfterUnlock=snapshotCache.metadata;snapshotCache.metadata=nil;
    [keepAlive removeAllObjects]; [auxiliaryKeepAlive removeAllObjects]; [lock unlock];
    double gpuSeconds=SRProfileEnabled()&&native.GPUEndTime>native.GPUStartTime?native.GPUEndTime-native.GPUStartTime:0;
    [context.lock lock]; ++context.completedBuffers;if(gpuSeconds>0)context.nativeGPUNs+=(uint64_t)(gpuSeconds*1e9); [context.lock unlock];
    if(native.status==MTLCommandBufferStatusError)fprintf(stderr,"SR_PERF GPU_COMMAND_ERROR status=%lu error=%s\n",(unsigned long)native.status,native.error.localizedDescription.UTF8String?:"");
    if (SRVerbose()) fprintf(stderr, "SOFTWARE_RESIDENCY completed status=%lu releasedAllocationRefs=%lu\n", (unsigned long)native.status, (unsigned long)count);
  }];
  [(id<MTLCommandBuffer>)_native commit];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  NSString *name = NSStringFromSelector(invocation.selector);
  if(SRProfileEnabled()&&[name hasPrefix:@"presentDrawable"]){[_queue.context.lock lock];++_queue.context.presentRequests;[_queue.context.lock unlock];}
  if ([name containsString:@"CommandEncoder"]) SRFail([@"uncovered encoder: " stringByAppendingString:name]);
  for (NSUInteger i = 2; i < invocation.methodSignature.numberOfArguments; ++i) {
    const char *type = [invocation.methodSignature getArgumentTypeAtIndex:i];
    while (*type && strchr("rnNoORV",*type)) ++type;
    if (*type != '@' || type[1] == '?') continue;
    __unsafe_unretained id object = nil; [invocation getArgument:&object atIndex:i]; object = SRNative(object);
    if ([object conformsToProtocol:@protocol(MTLResource)] || [object conformsToProtocol:@protocol(MTLHeap)]) [self captureAllocation:object];
    else [self captureAuxiliaryObject:object];
  }
  [super forwardInvocation:invocation];
}
@end

@implementation SREncoder
- (void)endEncoding {
  if (_ended) SRFail(@"encoder ended twice");
  [(id<MTLCommandEncoder>)_native endEncoding];
  _ended = YES;
  [_declared removeAllObjects];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoder {
  if (![_kind isEqualToString:@"parallel"]) SRFail(@"render child on non-parallel encoder");
  SREncoder *e=SRNewEncoder([(id<MTLParallelRenderCommandEncoder>)_native renderCommandEncoder],_buffer,@"render");
  e.visibilityHasBuffer=_visibilityHasBuffer;e.visibilityLength=_visibilityLength;e.visibilityStorage=_visibilityStorage;e.visibilityType=_visibilityType;e.visibilityHasHeap=_visibilityHasHeap;e.visibilityColorMapping=_visibilityColorMapping;return (id)e;
}
// Keep indexed draw arguments in documented typed calls, while retaining the
// same full resource declarations and completion-time ownership as generic forwarding.
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:(NSUInteger)offset instanceCount:(NSUInteger)instances baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
  id<MTLBuffer> real=SRNative(buffer);[_buffer captureAllocation:real];[self declareBeforeExecution:_cmd];
  SRContext *context=_buffer.queue.context;BOOL trace=SRProfileEnabled();
  if(trace){[context.lock lock];++context.indexedDrawCalls;context.lastDrawType=type;context.lastDrawCount=count;context.lastDrawIndexType=indexType;context.lastDrawOffset=offset;context.lastDrawBufferLength=real.length;context.lastDrawInstances=instances;context.lastDrawBaseVertex=baseVertex;context.lastDrawBaseInstance=baseInstance;[context.lock unlock];}
  [(id<MTLRenderCommandEncoder>)_native drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:real indexBufferOffset:offset instanceCount:instances baseVertex:baseVertex baseInstance:baseInstance];
  if(trace){[context.lock lock];++context.indexedDrawReturns;[context.lock unlock];}
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count {
  [self declareBeforeExecution:_cmd];[(id<MTLRenderCommandEncoder>)_native drawPrimitives:type vertexStart:start vertexCount:count];
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipeline {
  id<MTLRenderPipelineState> real=SRNative(pipeline);[_buffer captureAuxiliaryObject:real];_pipelineBound=real!=nil;
  [(id<MTLRenderCommandEncoder>)_native setRenderPipelineState:real];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
  if(_ended)SRFail(@"visibility state after endEncoding");
  BOOL trace=SRProfileEnabled();SRContext *context=_buffer.queue.context;
  if(trace){[context.lock lock];++context.visibilityCalls;context.lastVisibilityMode=mode;context.lastVisibilityOffset=offset;context.lastVisibilityLength=_visibilityLength;context.lastVisibilityStorage=_visibilityStorage;context.lastVisibilityType=_visibilityType;context.lastVisibilityHasBuffer=_visibilityHasBuffer;context.lastVisibilityHasHeap=_visibilityHasHeap;context.lastVisibilityHasPipeline=_pipelineBound;context.lastVisibilityColorMapping=_visibilityColorMapping;[context.lock unlock];}
  // Exact original arguments to the documented, typed native method. No
  // query disabling, synthetic results or changed accumulation/storage policy.
  [(id<MTLRenderCommandEncoder>)_native setVisibilityResultMode:mode offset:offset];
  if(trace){[context.lock lock];++context.visibilityReturns;[context.lock unlock];}
}
- (void)declareBeforeExecution:(SEL)selector {
  if (_ended) SRFail(@"GPU work encoded after endEncoding");
  NSString *name = NSStringFromSelector(selector);
  MTLRenderStages stages = MTLRenderStageVertex | MTLRenderStageFragment;
  if ([name containsString:@"Mesh"]) stages |= MTLRenderStageObject | MTLRenderStageMesh;
  if ([name containsString:@"Tile"]) {
    // Tile shaders are Apple-family functionality. The genuine AMD device's
    // capability is used, never the outer experimental Apple7 classification.
    if (![_buffer.queue.context.device supportsFamily:MTLGPUFamilyApple4]) SRFail(@"tile shader execution unsupported by genuine GPU");
    stages |= MTLRenderStageTile;
  }
  BOOL extendStages = [_kind isEqualToString:@"render"] && (stages & ~_declaredStages);
  uint64_t generation = _buffer.queue.context.generationSnapshot;
  if (_declaredOnce && !extendStages && _lastGeneration == generation) return;
  // Remember the generation read BEFORE taking the snapshot. A concurrent
  // registration can only force another scan, never make us skip a new object.
  BOOL firstDeclaration=!_declaredOnce;
  SRDeclarationMetadata *metadata=nil;
  BOOL shaderEncoder=[_kind isEqualToString:@"compute"]||[_kind isEqualToString:@"render"];
  __attribute__((objc_precise_lifetime)) NSArray *allocations=[_buffer captureSnapshotWithMetadata:shaderEncoder?&metadata:NULL];
  uint64_t gathering=SRProfileEnabled()?SRNow():0;
  _lastGeneration = generation; _declaredOnce = YES;
  if ([_kind isEqualToString:@"blit"] || [_kind isEqualToString:@"parallel"]) return;
  if (extendStages) _declaredStages |= stages;
  id<MTLResource> __unsafe_unretained *sourceResources=(id<MTLResource> __unsafe_unretained *)metadata.resources.bytes;
  id<MTLHeap> __unsafe_unretained *sourceHeaps=(id<MTLHeap> __unsafe_unretained *)metadata.heaps.bytes;
  id<MTLResource> __unsafe_unretained *rawResources=metadata.resourceCount?(id<MTLResource> __unsafe_unretained *)calloc(metadata.resourceCount,sizeof(id)):NULL;
  id<MTLHeap> __unsafe_unretained *rawHeaps=metadata.heapCount?(id<MTLHeap> __unsafe_unretained *)calloc(metadata.heapCount,sizeof(id)):NULL;
  if((metadata.resourceCount&&!rawResources)||(metadata.heapCount&&!rawHeaps))SRFail(@"declaration allocation failed");
  id<MTLResource> __unsafe_unretained *sourceReadOnly=(id<MTLResource> __unsafe_unretained *)metadata.readOnlyResources.bytes;
  id<MTLResource> __unsafe_unretained *rawReadOnly=metadata.readOnlyCount?(id<MTLResource> __unsafe_unretained *)calloc(metadata.readOnlyCount,sizeof(id)):NULL;
  if(metadata.readOnlyCount&&!rawReadOnly)SRFail(@"read-only declaration allocation failed");
  NSUInteger resourceCount=0,heapCount=0,readOnlyCount=0;
  for(NSUInteger i=0;i<metadata.heapCount;i++){
    __unsafe_unretained id<MTLHeap> heap=sourceHeaps[i];
    if(!firstDeclaration&&!extendStages&&[_declared containsObject:heap])continue;
    rawHeaps[heapCount++]=heap;[_declared addObject:heap];
  }
  for(NSUInteger i=0;i<metadata.resourceCount;i++){
    __unsafe_unretained id<MTLResource> resource=sourceResources[i];
    if(!firstDeclaration&&!extendStages&&[_declared containsObject:resource])continue;
    // Aliasability is mutable and must remain a genuine per-execution query.
    if(resource.isAliasable)continue;
    rawResources[resourceCount++]=resource;[_declared addObject:resource];
  }
  // Every allocation remains covered. Only immutable genuine texture usage
  // that forbids shader/render writes is grouped as Read. Buffers, unknown
  // texture usage and writable/target textures remain Read|Write. Native blit
  // writes and all Managed synchronizations remain untouched.
  for(NSUInteger i=0;i<metadata.readOnlyCount;i++){
    __unsafe_unretained id<MTLResource> resource=sourceReadOnly[i];
    if(!firstDeclaration&&!extendStages&&[_declared containsObject:resource])continue;
    if(resource.isAliasable)continue;
    rawReadOnly[readOnlyCount++]=resource;[_declared addObject:resource];
  }
  uint64_t nativeStart=gathering?SRNow():0;
  if ([_kind isEqualToString:@"compute"]) {
    if (heapCount) [(id<MTLComputeCommandEncoder>)_native useHeaps:rawHeaps count:heapCount];
    if (resourceCount) [(id<MTLComputeCommandEncoder>)_native useResources:rawResources count:resourceCount usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    if (readOnlyCount) [(id<MTLComputeCommandEncoder>)_native useResources:rawReadOnly count:readOnlyCount usage:MTLResourceUsageRead];
  } else if ([_kind isEqualToString:@"render"]) {
    if (heapCount) [(id<MTLRenderCommandEncoder>)_native useHeaps:rawHeaps count:heapCount stages:_declaredStages];
    if (resourceCount) [(id<MTLRenderCommandEncoder>)_native useResources:rawResources count:resourceCount usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:_declaredStages];
    if (readOnlyCount) [(id<MTLRenderCommandEncoder>)_native useResources:rawReadOnly count:readOnlyCount usage:MTLResourceUsageRead stages:_declaredStages];
  } else SRFail(@"unsupported shader encoder kind");
  uint64_t nativeEnd=nativeStart?SRNow():0;
  free(rawResources); free(rawHeaps); free(rawReadOnly);
  [_buffer.queue.context.lock lock];
  _buffer.queue.context.declarations += resourceCount + readOnlyCount + heapCount;
  if(gathering){_buffer.queue.context.gatherNs+=nativeStart-gathering;_buffer.queue.context.nativeDeclarationNs+=nativeEnd-nativeStart;}
  [_buffer.queue.context.lock unlock];
  if (SRVerbose()) fprintf(stderr, "SOFTWARE_RESIDENCY declare kind=%s resources=%lu heaps=%lu stages=%lu\n", _kind.UTF8String, (unsigned long)resourceCount, (unsigned long)heapCount, (unsigned long)_declaredStages);
}
- (void)useHeap:(id<MTLHeap>)heap {
  id<MTLHeap> real = SRNative(heap); [_buffer captureAllocation:real];
  if ([_kind isEqualToString:@"compute"]) [(id<MTLComputeCommandEncoder>)_native useHeap:real];
  else if ([_kind isEqualToString:@"render"]) [(id<MTLRenderCommandEncoder>)_native useHeap:real stages:MTLRenderStageVertex | MTLRenderStageFragment];
  else SRFail(@"useHeap on unsupported encoder");
}
- (void)useHeap:(id<MTLHeap>)heap stages:(MTLRenderStages)stages {
  if (![_kind isEqualToString:@"render"]) SRFail(@"render-stage heap call on non-render encoder");
  id<MTLHeap> real = SRNative(heap); [_buffer captureAllocation:real];
  [(id<MTLRenderCommandEncoder>)_native useHeap:real stages:stages];
}
- (void)useHeaps:(const id<MTLHeap>[])heaps count:(NSUInteger)count {
  for (NSUInteger i = 0; i < count; ++i) [self useHeap:heaps[i]];
}
- (void)useHeaps:(const id<MTLHeap>[])heaps count:(NSUInteger)count stages:(MTLRenderStages)stages {
  for (NSUInteger i = 0; i < count; ++i) [self useHeap:heaps[i] stages:stages];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  // Retain direct resource arguments at binding/encoding time, before callers
  // can release them on unretained command buffers. Also register foreign views.
  for (NSUInteger i = 2; i < invocation.methodSignature.numberOfArguments; ++i) {
    const char *type = [invocation.methodSignature getArgumentTypeAtIndex:i];
    while (*type && strchr("rnNoORV", *type)) ++type;
    if (*type != '@' || type[1] == '?') continue;
    __unsafe_unretained id object = nil; [invocation getArgument:&object atIndex:i];
    object = SRNative(object);
    if ([object conformsToProtocol:@protocol(MTLResource)] || [object conformsToProtocol:@protocol(MTLHeap)]) [_buffer captureAllocation:object];
    else [_buffer captureAuxiliaryObject:object];
  }
  NSString *name = NSStringFromSelector(invocation.selector);
  // Buffer/texture array bindings are not Objective-C object arguments. Retain
  // their entries explicitly as well, especially for unretained CBs.
  BOOL bindingArray = [name hasPrefix:@"set"] && [name hasSuffix:@"withRange:"] &&
    ([name containsString:@"Buffers:"] || [name containsString:@"Textures:"]);
  BOOL resourceArray = [name hasPrefix:@"useResources:count:usage:"];
  id __unsafe_unretained *originalArray = NULL;
  id __unsafe_unretained *unwrappedArray = NULL;
  if (bindingArray || resourceArray) {
    id __unsafe_unretained *objects = NULL;
    [invocation getArgument:&objects atIndex:2];
    NSUInteger count = 0;
    if (resourceArray) [invocation getArgument:&count atIndex:3];
    else {
      NSRange range = {0,0};
      [invocation getArgument:&range atIndex:invocation.methodSignature.numberOfArguments - 1];
      count = range.length;
    }
    BOOL needsUnwrap = NO;
    for (NSUInteger i = 0; objects && i < count; ++i) if (objects[i]) {
      [_buffer captureAllocation:objects[i]];
      if (SRNative(objects[i]) != objects[i]) needsUnwrap = YES;
    }
    if (needsUnwrap) {
      unwrappedArray = (id __unsafe_unretained *)calloc(count, sizeof(id));
      if (!unwrappedArray) SRFail(@"resource array unwrap allocation failed");
      for (NSUInteger i = 0; i < count; ++i) unwrappedArray[i] = SRNative(objects[i]);
      originalArray = objects;
      [invocation setArgument:&unwrappedArray atIndex:2];
    }
  }
  if ([_kind isEqualToString:@"blit"]) [self declareBeforeExecution:invocation.selector];
  else if ([name hasPrefix:@"draw"] || [name hasPrefix:@"dispatch"] || [name hasPrefix:@"executeCommands"]) [self declareBeforeExecution:invocation.selector];
  @try { [super forwardInvocation:invocation]; }
  @finally {
    if (unwrappedArray) { [invocation setArgument:&originalArray atIndex:2]; free(unwrappedArray); }
  }
}
@end

@interface SRHeap : SRProxy
@property(nonatomic, strong) SRContext *context;
@end
@implementation SRHeap
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
  id<MTLBuffer> buffer = [(id<MTLHeap>)_native newBufferWithLength:length options:options];
  [_context registerAllocation:buffer]; return buffer;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset {
  id<MTLBuffer> buffer = [(id<MTLHeap>)_native newBufferWithLength:length options:options offset:offset];
  [_context registerAllocation:buffer]; return buffer;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
  SRTextureDiagnostics(@"heap.newTexture", descriptor);
  id<MTLTexture> texture = [(id<MTLHeap>)_native newTextureWithDescriptor:descriptor];
  [_context registerAllocation:texture]; return texture;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset {
  SRTextureDiagnostics(@"heap.newTextureWithOffset", descriptor);
  id<MTLTexture> texture = [(id<MTLHeap>)_native newTextureWithDescriptor:descriptor offset:offset];
  [_context registerAllocation:texture]; return texture;
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  NSString *name = NSStringFromSelector(invocation.selector);
  if ([name hasPrefix:@"newBuffer"] || [name hasPrefix:@"newTexture"] || [name hasPrefix:@"newAccelerationStructure"]) {
    SRFail([@"uncovered heap allocation: " stringByAppendingString:name]);
  }
  [super forwardInvocation:invocation];
}
@end

@interface SRDevice : SRProxy
@property(nonatomic, strong) SRContext *context;
@end
static id SRNewQueue(id<MTLCommandQueue> native, SRContext *context) {
  if (!native) return nil;
  SRQueue *queue = [[SRQueue alloc] initWithNative:native];
  queue.context = context; queue.lock = [NSLock new]; queue.sets = SRStrongIdentitySet();
  return queue;
}
@implementation SRDevice
- (id<MTLResidencySet>)newResidencySetWithDescriptor:(MTLResidencySetDescriptor *)descriptor error:(NSError **)error {
  // Deliberately never calls the AMD native residency API; validation says it
  // is unsupported. This is a real software implementation of membership and
  // submission declarations, not a nil/no-op replacement.
  if (error) *error = nil;
  SRSet *set = [SRSet new]; set.context = _context; set.label = descriptor.label;
  if (SRVerbose()) fprintf(stderr, "SOFTWARE_RESIDENCY created software set device=%s\n", _context.device.name.UTF8String);
  return set;
}
- (id<MTLCommandQueue>)newCommandQueue { return SRNewQueue([(id<MTLDevice>)_native newCommandQueue], _context); }
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {
  return SRNewQueue([(id<MTLDevice>)_native newCommandQueueWithMaxCommandBufferCount:count], _context);
}
- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)descriptor {
  return SRNewQueue([(id<MTLDevice>)_native newCommandQueueWithDescriptor:descriptor], _context);
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
  id<MTLBuffer> buffer = [(id<MTLDevice>)_native newBufferWithLength:length options:options];
  [_context registerAllocation:buffer]; return buffer;
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options {
  id<MTLBuffer> buffer = [(id<MTLDevice>)_native newBufferWithBytes:bytes length:length options:options];
  [_context registerAllocation:buffer]; return buffer;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)bytes length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void *, NSUInteger))deallocator {
  id<MTLBuffer> buffer = [(id<MTLDevice>)_native newBufferWithBytesNoCopy:bytes length:length options:options deallocator:deallocator];
  [_context registerAllocation:buffer]; return buffer;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
  SRTextureDiagnostics(@"device.newTexture", descriptor);
  MTLTextureDescriptor *prepared = TSPrepareDeviceTextureDescriptor(_context.device, descriptor);
  id<MTLTexture> texture = [(id<MTLDevice>)_native newTextureWithDescriptor:prepared];
  TSRegisterConvertedTexture(texture, descriptor);
  [_context registerAllocation:texture]; return texture;
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)descriptor {
  uint64_t started=SRProfileEnabled()?SRNow():0;
  // Metal validates this query too. Use the identical public descriptor
  // policy as device allocation so sizing describes the actual resource.
  // This does not change a heap's storage mode or implement heap migration.
  SRTextureDiagnostics(@"device.heapTextureSizeAndAlign", descriptor);
  MTLTextureDescriptor *prepared = TSPrepareDeviceTextureDescriptor(_context.device, descriptor);
  MTLSizeAndAlign result = [(id<MTLDevice>)_native heapTextureSizeAndAlignWithDescriptor:prepared];
  if(started){[_context.lock lock];++_context.layoutQueryCalls;_context.layoutQueryNs+=SRNow()-started;[_context.lock unlock];}
  if (prepared != descriptor && getenv("GPU_ADAPTER_VERBOSE")) fprintf(stderr,
    "TEXTURE_STORAGE heapSizeQuery requestedMode=%lu actualMode=%lu format=%lu size=%lu align=%lu\n",
    (unsigned long)descriptor.storageMode, (unsigned long)prepared.storageMode,
    (unsigned long)prepared.pixelFormat, (unsigned long)result.size, (unsigned long)result.align);
  return result;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)surface plane:(NSUInteger)plane {
  SRTextureDiagnostics(@"device.newTextureIOSurface", descriptor);
  id<MTLTexture> texture = [(id<MTLDevice>)_native newTextureWithDescriptor:descriptor iosurface:surface plane:plane];
  [_context registerAllocation:texture]; return texture;
}
- (id<MTLTexture>)newSharedTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
  SRTextureDiagnostics(@"device.newSharedTexture", descriptor);
  id<MTLTexture> texture = [(id<MTLDevice>)_native newSharedTextureWithDescriptor:descriptor];
  [_context registerAllocation:texture]; return texture;
}
- (id<MTLTexture>)newSharedTextureWithHandle:(MTLSharedTextureHandle *)handle {
  id<MTLTexture> texture = [(id<MTLDevice>)_native newSharedTextureWithHandle:handle];
  [_context registerAllocation:texture]; return texture;
}
- (id<MTLIndirectCommandBuffer>)newIndirectCommandBufferWithDescriptor:(MTLIndirectCommandBufferDescriptor *)descriptor maxCommandCount:(NSUInteger)count options:(MTLResourceOptions)options {
  id<MTLIndirectCommandBuffer> buffer = [(id<MTLDevice>)_native newIndirectCommandBufferWithDescriptor:descriptor maxCommandCount:count options:options];
  [_context registerAllocation:buffer]; return buffer;
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)descriptor {
  id<MTLHeap> heap = [(id<MTLDevice>)_native newHeapWithDescriptor:descriptor];
  if (!heap) return nil;
  [_context registerAllocation:heap];
  SRHeap *wrapper = [[SRHeap alloc] initWithNative:heap]; wrapper.context = _context;
  return (id<MTLHeap>)wrapper;
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  NSString *name = NSStringFromSelector(invocation.selector);
  if ([name hasPrefix:@"newBuffer"] || [name hasPrefix:@"newTexture"] || [name hasPrefix:@"newSharedTexture"] || [name hasPrefix:@"newHeap"] || [name hasPrefix:@"newIndirectCommandBuffer"] || [name hasPrefix:@"newCommandQueue"] || [name hasPrefix:@"newCommandBuffer"] || [name hasPrefix:@"newCommandAllocator"] || [name hasPrefix:@"newArgumentTable"] || [name hasPrefix:@"newAccelerationStructure"] || [name hasPrefix:@"newIOCommandQueue"]) {
    SRFail([@"uncovered resource/queue creation: " stringByAppendingString:name]);
  }
  [super forwardInvocation:invocation];
  // Observe only synchronous native object returns; preserve original result,
  // NSError output, descriptor, options and ownership. Never read shader input.
  BOOL pipeline = [name hasPrefix:@"newRenderPipelineState"] || [name hasPrefix:@"newComputePipelineState"];
  if (SRProfileEnabled() && pipeline && [name hasSuffix:@"error:"] && invocation.methodSignature.methodReturnType[0]=='@') {
    __unsafe_unretained id actual=nil; [invocation getReturnValue:&actual];
    [_context.lock lock]; ++_context.pipelineCreationCalls;
    uint64_t failures=_context.pipelineCreationFailures;
    if(!actual)failures=++_context.pipelineCreationFailures;
    [_context.lock unlock];
    if(!actual && failures<=16) {
      NSError *__autoreleasing *errorOutput=NULL;
      [invocation getArgument:&errorOutput atIndex:invocation.methodSignature.numberOfArguments-1];
      NSError *error=errorOutput?*errorOutput:nil;
      NSString *description=error.localizedDescription?:@"";
      if(description.length>4096)description=[description substringToIndex:4096];
      NSUInteger options=0;if([name containsString:@":options:"])[invocation getArgument:&options atIndex:3];
      NSDictionary *detail=@{@"nativePipelineOptions":@(options),@"binaryArchiveMissRequested":@((options&MTLPipelineOptionFailOnBinaryArchiveMiss)!=0),@"pid":@(getpid()),@"monotonicNs":@(SRNow()),@"selector":name,@"domain":error.domain?:@"",@"code":@(error.code),@"description":description,@"scope":@"Native compiler error only; no shader source read or result modification"};
      NSData *json=[NSJSONSerialization dataWithJSONObject:detail options:0 error:nil];
      fprintf(stderr,"PIPELINE_FAILURE_JSON ");if(json)fwrite(json.bytes,1,json.length,stderr);fputc('\n',stderr);
      fprintf(stderr,"PIPELINE_FAILURE pid=%d selector=%s domain=%s code=%ld NATIVE_NIL_RETURN_UNCHANGED\n",getpid(),name.UTF8String,error.domain.UTF8String? : "none",(long)error.code);
    }
  }
}
@end

id<MTLDevice> SRWrapMetalDeviceForSoftwareResidency(id<MTLDevice> device) {
  SRDevice *wrapper = [[SRDevice alloc] initWithNative:SRNative(device)];
  wrapper.context = SRContextForDevice(device);
  if (SRVerbose()) fprintf(stderr, "SOFTWARE_RESIDENCY enabled conservative Metal3 declarations; realGPU=%s\n", wrapper.context.device.name.UTF8String);
  return (id<MTLDevice>)wrapper;
}
void SRRegisterMetalAllocation(id<MTLDevice> device, id<MTLAllocation> allocation) { [SRContextForDevice(device) registerAllocation:allocation]; }
NSDictionary *SRSoftwareResidencyStatistics(id<MTLDevice> device) {
  SRContext *context = SRContextForDevice(device);
  [context.lock lock];
  NSDictionary *result = @{@"registeredLiveAllocations": @(context.registry.count), @"nativeDeclarations": @(context.declarations), @"completedNativeCommandBuffers": @(context.completedBuffers), @"snapshotCacheHits":@(context.snapshotCacheHits), @"snapshotCacheMisses":@(context.snapshotCacheMisses),@"snapshotNs":@(context.snapshotNs),@"gatherNs":@(context.gatherNs),@"nativeDeclarationNs":@(context.nativeDeclarationNs),@"submittedNativeCommandBuffers":@(context.submittedBuffers),@"presentRequests":@(context.presentRequests),@"completedNativeGPUTimeNs":@(context.nativeGPUNs)};
  [context.lock unlock];
  return result;
}
