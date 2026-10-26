// Opt-in per-source native compute archives. Cold compilation remains normal;
// publication follows successful compilation and never holds the device monitor.
#pragma once
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>
#include <mutex>
#include <memory>
#include <string>
#include <utility>
#include <cstdint>
#include <limits>
#if !defined(MVK_ARCHIVE_ADMISSION_CPU_CONTROL)
#include "MVKForensicsTrace.h"
#endif

// Process-local reservation ledger, shared by compute/render writers. No Metal
// work is needed when admission is impossible. Reserve the maximum accepted
// shard size before construction: this may leave a tail smaller than one shard
// limit unused, but never predicts opaque Metal output or enlarges the budget.
class MVKArchiveAdmissionLedger {
public:
    enum class Decision { Accepted, Budget, Pending, Invalid };
    struct Stats {
        uint64_t committed=0,reserved=0,pending=0,inventoryRuns=0;
        uint64_t accepted=0,budgetSkipped=0,pendingSkipped=0,invalid=0,published=0,failed=0;
    };
private:
    struct State {
        std::mutex lock;
        bool initialized=false;
        uint64_t maximum=0;
        Stats stats;
        std::unordered_set<std::string> pending;
    };
    std::mutex _rootsLock;
    std::unordered_map<std::string,std::shared_ptr<State>> _roots;
public:
    class Reservation {
        friend class MVKArchiveAdmissionLedger;
        std::shared_ptr<State> _state;
        std::string _key;
        uint64_t _bytes=0;
        Decision _decision=Decision::Invalid;
        explicit Reservation(Decision decision):_decision(decision){}
        Reservation(std::shared_ptr<State> state,std::string key,uint64_t bytes):
            _state(std::move(state)),_key(std::move(key)),_bytes(bytes),_decision(Decision::Accepted){}
        void settleLocked(bool published,uint64_t actual){
            auto&stats=_state->stats;
            stats.reserved-=_bytes;
            _state->pending.erase(_key);
            stats.pending=_state->pending.size();
            if(published){stats.committed+=actual;++stats.published;}else ++stats.failed;
            _bytes=0;
        }
    public:
        Reservation()=default;
        Reservation(const Reservation&)=delete;
        Reservation&operator=(const Reservation&)=delete;
        Reservation(Reservation&&other)noexcept:
            _state(std::move(other._state)),_key(std::move(other._key)),_bytes(other._bytes),_decision(other._decision){other._bytes=0;}
        Reservation&operator=(Reservation&&other)noexcept {
            if(this!=&other){cancel();_state=std::move(other._state);_key=std::move(other._key);_bytes=other._bytes;_decision=other._decision;other._bytes=0;}return *this;
        }
        ~Reservation(){cancel();}
        explicit operator bool()const{return _bytes!=0;}
        uint64_t reservedBytes()const{return _bytes;}
        Decision decision()const{return _decision;}
        void cancel(){
            if(!_bytes)return;
            {std::lock_guard<std::mutex> guard(_state->lock);settleLocked(false,0);}
            _state.reset();
        }
        template<class Link> bool publish(uint64_t actual,Link&&atomicLink){
            if(!_bytes)return false;
            bool published=false;
            {std::lock_guard<std::mutex> guard(_state->lock);
                // The pre-reserved maximum covers every accepted actual size.
                // Hold this short lock through create-only publication/accounting.
                if(actual&&actual<_bytes)published=atomicLink();
                settleLocked(published,actual);
            }
            _state.reset();return published;
        }
    };
    template<class Inventory> Reservation reserve(const std::string&root,std::string key,
                                                  uint64_t maximum,uint64_t shardMaximum,
                                                  Inventory&&inventory){
        std::shared_ptr<State> state;
        {std::lock_guard<std::mutex> guard(_rootsLock);auto&slot=_roots[root];if(!slot)slot=std::make_shared<State>();state=slot;}
#if !defined(MVK_ARCHIVE_ADMISSION_CPU_CONTROL) || defined(MVK_ARCHIVE_ADMISSION_FORENSICS_CONTROL)
        // Only copy decision POD while locked. Emit after guard destruction so
        // diagnostics never add the writer lock beneath the admission lock.
        struct DecisionObservation {
            bool armed;const void*ledger;const void*state;uint64_t maximum,shard;
            Decision decision=Decision::Invalid;Stats stats{};bool noted=false;
            void note(Decision d,const Stats&s){if(armed){decision=d;stats=s;noted=true;}}
            ~DecisionObservation(){if(armed&&noted&&mvkForensicsArmed())
                mvkForensicsRecord("archive-admission",{{"ledgerInstance",reinterpret_cast<uintptr_t>(ledger)},
                    {"rootStateInstance",reinterpret_cast<uintptr_t>(state)},{"decision",uint64_t(decision)},
                    {"maximumBytes",maximum},{"shardMaximumBytes",shard},{"committedBytes",stats.committed},
                    {"reservedBytes",stats.reserved},{"pending",stats.pending},
                    {"budgetSkippedTotal",stats.budgetSkipped},{"pendingSkippedTotal",stats.pendingSkipped}});}
        } observation{mvkForensicsArmed(),this,state.get(),maximum,shardMaximum};
        auto observe=[&](Decision decision,const Stats&stats){observation.note(decision,stats);};
#else
        auto observe=[](Decision,const Stats&){};
#endif
        std::lock_guard<std::mutex> guard(state->lock);
        if(!state->initialized){++state->stats.inventoryRuns;state->stats.committed=inventory();state->maximum=maximum;state->initialized=true;}
        auto&stats=state->stats;
        if(!maximum||!shardMaximum||maximum!=state->maximum){++stats.invalid;observe(Decision::Invalid,stats);return Reservation(Decision::Invalid);}
        if(state->pending.find(key)!=state->pending.end()){++stats.pendingSkipped;observe(Decision::Pending,stats);return Reservation(Decision::Pending);}
        if(stats.committed>maximum||stats.reserved>maximum-stats.committed||
           shardMaximum>maximum-stats.committed-stats.reserved){++stats.budgetSkipped;observe(Decision::Budget,stats);return Reservation(Decision::Budget);}
        state->pending.insert(key);stats.reserved+=shardMaximum;stats.pending=state->pending.size();++stats.accepted;
        observe(Decision::Accepted,stats);
        return Reservation(state,std::move(key),shardMaximum);
    }
    Stats snapshot(const std::string&root){
        std::shared_ptr<State> state;
        {std::lock_guard<std::mutex> guard(_rootsLock);auto found=_roots.find(root);if(found==_roots.end())return {};state=found->second;}
        std::lock_guard<std::mutex> guard(state->lock);return state->stats;
    }
};

inline MVKArchiveAdmissionLedger& mvkArchiveAdmissionLedger(){static MVKArchiveAdmissionLedger ledger;return ledger;}

#if !defined(MVK_ARCHIVE_ADMISSION_CPU_CONTROL)
#include "MVKMeshLinkDifferential.h"

// Wine drives pipeline creation from long-lived worker threads that do not
// necessarily drain an Objective-C autorelease pool between requests. An array
// literal here would therefore retain each per-request MTLBinaryArchive (and its
// file mapping) until the worker exits. Keep the temporary ownership explicit;
// the descriptor retains the array for exactly as long as it needs it.
static void mvkSetBinaryArchive(id descriptor, id<MTLBinaryArchive> archive) {
    NSArray* archives = [[NSArray alloc] initWithObjects:archive, nil];
    [descriptor setBinaryArchives:archives];
    [archives release];
}

static uint64_t mvkComputeArchiveLimit(const char* name, uint64_t fallback) {
    const char* value = getenv(name);
    if (!value) return fallback;
    char* end = nullptr;
    uint64_t parsed = strtoull(value, &end, 10);
    return end && !*end && parsed ? parsed : fallback;
}

static NSString* mvkComputeShardPath(MTLComputePipelineDescriptor* descriptor) {
    const char* rootC = getenv("MVK_AMD_COMPUTE_ARCHIVE_DIR");
    if (!rootC || rootC[0] != '/') return nil;
    NSString* label = descriptor.label;
    if (![label hasPrefix:@"mvk-cs2-"] || label.length != 72) return nil;
    NSString* key = [label substringFromIndex:8];
    NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"] invertedSet];
    if ([key rangeOfCharacterFromSet:invalid].location != NSNotFound) return nil;
    NSString* root = [NSString stringWithUTF8String:rootC];
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&directory] || !directory)
        return nil;
    NSString* name = [NSString stringWithFormat:@"cs2-%@-%lu-%u.metalar", key,
        (unsigned long)descriptor.maxTotalThreadsPerThreadgroup,
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth ? 1 : 0];
    return [root stringByAppendingPathComponent:name];
}

static bool mvkLoadComputeShard(id<MTLDevice> device,
                               MTLComputePipelineDescriptor* descriptor, NSString* path) {
    if (!path) return false;
    struct stat info {};
    uint64_t limit = mvkComputeArchiveLimit("MVK_AMD_COMPUTE_ARCHIVE_MAX_SHARD_BYTES", 16ull << 20);
    if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || (uint64_t)info.st_size >= limit) return false;
    MTLBinaryArchiveDescriptor* archiveDescriptor = [MTLBinaryArchiveDescriptor new];
    archiveDescriptor.url = [NSURL fileURLWithPath:path];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
    [archiveDescriptor release];
    if (!archive) return false;
    mvkSetBinaryArchive(descriptor, archive); // The descriptor retains this request's archive.
    [archive release];
    return true;
}

// A process-local admission budget includes existing owned shard files. No cache
// eviction or deletion is performed. Separate processes sharing one directory
// can exceed this admission budget, so callers should use a per-game directory.
static MVKArchiveAdmissionLedger::Reservation mvkReserveArchiveShard(NSString* path,
                                  NSString* prefix,const char* budgetName,const char* shardName) {
    NSString* root = path.stringByDeletingLastPathComponent;
    std::string rootKey = std::string(root.fileSystemRepresentation) + ":" + prefix.UTF8String;
    return mvkArchiveAdmissionLedger().reserve(rootKey,path.fileSystemRepresentation,
        mvkComputeArchiveLimit(budgetName,2ull<<30),mvkComputeArchiveLimit(shardName,16ull<<20),[&] {
        uint64_t existing = 0;
        for (NSString* name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
            if (![name hasPrefix:prefix] || ![name hasSuffix:@".metalar"]) continue;
            struct stat info {};
            NSString* file = [root stringByAppendingPathComponent:name];
            if (!lstat(file.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) && info.st_size > 0)
                existing = (uint64_t)info.st_size>std::numeric_limits<uint64_t>::max()-existing ?
                    std::numeric_limits<uint64_t>::max() : existing+(uint64_t)info.st_size;
        }
        return existing;
    });
}

static bool mvkPublishComputeShard(MVKArchiveAdmissionLedger::Reservation& reservation,
                                  NSString* temporary,NSString* path,uint64_t bytes) {
    // Atomic create-only publication. Concurrent writers never overwrite an
    // existing archive, including an incompatible one retained for diagnosis.
    return reservation.publish(bytes,[&] {return link(temporary.fileSystemRepresentation,path.fileSystemRepresentation)==0;});
}

static bool mvkStoreComputeShard(id<MTLDevice> device,
                                MTLComputePipelineDescriptor* descriptor, NSString* path) {
    if (!path || [[NSFileManager defaultManager] fileExistsAtPath:path]) return false;
    auto reservation=mvkReserveArchiveShard(path,@"cs2-","MVK_AMD_COMPUTE_ARCHIVE_MAX_TOTAL_BYTES",
                                           "MVK_AMD_COMPUTE_ARCHIVE_MAX_SHARD_BYTES");
    if(!reservation)return false;
    MTLBinaryArchiveDescriptor* archiveDescriptor = [MTLBinaryArchiveDescriptor new];
    NSError* error = nil;
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:archiveDescriptor error:&error];
    [archiveDescriptor release];
    if (!archive) return false;
    mvkSetBinaryArchive(descriptor, archive);
    uint64_t operation=mvkLinkOperationBegin(@"compute-archive-add",descriptor.label);
    bool added = [archive addComputePipelineFunctionsWithDescriptor:descriptor error:&error];
    mvkLinkOperationEnd(operation);
    NSString* temporary = [path stringByAppendingFormat:@".tmp.%@", [NSUUID UUID].UUIDString];
    bool serialized = added && [archive serializeToURL:[NSURL fileURLWithPath:temporary] error:&error];
    bool published = false;
    if (serialized) {
        struct stat info {};
        uint64_t limit = reservation.reservedBytes();
        if (!lstat(temporary.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) &&
            info.st_size > 0 && (uint64_t)info.st_size < limit)
            published = mvkPublishComputeShard(reservation,temporary,path,(uint64_t)info.st_size);
    }
    // Only this call's unique unpublished temporary is removed. Existing cache
    // files and all user assets are preserved, even when admission is refused.
    unlink(temporary.fileSystemRepresentation);
    [archive release];
    return published;
}
#endif // !MVK_ARCHIVE_ADMISSION_CPU_CONTROL
