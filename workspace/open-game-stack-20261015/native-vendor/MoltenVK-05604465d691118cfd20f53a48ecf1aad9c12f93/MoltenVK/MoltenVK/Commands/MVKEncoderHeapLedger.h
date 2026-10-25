// CPU-only encoder residency bookkeeping. The caller owns every identity.
#pragma once
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

template<class Resource, class Heap> class MVKEncoderHeapLedger {
public:
    struct Stats {
        uint64_t heapQueueCalls=0, heapQueueSuppressed=0, writeQueueCalls=0;
        uint64_t preciseReadQueueCalls=0, readQueueSuperseded=0, readCallsEmitted=0;
        uint64_t flushes=0, heapCallsEmitted=0, writeCallsEmitted=0;
        uint64_t writeExceptionsReplayed=0, writeMetadataVisits=0;
        uint64_t readMetadataVisits=0;
        uint64_t readResourceReplayOperations=0; // There is no read-resource loop.
    };
private:
    struct HeapState {
        Heap heap{};
        uint32_t readStages=0;
        uint32_t preciseReadStages=0;
        uint64_t epoch=0;
        bool epochKnown=false, dirty=false;
        std::vector<size_t> writes;
        explicit HeapState(Heap value):heap(value){}
    };
    struct WriteState {
        Resource resource{};
        Heap heap{};
        uint32_t stages=0;
        bool dirty=false;
        uint64_t selectedSerial=0;
    };
    struct ReadState {
        Resource resource{};
        Heap heap{};
        uint32_t stages=0;
        bool dirty=false;
    };
    std::unordered_map<Heap,size_t> _heapIndex;
    std::unordered_map<Resource,size_t> _writeIndex;
    std::unordered_map<Resource,size_t> _readIndex;
    std::vector<HeapState> _heaps;
    std::vector<WriteState> _writes;
    std::vector<ReadState> _reads;
    std::vector<size_t> _dirtyHeaps, _dirtyReads, _dirtyWrites, _selectedWrites;
    uint64_t _flushSerial=0;
    bool _flushing=false;
    Stats _stats;

    void requireNotFlushing() const {
        if (_flushing) throw std::logic_error("encoder heap ledger callbacks must not re-enter");
    }
    size_t heapIndex(Heap heap) {
        auto found=_heapIndex.find(heap);
        if(found!=_heapIndex.end())return found->second;
        size_t index=_heaps.size();
        _heaps.push_back(HeapState{heap});
        _heapIndex.emplace(heap,index);
        return index;
    }
    uint32_t heapReadStages(Heap heap) const {
        if(heap==Heap{})return 0;
        auto found=_heapIndex.find(heap);
        return found==_heapIndex.end()?0:_heaps[found->second].readStages;
    }
    void selectWrite(size_t index) {
        auto& entry=_writes[index];
        if(entry.selectedSerial==_flushSerial)return;
        entry.selectedSerial=_flushSerial;
        _selectedWrites.push_back(index);
        if(!entry.dirty)++_stats.writeExceptionsReplayed;
    }
public:
    // Mask must contain Metal render/compute stages in a caller-chosen encoding.
    // Epoch denotes currently allocated/registered children of this heap.
    // A nil heap or empty stage mask requires no heap call and returns false.
    bool queueHeapRead(Heap heap,uint32_t stages,uint64_t membershipEpoch) {
        requireNotFlushing();
        ++_stats.heapQueueCalls;
        if(heap==Heap{}||!stages){++_stats.heapQueueSuppressed;return false;}
        size_t index=heapIndex(heap);auto& entry=_heaps[index];
        uint32_t targetStages=entry.readStages|stages|entry.preciseReadStages;
        bool changed=!entry.epochKnown||entry.epoch!=membershipEpoch||
                     targetStages!=entry.readStages;
        entry.readStages=targetStages;entry.epoch=membershipEpoch;entry.epochKnown=true;
        if(!changed){++_stats.heapQueueSuppressed;return false;}
        if(!entry.dirty){entry.dirty=true;_dirtyHeaps.push_back(index);}
        return true;
    }
    // Track precise reads (including nonheap/texture fallbacks) so a later heap
    // call cannot discard earlier stage coverage. This visits only the precise
    // resource being queued, never the members of a cached bulk-read plan.
    bool queuePreciseRead(Resource resource,Heap heap,uint32_t stages) {
        requireNotFlushing();++_stats.preciseReadQueueCalls;
        if(resource==Resource{}||!stages)return false;
        auto writer=_writeIndex.find(resource);
        if(writer!=_writeIndex.end()&&_writes[writer->second].heap!=heap)
            throw std::logic_error("retained resource changed heap identity");
        auto found=_readIndex.find(resource);size_t index;
        if(found==_readIndex.end()){
            index=_reads.size();_reads.push_back(ReadState{resource,heap,stages});
            _readIndex.emplace(resource,index);
        }else{
            index=found->second;
            if(_reads[index].heap!=heap)
                throw std::logic_error("retained resource changed heap identity");
            _reads[index].stages|=stages;
        }
        auto& entry=_reads[index];
        if(!entry.dirty){entry.dirty=true;_dirtyReads.push_back(index);}
        if(heap!=Heap{}){
            auto& h=_heaps[heapIndex(heap)];h.preciseReadStages|=stages;
            // A pending heap declaration may absorb these stages immediately.
            // An already emitted one must wait for the next queueHeapRead.
            if(h.dirty)h.readStages|=stages;
        }
        if(writer!=_writeIndex.end()){
            auto& write=_writes[writer->second];write.stages|=entry.stages;
            if(!write.dirty){write.dirty=true;_dirtyWrites.push_back(writer->second);}
        }
        return true;
    }
    // Repeated writes are coalesced until flush. Previous precise stage coverage
    // must be supplied too if the caller performs precise reads outside this API.
    // The heap of a retained resource identity is immutable within an encoder.
    bool queueWrite(Resource resource,Heap heap,uint32_t stages) {
        requireNotFlushing();
        ++_stats.writeQueueCalls;
        if(resource==Resource{}||!stages)return false;
        auto reader=_readIndex.find(resource);
        if(reader!=_readIndex.end()){
            const auto& read=_reads[reader->second];
            if(read.heap!=heap)throw std::logic_error("retained resource changed heap identity");
            stages|=read.stages;
        }
        auto found=_writeIndex.find(resource);size_t index;
        if(found==_writeIndex.end()){
            index=_writes.size();
            _writes.push_back(WriteState{resource,heap,stages});
            _writeIndex.emplace(resource,index);
            if(heap!=Heap{})_heaps[heapIndex(heap)].writes.push_back(index);
        }else{
            index=found->second;
            if(_writes[index].heap!=heap)
                throw std::logic_error("retained resource changed heap identity");
            _writes[index].stages|=stages;
        }
        auto& entry=_writes[index];
        if(!entry.dirty){entry.dirty=true;_dirtyWrites.push_back(index);}
        return true;
    }
    // heapCallback(Heap,uint32_t readStages), readCallback(Resource,uint32_t
    // preciseReadStages), then afterHeapsCallback() for grouped heap/read
    // emission, followed by
    // writeCallback(Resource,uint32_t readWriteStages).
    // Callbacks must not mutate this ledger. If a callback throws, dirty state
    // remains and a retry replays heap reads and write exceptions conservatively.
    template<class HeapCallback,class ReadCallback,class WriteCallback,class AfterHeapsCallback>
    void flush(HeapCallback&& heapCallback,ReadCallback&& readCallback,WriteCallback&& writeCallback,
               AfterHeapsCallback&& afterHeapsCallback) {
        requireNotFlushing();
        _flushing=true;
        struct Restore {bool& flag;~Restore(){flag=false;}} restore{_flushing};
        ++_stats.flushes;
        if(++_flushSerial==0){for(auto& w:_writes)w.selectedSerial=0;_flushSerial=1;}
        _selectedWrites.clear();
        for(size_t index:_dirtyWrites){++_stats.writeMetadataVisits;selectWrite(index);}
        for(size_t index:_dirtyHeaps){
            for(size_t wi:_heaps[index].writes){++_stats.writeMetadataVisits;selectWrite(wi);}
        }
        // Heap reads may reset native per-resource write declarations. Emit all
        // touched heaps first, then reassert every tracked write exception last.
        for(size_t index:_dirtyHeaps){
            const auto& entry=_heaps[index];
            heapCallback(entry.heap,entry.readStages);++_stats.heapCallsEmitted;
        }
        for(size_t index:_dirtyReads){
            ++_stats.readMetadataVisits;const auto& entry=_reads[index];
            if(_writeIndex.find(entry.resource)!=_writeIndex.end()){
                ++_stats.readQueueSuperseded;continue;
            }
            readCallback(entry.resource,entry.stages|heapReadStages(entry.heap));
            ++_stats.readCallsEmitted;
        }
        // The caller can emit aggregated heap arrays and precise reads here.
        // All queued write exceptions still run afterwards. This callback also
        // runs when there are no dirty heaps, so precise-only batches can flush.
        afterHeapsCallback();
        for(size_t index:_selectedWrites){
            const auto& entry=_writes[index];
            writeCallback(entry.resource,entry.stages|heapReadStages(entry.heap));
            ++_stats.writeCallsEmitted;
        }
        for(size_t index:_dirtyHeaps)_heaps[index].dirty=false;
        for(size_t index:_dirtyReads)_reads[index].dirty=false;
        for(size_t index:_selectedWrites)_writes[index].dirty=false;
        _dirtyHeaps.clear();_dirtyReads.clear();_dirtyWrites.clear();_selectedWrites.clear();
    }
    template<class HeapCallback,class WriteCallback,class AfterHeapsCallback>
    void flush(HeapCallback&& heapCallback,WriteCallback&& writeCallback,
               AfterHeapsCallback&& afterHeapsCallback) {
        flush(std::forward<HeapCallback>(heapCallback),
              [](Resource,uint32_t){throw std::logic_error("precise read callback required");},
              std::forward<WriteCallback>(writeCallback),
              std::forward<AfterHeapsCallback>(afterHeapsCallback));
    }
    template<class HeapCallback,class WriteCallback>
    void flush(HeapCallback&& heapCallback,WriteCallback&& writeCallback) {
        flush(std::forward<HeapCallback>(heapCallback),
              std::forward<WriteCallback>(writeCallback),[]{});
    }
    // Must be called at every native Metal encoder boundary, including resumed
    // render passes, rather than only at a Vulkan submission boundary.
    void reset() {
        requireNotFlushing();
        _heapIndex.clear();_writeIndex.clear();_readIndex.clear();_heaps.clear();_writes.clear();_reads.clear();
        _dirtyHeaps.clear();_dirtyReads.clear();_dirtyWrites.clear();_selectedWrites.clear();_flushSerial=0;
    }
    uint32_t coveredHeapReadStages(Heap heap) const { return heapReadStages(heap); }
    size_t heapCount() const {return _heaps.size();}
    size_t writeCount() const {return _writes.size();}
    size_t preciseReadCount() const {return _reads.size();}
    const Stats& stats() const {return _stats;}
    Stats takeStats(){requireNotFlushing();auto result=_stats;_stats={};return result;}
    void resetStats(){requireNotFlushing();_stats={};}
};
