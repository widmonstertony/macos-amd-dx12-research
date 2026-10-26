// Bounded, opt-in shader diagnostics. No shader/cache decisions are made here.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>
#include <atomic>
#include <cerrno>
#include <pthread.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <vector>
#include <mutex>
#if !defined(MVK_SHADER_FORENSICS_CPU_CONTROL)
#include "MVKForensicsTrace.h"
#endif

struct MVKShaderForensicsContext { uint64_t request=0,shader=0,config=0,session=0; };
inline thread_local MVKShaderForensicsContext mvkSFContext{};
inline MVKShaderForensicsContext mvkSFCurrentContext(){auto value=mvkSFContext;if(!value.session)value.session=mvkForensicsSessionID();return value;}
struct MVKShaderForensicsContextGuard {
    MVKShaderForensicsContext previous;
    explicit MVKShaderForensicsContextGuard(MVKShaderForensicsContext next):previous(mvkSFContext){mvkSFContext=next;}
    ~MVKShaderForensicsContextGuard(){mvkSFContext=previous;}
};
struct MVKShaderForensicsErrno {int previous=errno;~MVKShaderForensicsErrno(){errno=previous;}};
inline uint64_t mvkSFIdentity(const void*value){return reinterpret_cast<uintptr_t>(value);}
inline uint64_t mvkSFTimeNS(){
    MVKShaderForensicsErrno preserve;
    static auto scale=[] {mach_timebase_info_data_t value{1,1};mach_timebase_info(&value);return value;}();
    return uint64_t((static_cast<unsigned __int128>(mach_absolute_time())*scale.numer)/scale.denom);
}
inline uint64_t mvkSFSequence(){static std::atomic<uint64_t> sequence{1};return sequence.fetch_add(1,std::memory_order_relaxed);}
inline void mvkSFEvent(const char*event,const void*instance,uint64_t operation=0,uint64_t phase=0,
                      uint64_t outcome=0,uint64_t auxiliary=0,uint64_t elapsedNS=0) noexcept {
    if(!mvkSFContext.session&&!mvkForensicsArmed())return;MVKShaderForensicsErrno preserve;
    int relative=0;qos_class_t qos=QOS_CLASS_UNSPECIFIED;
    const int qosResult=pthread_get_qos_class_np(pthread_self(),&qos,&relative);
    try{mvkForensicsRecordForSession(mvkSFContext.session,event,{{"request",mvkSFContext.request},{"shader",mvkSFContext.shader},
        {"config",mvkSFContext.config},{"instance",mvkSFIdentity(instance)},{"operation",operation},
        {"phase",phase},{"outcome",outcome},{"auxiliary",auxiliary},{"elapsedNS",elapsedNS},
        {"qos",uint64_t(qos)},{"qosResult",uint64_t(qosResult)},{"relativePriority",uint64_t(int64_t(relative))}});}catch(...){}
}
// Callers guard construction. Begin/end include the executing thread's QoS;
// asynchronous work explicitly copies/restores the POD context above.
struct MVKShaderForensicsSpan {
    const char*kind;const void*object;uint64_t operation=0,start=0;bool done=false;
    MVKShaderForensicsContext owner;
    MVKShaderForensicsSpan(bool armed,const char*event,const void*instance):kind(event),object(instance),owner(mvkSFContext){
        if(armed){owner.session=mvkForensicsSessionID();operation=mvkSFSequence();start=mvkSFTimeNS();
            MVKShaderForensicsContextGuard guard(owner);mvkSFEvent(kind,object,operation,0);}}
    void finish(uint64_t outcome=0,uint64_t auxiliary=0){if(!operation||done)return;done=true;
        MVKShaderForensicsContextGuard guard(owner);mvkSFEvent(kind,object,operation,1,outcome,auxiliary,mvkSFTimeNS()-start);}
    ~MVKShaderForensicsSpan(){finish(0);}
};

inline bool mvkSFMetadataAdmission(const void*instance) noexcept {
    if(!mvkForensicsArmed())return false;MVKShaderForensicsErrno preserve;
    struct Budget{std::mutex lock;uint64_t session=0,count=0;};static Budget budget;
    uint64_t index=0;try{std::lock_guard<std::mutex>guard(budget.lock);auto session=mvkForensicsSessionID();
        if(budget.session!=session){budget.session=session;budget.count=0;}index=budget.count++;}
    catch(...){mvkSFEvent("shader-metadata-unavailable",instance,0,0,6);return false;}
    if(index>=512){mvkSFEvent("shader-metadata-denied",instance,0,0,1,512,index+1);return false;}
    return true;
}
inline NSString* mvkSFStableJSONSHA(NSDictionary*value,uint64_t*tag=nullptr) {
    if(tag)*tag=0;if(!value)return nil;
    NSData*data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    if(!data||data.length>65536)return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,CC_LONG(data.length),hash);
    char hex[CC_SHA256_DIGEST_LENGTH*2+1];static const char digits[]="0123456789abcdef";
    uint64_t shortTag=0;for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;++i){hex[i*2]=digits[hash[i]>>4];hex[i*2+1]=digits[hash[i]&15];if(i<8)shortTag=(shortTag<<8)|hash[i];}
    hex[64]=0;if(tag)*tag=shortTag;return [NSString stringWithUTF8String:hex];
}
inline NSDictionary* mvkSFSpecialization(const VkSpecializationInfo*info) {
    if(!info)return @{ @"present":@NO,@"entries":@[] };
    if(info->mapEntryCount>1024||info->dataSize>16384||(!info->pData&&info->dataSize)||(!info->pMapEntries&&info->mapEntryCount))
        return @{ @"present":@YES,@"complete":@NO,@"reason":@"invalid-or-bounded-specialization" };
    std::vector<uint32_t> order(info->mapEntryCount);for(uint32_t i=0;i<order.size();++i)order[i]=i;
    std::stable_sort(order.begin(),order.end(),[&](uint32_t a,uint32_t b){return info->pMapEntries[a].constantID<info->pMapEntries[b].constantID;});
    NSMutableArray*entries=[NSMutableArray array];size_t captured=0;
    for(uint32_t i:order){auto&e=info->pMapEntries[i];
        if(e.offset>info->dataSize||e.size>info->dataSize-e.offset||e.size>16384-captured)
            return @{ @"present":@YES,@"complete":@NO,@"reason":@"specialization-range-unavailable" };
        captured+=e.size;
        const void*value=e.size?static_cast<const char*>(info->pData)+e.offset:nullptr;
        NSData*bytes=[NSData dataWithBytes:value length:e.size];
        [entries addObject:@{@"constantID":@(e.constantID),@"size":@(e.size),@"valueBase64":[bytes base64EncodedStringWithOptions:0]}];
    }
    return @{@"present":@YES,@"complete":@YES,@"entries":entries,
        @"meaning":@"requested constantID/size/value bytes sorted by ID; unused entries included; offsets/padding/pointers excluded"};
}

// Implemented after MVKPipeline's existing complete Cereal field serializers.
// This representation includes all serialized configuration fields, not raw
// struct memory. It is NOT equivalent to the asymmetric matches()/alignWith().
NSDictionary* mvkSFConversionFields(const mvk::SPIRVToMSLConversionConfiguration&config);
inline uint64_t mvkSFVariantMetadata(const char*role,const void*instance,uint64_t shader,
    const mvk::SPIRVToMSLConversionConfiguration&config,const VkSpecializationInfo*specialization=nullptr) noexcept {
    if(!mvkForensicsArmed()||!mvkSFMetadataAdmission(instance))return 0;
    MVKShaderForensicsErrno preserve;
    try{@autoreleasepool{@try{
        size_t members=config.shaderInputs.size()+config.shaderOutputs.size()+config.resourceBindings.size()+config.discreteDescriptorSets.size()+config.dynamicBufferDescriptors.size();
        if(members>4096||config.options.entryPointName.size()>4096){mvkSFEvent("shader-metadata-denied",instance,0,0,2,members);return 0;}
        NSDictionary*fields=mvkSFConversionFields(config);NSDictionary*spec=mvkSFSpecialization(specialization);
        if(spec[@"complete"]&&![spec[@"complete"] boolValue])mvkSFEvent("shader-metadata-unavailable",instance,0,0,5);
        if(!fields){mvkSFEvent("shader-metadata-unavailable",instance,0,0,1);return 0;}
        NSDictionary*key=@{@"conversionFields":fields,@"specialization":spec};uint64_t tag=0;
        NSString*sha=mvkSFStableJSONSHA(key,&tag);if(!sha){mvkSFEvent("shader-metadata-unavailable",instance,0,0,2);return 0;}
        mvkForensicsJSON("shader-variant",@{@"request":@(mvkSFContext.request),@"shader":@(shader),
            @"ownerSession":@(mvkSFContext.session?mvkSFContext.session:mvkForensicsSessionID()),
            @"instance":@(mvkSFIdentity(instance)),@"role":@(role),@"configTag":@(tag),@"SHA256":sha,
            @"key":key,@"serialization":@"explicit-Cereal-fields-JSON-v1; vector order preserved",
            @"matchEquivalent":@NO,@"duplicateCompilationProof":@NO,
            @"limits":@"actual cache hit/miss is reported separately; matches ignores unused interfaces/resources and alignWith mutates request; identical SHA alone is not duplication proof",
            @"metadataBudgetScope":@"per-arm-session-512; canonical key JSON <=64KiB"});
        return tag;
    }@catch(NSException*){mvkSFEvent("shader-metadata-unavailable",instance,0,0,3);return 0;}}}
    catch(...){mvkSFEvent("shader-metadata-unavailable",instance,0,0,4);return 0;}
}

// Actual public native options can differ from conversion options (e.g. scoped
// conservative mesh math). Capture that distinction without changing either.
inline void mvkSFNativeLibraryMetadata(const void*instance,uint64_t operation,NSString*source,
                                       MTLCompileOptions*options) noexcept {
    if(!mvkForensicsArmed()||!mvkSFMetadataAdmission(instance))return;
    MVKShaderForensicsErrno preserve;
    try{@autoreleasepool{@try{
        const NSUInteger length=[source lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const char*bytes=source.UTF8String;
        if(!bytes||length>16*1024*1024){mvkSFEvent("shader-metadata-unavailable",instance,operation,0,7,length);return;}
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,CC_LONG(length),digest);
        char hex[65];static const char digits[]="0123456789abcdef";
        for(unsigned i=0;i<32;i++){hex[2*i]=digits[digest[i]>>4];hex[2*i+1]=digits[digest[i]&15];}hex[64]=0;
        NSMutableDictionary*fields=[NSMutableDictionary dictionaryWithDictionary:@{
            @"sourceSHA256":[NSString stringWithUTF8String:hex],@"sourceUTF8Bytes":@(length),
            @"fastMathEnabled":@(options.fastMathEnabled),@"languageVersion":@(options.languageVersion),
            @"preprocessorMacros":options.preprocessorMacros?:@{}}];
        if([options respondsToSelector:@selector(preserveInvariance)])fields[@"preserveInvariance"]=@(options.preserveInvariance);
        else fields[@"preserveInvarianceAvailable"]=@NO;
#if MVK_XCODE_16
        if([options respondsToSelector:@selector(mathMode)])fields[@"mathMode"]=@(options.mathMode);
        else fields[@"mathModeAvailable"]=@NO;
        if([options respondsToSelector:@selector(mathFloatingPointFunctions)])fields[@"mathFloatingPointFunctions"]=@(options.mathFloatingPointFunctions);
        else fields[@"mathFloatingPointFunctionsAvailable"]=@NO;
#else
        fields[@"mathModeAvailable"]=@NO;fields[@"mathFloatingPointFunctionsAvailable"]=@NO;
#endif
        uint64_t tag=0;NSString*sha=mvkSFStableJSONSHA(fields,&tag);
        if(!sha){mvkSFEvent("shader-metadata-unavailable",instance,operation,0,8);return;}
        mvkForensicsJSON("shader-native-options",@{@"request":@(mvkSFContext.request),@"shader":@(mvkSFContext.shader),
            @"conversionConfigTag":@(mvkSFContext.config),@"ownerSession":@(mvkSFContext.session),
            @"instance":@(mvkSFIdentity(instance)),@"operation":@(operation),@"nativeOptionsTag":@(tag),
            @"SHA256":sha,@"key":fields,@"matchEquivalent":@NO,@"duplicateCompilationProof":@NO,
            @"limits":@"actual source + listed public options/macros, not proof of Metal driver cache key; unavailable selectors explicit"});
    }@catch(NSException*){mvkSFEvent("shader-metadata-unavailable",instance,operation,0,9);}}}
    catch(...){mvkSFEvent("shader-metadata-unavailable",instance,operation,0,10);}
}
