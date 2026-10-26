// Armed, encoder-local integer aggregation. No resource identities are logged
// individually, and none of this metadata participates in resource decisions.
#pragma once
#include <array>
#include <cstdint>
#include <time.h>
#ifndef MVK_RESOURCE_FORENSICS_TEST_STUB
#include "MVKForensicsTrace.h"
#endif

struct MVKResourceForensics {
    enum Counter : uint32_t {
        BindingCalls, BindingSkippedSlots, ReadBufferSlots, ReadTextureSlots,
        WriteBufferSlots, WriteTextureSlots, UnknownReadSlots, UnknownWriteSlots,
        SnapshotCalls, SnapshotWords, RejectDisabled, RejectTexture, RejectWrite,
        RejectSmall, RejectLeaseMissing, RejectLeaseLarge, RejectHeapSmall,
        PlanEligibleChildren, PlanPreciseChildren, PlanCoveredSkips, PlanGroups,
        UsedVisits, UsedNewNodes, UsedNewGeneration, UsedUpgrades, UsedCompatible,
        PendingQueued, PendingSuperseded, WarmReplayChildren, ColdReplayChildren,
        DeltaReplayChildren, SnapshotCoveredSkips, LeaseRefreshes,
        RegistrationQueries, RegistrationRelated, RegistrationUnrelated,
        DescriptorFastHits, DescriptorMisses, DescriptorCacheClears,
        SnapshotCacheClears, HeapPlanCacheClears, HeapRegroupVisits,
        HeapCollapsedChildren, BindFlushes, ImmediateCalls, LiveCacheHits,
        LiveLookups, LiveFound, AbsentHits, OwnedResourceRetains,
        LifetimeClears, EncoderResets, ClearNoCrossEncoder, ClearMapBound, PlanAppliedChildren, Count
    };
    struct Native {
        uint64_t calls=0, resources=0, wallNS=0, maxWallNS=0, stageUnion=0;
    };
    std::array<uint64_t,Count> counts{};
    std::array<Native,3> native{}; // read, write, heap
    bool armed=false, partialPrefix=true, beginRecorded=false, heapPlansEnabled=false;
    uint64_t session=0, encoder=0, generation=0, ownerNativeCB=0;
    uint64_t ownerSubmit=0, ownerFrame=0, ownerFamily=0, ownerIndex=0;
    uint64_t firstPipeline=0, lastPipeline=0, lastNativePipeline=0;
    uint64_t pipelineChanges=0, pipelineRows=0, pipelineRowsDropped=0;
    uint64_t startNS=0, resetSession=0, resetCount=0, encoderKind=0;
    uint64_t heldResources=0, heldLeases=0, heldSnapshotEntries=0, usedNodes=0;

    static uint64_t now() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
    void add(Counter c,uint64_t n=1) { if (armed) counts[c]+=n; }
    void declaration(char kind,uint64_t n,uint64_t stages,uint64_t wall) {
        if (!armed) return;
        auto& v=native[kind=='h'?2:kind=='r'?0:1];
        ++v.calls;v.resources+=n;v.wallNS+=wall;
        if(wall>v.maxWallNS)v.maxWallNS=wall;
        if(encoderKind!=2)v.stageUnion|=stages; // Compute useResources has no stages argument.
    }
    template<class Context> void begin(uint64_t sid,const Context& ctx,bool partial) {
        counts={};native={};pipelineChanges=pipelineRows=pipelineRowsDropped=0;
        firstPipeline=lastPipeline=lastNativePipeline=0;
        heldResources=heldLeases=heldSnapshotEntries=usedNodes=0;encoderKind=0;
        armed=true;beginRecorded=false;session=sid;encoder=0;generation=resetCount;
        partialPrefix=partial;startNS=now();
        ownerNativeCB=ctx.nativeCB;ownerSubmit=ctx.submission;ownerFrame=ctx.frame;
        ownerFamily=ctx.queueFamily;ownerIndex=ctx.queueIndex;
    }
    void recordBegin() {
        if(beginRecorded)return;beginRecorded=true;
        mvkForensicsRecord("resourceEncoderBegin",{
            {"ownerSession",session},{"encoder",encoder},{"encoderGeneration",generation},
            {"ownerNativeCB",ownerNativeCB},{"ownerSubmission",ownerSubmit},
            {"ownerFrame",ownerFrame},{"ownerQueueFamily",ownerFamily},{"ownerQueueIndex",ownerIndex},
            {"partialPrefix",partialPrefix},{"encoderIdentityMissing",encoder==0},
            {"resourceClockUptimeNS",startNS}});
    }
    // Arm is checked at an actual encoder reset/prepare, never per child.
    template<class Context> void reset(const Context& ctx) {
        finish(1);++resetCount;resetSession=mvkForensicsSessionID();encoder=0;
        if(resetSession)begin(resetSession,ctx,false);
    }
    template<class Context> void observe(uint64_t enc,uint64_t vkPipeline,
                                        uint64_t nativePipeline,const Context& ctx,uint64_t kind=0) {
        uint64_t sid=mvkForensicsSessionID();
        bool identityChanged=armed && encoder && encoder!=enc;
        if(armed && (sid!=session || identityChanged))finish(sid==session?2:3);
        if(!sid)return;
        if(!armed)begin(sid,ctx,true);
        encoder=enc;if(kind)encoderKind=kind;recordBegin();
        if(vkPipeline!=lastPipeline || nativePipeline!=lastNativePipeline) {
            ++pipelineChanges;if(!firstPipeline)firstPipeline=vkPipeline;
            lastPipeline=vkPipeline;lastNativePipeline=nativePipeline;
            if(pipelineRows<64) {
                ++pipelineRows;
                mvkForensicsRecord("resourcePipelineBind",{
                    {"ownerSession",session},{"encoder",encoder},{"encoderGeneration",generation},
                    {"ownerNativeCB",ownerNativeCB},{"ownerSubmission",ownerSubmit},
                    {"vulkanPipeline",vkPipeline},{"nativePipeline",nativePipeline},
                    {"ordinal",pipelineChanges}});
            } else ++pipelineRowsDropped;
        }
    }
    void slots(uint64_t n,bool buffer,bool texture,bool write) {
        add(buffer?(write?WriteBufferSlots:ReadBufferSlots):
            texture?(write?WriteTextureSlots:ReadTextureSlots):
                    (write?UnknownWriteSlots:UnknownReadSlots),n);
    }
    void finish(uint64_t reason) {
        if(!armed)return;
        // A missing End when the global arm/budget closes remains detectable
        // from Begin. The common writer reports admission/cap losses; this
        // local suffix additionally carries its original session/provenance.
        bool suffixPartial=mvkForensicsSessionID()!=session;
        recordBegin();
        mvkForensicsRecord("resourceEncoderEnd",{
            {"ownerSession",session},{"encoder",encoder},{"encoderGeneration",generation},
            {"ownerNativeCB",ownerNativeCB},{"ownerSubmission",ownerSubmit},
            {"ownerFrame",ownerFrame},{"ownerQueueFamily",ownerFamily},{"ownerQueueIndex",ownerIndex},
            {"partialPrefix",partialPrefix},{"partialSuffix",suffixPartial},{"endReason",reason},
            {"localComplete",!partialPrefix&&!suffixPartial&&!pipelineRowsDropped&&encoder!=0},{"encoderKind",encoderKind},
            {"firstPipeline",firstPipeline},{"lastPipeline",lastPipeline},
            {"pipelineChanges",pipelineChanges},{"pipelineRows",pipelineRows},
            {"pipelineRowsDropped",pipelineRowsDropped},{"bindingCalls",counts[BindingCalls]},
            {"bindingSkippedSlots",counts[BindingSkippedSlots]},
            {"readBufferSlots",counts[ReadBufferSlots]},{"readTextureSlots",counts[ReadTextureSlots]},
            {"writeBufferSlots",counts[WriteBufferSlots]},{"writeTextureSlots",counts[WriteTextureSlots]},
            {"unknownReadSlots",counts[UnknownReadSlots]},{"unknownWriteSlots",counts[UnknownWriteSlots]},
            {"snapshotCalls",counts[SnapshotCalls]},{"snapshotWords",counts[SnapshotWords]},
            {"bindFlushes",counts[BindFlushes]},{"immediateCalls",counts[ImmediateCalls]},
            {"encoderResetsBefore",resetCount},{"usedNodesAtEnd",usedNodes},
            {"heapPlansEnabled",heapPlansEnabled},{"resourceTracker",reinterpret_cast<uintptr_t>(this)},

            {"planRejectDisabled",counts[RejectDisabled]},{"planRejectTexture",counts[RejectTexture]},
            {"planRejectWrite",counts[RejectWrite]},{"planRejectSmall",counts[RejectSmall]},
            {"planRejectLeaseMissing",counts[RejectLeaseMissing]},{"planRejectLeaseLarge",counts[RejectLeaseLarge]},
            {"planRejectHeapSmall",counts[RejectHeapSmall]},
            {"planAppliedChildren",counts[PlanAppliedChildren]},{"planEligibleChildren",counts[PlanEligibleChildren]},{"planPreciseChildren",counts[PlanPreciseChildren]},
            {"planCoveredSkips",counts[PlanCoveredSkips]},{"planGroups",counts[PlanGroups]},
            {"usedReplayVisits",counts[UsedVisits]},{"usedNewNodes",counts[UsedNewNodes]},
            {"usedNewGeneration",counts[UsedNewGeneration]},{"usedUpgrades",counts[UsedUpgrades]},
            {"usedCompatible",counts[UsedCompatible]},{"pendingQueued",counts[PendingQueued]},
            {"pendingSuperseded",counts[PendingSuperseded]},
            {"warmReplayChildren",counts[WarmReplayChildren]},{"coldReplayChildren",counts[ColdReplayChildren]},
            {"deltaReplayChildren",counts[DeltaReplayChildren]},
            {"snapshotCoveredSkips",counts[SnapshotCoveredSkips]},

            {"readCalls",native[0].calls},{"readResources",native[0].resources},{"readWallNS",native[0].wallNS},
            {"readMaxWallNS",native[0].maxWallNS},{"readStageUnion",native[0].stageUnion},
            {"writeCalls",native[1].calls},{"writeResources",native[1].resources},{"writeWallNS",native[1].wallNS},
            {"writeMaxWallNS",native[1].maxWallNS},{"writeStageUnion",native[1].stageUnion},
            {"heapCalls",native[2].calls},{"heapObjects",native[2].resources},{"heapWallNS",native[2].wallNS},
            {"heapMaxWallNS",native[2].maxWallNS},{"heapStageUnion",native[2].stageUnion},
            {"heapRegroupVisits",counts[HeapRegroupVisits]},{"heapCollapsedChildren",counts[HeapCollapsedChildren]},

            {"descriptorFastHits",counts[DescriptorFastHits]},{"descriptorMisses",counts[DescriptorMisses]},
            {"descriptorCacheClears",counts[DescriptorCacheClears]},
            {"snapshotCacheClears",counts[SnapshotCacheClears]},{"heapPlanCacheClears",counts[HeapPlanCacheClears]},
            {"leaseRefreshes",counts[LeaseRefreshes]},{"registrationQueries",counts[RegistrationQueries]},
            {"registrationRelated",counts[RegistrationRelated]},{"registrationUnrelated",counts[RegistrationUnrelated]},
            {"liveCacheHits",counts[LiveCacheHits]},{"liveLookups",counts[LiveLookups]},
            {"liveFound",counts[LiveFound]},{"absentHits",counts[AbsentHits]},
            {"ownedResourceRetains",counts[OwnedResourceRetains]},{"lifetimeClears",counts[LifetimeClears]},
            {"clearNoCrossEncoder",counts[ClearNoCrossEncoder]},{"clearMapBound",counts[ClearMapBound]},
            {"heldResourcesAtEnd",heldResources},{"heldLeasesAtEnd",heldLeases},
            {"heldSnapshotEntriesAtEnd",heldSnapshotEntries}});
        armed=false;
    }
};
