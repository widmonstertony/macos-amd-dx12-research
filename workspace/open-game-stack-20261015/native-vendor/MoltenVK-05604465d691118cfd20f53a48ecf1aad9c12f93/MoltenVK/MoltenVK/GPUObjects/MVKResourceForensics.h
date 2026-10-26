// Armed, encoder-local integer aggregation. No resource identities are logged
// individually, and none of this metadata participates in resource decisions.
#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <time.h>
#include "MVKResourcePointerFingerprint.h"
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
    uint64_t batchOffered=0,batchEnded=0,batchHashIncomplete=0,batchHashWallNS=0,batchBeginWriterWallNS=0;
    inline static std::atomic<uint64_t> nextBatchID{1};
    struct Batch {
        uint64_t id=0,session=0,encoder=0,encoderGeneration=0,pendingGeneration=0;
        uint64_t submission=0,nativeCB=0,frame=0,family=0,index=0,thread=0;
        uint64_t pipelineOrdinal=0,vulkanPipeline=0,nativePipeline=0,count=0,stages=0;
        uint64_t hashStart=0,hashEnd=0,beginWriterStart=0,beginWriterEnd=0;
        uint64_t source=0,kind=0;bool fileFlushSucceeded=false;
        MVKResourcePointerFingerprint fingerprint{};
    };

    static uint64_t now() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
    void add(Counter c,uint64_t n=1) { if (armed) counts[c]+=n; }
    void declaration(char kind,uint64_t n,uint64_t stages,uint64_t wall) {
        if (!armed) return;
        auto& v=native[kind=='h'?2:kind=='r'?0:1];
        ++v.calls;v.resources+=n;v.wallNS+=wall;
        if(wall>v.maxWallNS)v.maxWallNS=wall;
        if(encoderKind!=2)v.stageUnion|=stages; // Compute useResources has no stages argument.
    }
#if !defined(MVK_RESOURCE_FORENSICS_TEST_STUB) || defined(MVK_RESOURCE_BATCH_TEST_STUB)
    // All calls are offered, without a new threshold/sample gate. The common
    // writer is void and may drop rows: offered is never called admitted.
    template<class Pointer,class Context> Batch beginBatch(const Pointer* resources,size_t count,char kind,
        uint64_t stages,MVKResourceBatchSource source,uint64_t pendingGeneration,uint64_t actualEncoderGeneration,
        uint64_t actualEncoder,const Context&ctx) {
        Batch b;if(!armed)return b;MVKForensics::ErrnoGuard preserve;
        b.id=nextBatchID.fetch_add(1,std::memory_order_relaxed);b.session=session;b.encoder=actualEncoder;
        b.encoderGeneration=actualEncoderGeneration;b.pendingGeneration=pendingGeneration;
        b.submission=ctx.submission;b.nativeCB=ctx.nativeCB;b.frame=ctx.frame;b.family=ctx.queueFamily;b.index=ctx.queueIndex;
        pthread_threadid_np(nullptr,&b.thread);b.pipelineOrdinal=pipelineChanges;b.vulkanPipeline=lastPipeline;b.nativePipeline=lastNativePipeline;
        b.count=count;b.stages=stages;b.source=uint64_t(source);b.kind=kind=='h'?3:kind=='r'?1:2;++batchOffered;
        b.hashStart=mvkStutterMonotonicNS();
        b.fingerprint=MVKResourcePointerFingerprint::compute(count,resources!=nullptr,[&](size_t i){return uint64_t(reinterpret_cast<uintptr_t>(resources[i]));});
        b.hashEnd=mvkStutterMonotonicNS();batchHashWallNS+=b.hashEnd-b.hashStart;if(!b.fingerprint.complete)++batchHashIncomplete;
        b.beginWriterStart=mvkStutterMonotonicNS();
        mvkForensicsRecordForSession(b.session,"resourceBatchBegin",{
            {"diagnosticSchema",1},{"batchID",b.id},{"ownerSession",b.session},{"encoder",b.encoder},
            {"encoderGeneration",b.encoderGeneration},{"trackerGeneration",generation},{"pendingBatchGeneration",b.pendingGeneration},
            {"ownerSubmission",b.submission},{"ownerNativeCB",b.nativeCB},{"ownerFrame",b.frame},
            {"ownerQueueFamily",b.family},{"ownerQueueIndex",b.index},{"callThreadMachID",b.thread},
            {"encoderOwnerSubmission",ownerSubmit},{"encoderOwnerNativeCB",ownerNativeCB},
            {"pipelineBindOrdinal",b.pipelineOrdinal},{"vulkanPipeline",b.vulkanPipeline},{"nativePipeline",b.nativePipeline},
            {"sourceKind",b.source},{"declarationKind",b.kind},{"resourceCount",b.count},{"stageMask",b.stages},
            {"intentMachNS",b.beginWriterStart},{"hashStartMachNS",b.hashStart},{"hashEndMachNS",b.hashEnd},
            {"hashAlgorithm",MVKResourcePointerFingerprint::AlgorithmVersion},{"pointerAddressOnly",1},
            {"pointerHash1",b.fingerprint.first},{"pointerHash2",b.fingerprint.second},
            {"hashCount",b.fingerprint.hashedCount},{"hashCountCap",MVKResourcePointerFingerprint::MaxHashedPointers},
            {"hashInputAvailable",b.fingerprint.inputAvailable},{"hashComplete",b.fingerprint.complete},
            {"pointerSampleCount",b.fingerprint.sampleCount},{"pointer0",b.fingerprint.samples[0]},
            {"pointer1",b.fingerprint.samples[1]},{"pointer2",b.fingerprint.samples[2]},{"pointer3",b.fingerprint.samples[3]},
            {"partialPrefix",partialPrefix},{"unfinishedUntilMatchingEnd",1}});
        b.fileFlushSucceeded=mvkForensicsFlushIntent(b.session);
        b.beginWriterEnd=mvkStutterMonotonicNS();batchBeginWriterWallNS+=b.beginWriterEnd-b.beginWriterStart;return b;
    }
    void endBatch(const Batch&b,uint64_t actualStart,uint64_t actualEnd,uint64_t cpuStart,uint64_t cpuEnd) {
        if(!b.id)return;++batchEnded;
        bool cpuKnown=cpuStart&&cpuEnd&&cpuEnd>=cpuStart;
        mvkForensicsRecordForSession(b.session,"resourceBatchEnd",{
            {"diagnosticSchema",1},{"batchID",b.id},{"ownerSession",b.session},{"encoder",b.encoder},
            {"encoderGeneration",b.encoderGeneration},{"pendingBatchGeneration",b.pendingGeneration},
            {"ownerSubmission",b.submission},{"ownerNativeCB",b.nativeCB},{"ownerFrame",b.frame},
            {"ownerQueueFamily",b.family},{"ownerQueueIndex",b.index},{"callThreadMachID",b.thread},
            {"pipelineBindOrdinal",b.pipelineOrdinal},{"vulkanPipeline",b.vulkanPipeline},{"nativePipeline",b.nativePipeline},
            {"sourceKind",b.source},{"declarationKind",b.kind},{"resourceCount",b.count},{"stageMask",b.stages},
            {"actualStartMachNS",actualStart},{"actualEndMachNS",actualEnd},{"actualAPIWallNS",actualEnd-actualStart},
            {"threadCPUStartNS",cpuStart},{"threadCPUEndNS",cpuEnd},{"threadCPUKnown",cpuKnown},
            {"actualThreadCPUBracketNS",cpuKnown?cpuEnd-cpuStart:0},{"threadCPUBracketIncludesClockReads",1},
            {"hashWallNS",b.hashEnd-b.hashStart},{"beginWriterWallNS",b.beginWriterEnd-b.beginWriterStart},
            {"beginWriterStartMachNS",b.beginWriterStart},{"beginWriterEndMachNS",b.beginWriterEnd},
            {"beginFileFlushSucceeded",b.fileFlushSucceeded},{"writerAdmissionKnown",0},
            {"scopeFinishedBeforeEndWriter",1},{"nativeCallReturned",1},{"partialSuffix",mvkForensicsSessionID()!=b.session}});
    }
#endif
    template<class Context> void begin(uint64_t sid,const Context& ctx,bool partial) {
        counts={};native={};pipelineChanges=pipelineRows=pipelineRowsDropped=0;
        batchOffered=batchEnded=batchHashIncomplete=batchHashWallNS=batchBeginWriterWallNS=0;
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
            {"diagnosticSchema",2},{"nativeWallTimeMeaning",2},
            {"resourceBatchesOffered",batchOffered},{"resourceBatchesEnded",batchEnded},
            {"resourceBatchesUnfinished",batchOffered>=batchEnded?batchOffered-batchEnded:0},
            {"resourceBatchHashIncomplete",batchHashIncomplete},{"resourceBatchHashWallNS",batchHashWallNS},
            {"resourceBatchBeginWriterWallNS",batchBeginWriterWallNS},{"resourceBatchWriterAdmissionKnown",0},
            {"resourceBatchRecordEvery",1},{"resourceBatchMinimumWallNS",0},
            {"ownerSession",session},{"encoder",encoder},{"encoderGeneration",generation},
            {"ownerNativeCB",ownerNativeCB},{"ownerSubmission",ownerSubmit},
            {"ownerFrame",ownerFrame},{"ownerQueueFamily",ownerFamily},{"ownerQueueIndex",ownerIndex},
            {"partialPrefix",partialPrefix},{"partialSuffix",suffixPartial},{"endReason",reason},
            {"localComplete",!partialPrefix&&!suffixPartial&&!pipelineRowsDropped&&batchOffered==batchEnded&&encoder!=0},{"encoderKind",encoderKind},
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
