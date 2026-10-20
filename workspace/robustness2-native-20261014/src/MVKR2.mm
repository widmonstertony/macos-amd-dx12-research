#include "MVKR2.h"
#include "R2Native.h"
#include <chrono>
#include <cstring>
#include "MVKShaderModule.h"
#include "MVKPipeline.h"
#include "MVKDescriptorSet.h"
#include "MVKCommandBuffer.h"
#include <fstream>
#include <map>
#include <mutex>
#include <atomic>
#include <unistd.h>

namespace {
constexpr uint32_t sentinel=0xa5a55a5a;
std::atomic<uint64_t> pipelineCount{0},dispatchCount{0},nullCount{0};
struct Dummy {
    id<MTLBuffer> buffer;
    id<MTLTexture> texture;
    Dummy(id<MTLDevice> d) {
        buffer=[d newBufferWithLength:256 options:MTLResourceStorageModeShared];
        if(!buffer) throw std::runtime_error("R2 dummy buffer allocation failed");
        std::fill_n((uint32_t*)buffer.contents,64,sentinel);
        MTLTextureDescriptor* td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:4 height:3 mipmapped:NO];
        td.storageMode=MTLStorageModeManaged;td.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        texture=[d newTextureWithDescriptor:td];
        if(!texture) throw std::runtime_error("R2 dummy image allocation failed");
        std::array<uint32_t,48> pixels;pixels.fill(sentinel);
        [texture replaceRegion:MTLRegionMake2D(0,0,4,3) mipmapLevel:0 withBytes:pixels.data() bytesPerRow:64];
    }
    ~Dummy(){[buffer release];[texture release];}
};
std::mutex dummyLock;
std::map<id<MTLDevice>,std::unique_ptr<Dummy>> dummies;
Dummy& dummy(id<MTLDevice> d) {
    std::lock_guard<std::mutex> lock(dummyLock);
    auto& ptr=dummies[d];if(!ptr)ptr=std::make_unique<Dummy>(d);return *ptr;
}
}
bool mvkR2Enabled(){static const bool enabled=[](){const char* value=getenv("MVK_R2_RESEARCH");return value&&std::string(value)=="1";}();return enabled;}
id<MTLBuffer> mvkR2DummyBuffer(id<MTLDevice> d){return mvkR2Enabled()?dummy(d).buffer:nil;}
id<MTLTexture> mvkR2DummyTexture(id<MTLDevice> d,bool texel){
    if(!mvkR2Enabled())return nil;
    if(texel)throw std::runtime_error("R2 texel dummy not yet implemented");
    return dummy(d).texture;
}

namespace {
std::mutex compilerLock;
std::map<std::string,R2NativeResult> compilerCache;
std::atomic<uint64_t> nativeTransforms{0},nativeCacheHits{0},nativePhysical{0},renderBinds{0};
}
bool mvkR2Compile(MVKShaderModule* module,MVKPipelineLayout* layout,std::vector<uint32_t>& output,MVKR2State& state){
    std::map<std::pair<uint32_t,uint32_t>,uint32_t> counts;
    for(uint32_t set=0;set<layout->getDescriptorSetCount();++set){
        auto* sl=layout->getDescriptorSetLayout(set);
        if(sl->argBufMode()==MVKArgumentBufferMode::Off){fprintf(stderr,"[r2-native] REFUSE direct descriptor mode\n");return false;}
        for(auto& b:sl->bindings())counts[{set,b.binding}]=b.descriptorCount;
    }
    const auto& input=module->getSPIRV();
    if(input.empty()){fprintf(stderr,"[r2-native] REFUSE non-SPIR-V module\n");return false;}
    uint64_t inputWords=input.size();std::string key(reinterpret_cast<const char*>(&inputWords),sizeof(inputWords));
    key.append(reinterpret_cast<const char*>(input.data()),input.size()*4);
    for(auto& entry:counts){uint32_t words[]={entry.first.first,entry.first.second,entry.second};key.append(reinterpret_cast<const char*>(words),sizeof(words));}
    R2NativeResult result;std::string error;bool hit=false;
    {
        std::lock_guard<std::mutex> lock(compilerLock);
        auto found=compilerCache.find(key);
        if(found!=compilerCache.end()){result=found->second;hit=true;++nativeCacheHits;}
        else{
            if(!r2NativeLower(input,counts,result,error)){fprintf(stderr,"[r2-native] REFUSE %s\n",error.c_str());return false;}
            if(compilerCache.size()>=32)compilerCache.erase(compilerCache.begin());
            compilerCache.emplace(key,result);++nativeTransforms;
        }
    }
    state={};state.slots=result.slots;state.metalIndex=26;
    for(auto& r:result.resources){
        if(r.sampler)continue;if(r.set>=layout->getDescriptorSetCount())return false;
        bool found=false;for(auto& binding:layout->getDescriptorSetLayout(r.set)->bindings())if(binding.binding==r.binding)found=true;
        if(!found)return false;state.resources.push_back({r.set,r.binding,r.slot,r.count,r.buffer});
    }
    output=std::move(result.binary);++pipelineCount;nativePhysical+=result.physicalAccesses;
    fprintf(stderr,"[r2-native] IN_PROCESS slots=%u guards=%u physicalCallerManaged=%u cacheHit=%d\n",state.slots,result.guardedOperations,result.physicalAccesses,hit);
    return true;
}

static std::vector<std::array<uint32_t,4>> r2Metadata(MVKDescriptorSet*const* sets,const MVKR2State& state){
    std::vector<std::array<uint32_t,4>> meta(state.slots,{0,0,0,0});
    for(const auto& r:state.resources){
        auto* set=sets[r.set];if(!set)continue;
        const MVKDescriptorBinding* b=nullptr;
        for(const auto& candidate:set->layout->bindings())if(candidate.binding==r.binding)b=&candidate;
        if(!b)throw std::runtime_error("R2 bound descriptor layout mismatch");
        uint32_t count=std::min(r.count,b->getDescriptorCount(set->variableDescriptorCount));
        size_t stride=descriptorCPUSize(b->cpuLayout);
        if(!stride||b->cpuOffset+count*stride>set->cpuBufferSize)throw std::runtime_error("R2 CPU descriptor metadata unavailable");
        for(uint32_t i=0;i<count;++i){
            auto* cpu=set->cpuBuffer+b->cpuOffset+i*stride;auto& value=meta.at(r.slot+i);
            if(r.buffer){
                if(b->cpuLayout!=MVKDescriptorCPULayout::OneID2Meta)throw std::runtime_error("R2 unsupported buffer CPU layout");
                auto* d=reinterpret_cast<const MVKCPUDescriptorOneID2Meta*>(cpu);
                if(d->a && set->layout->getDevice()->getLiveResources().isLive((id<MTLBuffer>)d->a))value={1,d->meta.buffer.size,0,0};else ++nullCount;
            }else{
                id<MTLTexture> tex=*reinterpret_cast<id<MTLTexture>const*>(cpu);
                if(tex && set->layout->getDevice()->getLiveResources().isLive(tex))value={1,uint32_t(tex.width),uint32_t(tex.height),0};else ++nullCount;
            }
        }
    }
    return meta;
}

void mvkR2Bind(id<MTLComputeCommandEncoder> encoder,MVKCommandEncoder& mvkEncoder,MVKDescriptorSet*const* sets,const MVKR2State& state){
    if(!state.slots)return;
    auto meta=r2Metadata(sets,state);
    // Always regenerate from actual descriptors, including copy/update and actual
    // variable allocation counts. The command buffer pool owns each snapshot until completion.
    const auto* allocation=mvkEncoder.copyToTempMTLBufferAllocation(meta.data(),meta.size()*16);
    mvkEncoder.getMtlCompute().bindBuffer(encoder,allocation->_mtlBuffer,allocation->_offset,state.metalIndex);
    auto& d=dummy(encoder.device);
    [encoder useResource:d.buffer usage:MTLResourceUsageRead|MTLResourceUsageWrite];
    [encoder useResource:d.texture usage:MTLResourceUsageRead|MTLResourceUsageWrite];
    ++dispatchCount;
}

// Private research diagnostics, not a Vulkan feature/capability advertisement.
extern "C" __attribute__((visibility("default"))) void mvkR2ResearchCounters(uint64_t* out){
    out[0]=pipelineCount;out[1]=dispatchCount;out[2]=nullCount;out[3]=0;
    std::lock_guard<std::mutex> lock(dummyLock);
    for(auto& entry:dummies){
        auto& d=*entry.second;id<MTLCommandQueue> queue=[entry.first newCommandQueue];
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        [blit synchronizeResource:d.texture];[blit endEncoding];[cb commit];[cb waitUntilCompleted];
        std::array<uint32_t,48> pixels;[d.texture getBytes:pixels.data() bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,4,3) mipmapLevel:0];
        for(auto v:pixels)if(v!=sentinel)++out[3];
        for(unsigned i=0;i<64;++i)if(((uint32_t*)d.buffer.contents)[i]!=sentinel)++out[3];
        [queue release];
    }
}

void mvkR2BindRender(id<MTLRenderCommandEncoder> encoder,MVKCommandEncoder& mvkEncoder,MVKDescriptorSet*const* sets,const MVKR2State& state,bool fragment){
    if(!state.slots)return;
    auto meta=r2Metadata(sets,state);
    const auto* allocation=mvkEncoder.copyToTempMTLBufferAllocation(meta.data(),meta.size()*16);
    if(fragment)mvkEncoder.getMtlGraphics().bindFragmentBuffer(encoder,allocation->_mtlBuffer,allocation->_offset,state.metalIndex);
    else mvkEncoder.getMtlGraphics().bindVertexBuffer(encoder,allocation->_mtlBuffer,allocation->_offset,state.metalIndex);
    auto& d=dummy(encoder.device);
    [encoder useResource:d.buffer usage:MTLResourceUsageRead|MTLResourceUsageWrite stages:fragment?MTLRenderStageFragment:MTLRenderStageVertex];
    [encoder useResource:d.texture usage:MTLResourceUsageRead|MTLResourceUsageWrite stages:fragment?MTLRenderStageFragment:MTLRenderStageVertex];
    ++renderBinds;
}
extern "C" __attribute__((visibility("default"))) void mvkR2NativeCounters(uint64_t* out){out[0]=nativeTransforms;out[1]=nativeCacheHits;out[2]=nativePhysical;out[3]=renderBinds;}
