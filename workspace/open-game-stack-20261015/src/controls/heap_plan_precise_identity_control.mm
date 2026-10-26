// CPU regression for tryAddBufferHeapSnapshot's precise-fallback heap argument.
// Real plan and ledger headers; NSObject property doubles; no Metal device/work.
#include "MVKBufferHeapReadPlan.h"
#include "MVKEncoderHeapLedger.h"
#import <objc/runtime.h>
#include <cctype>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>

@interface CPUHeap : NSObject { @public MTLHeapType kind; }
- (MTLHeapType)type;
- (NSUInteger)size;
@end
@implementation CPUHeap
- (MTLHeapType)type { return kind; }
- (NSUInteger)size { return 1u << 24; }
@end

@interface CPUResource : NSObject {
@public id<MTLHeap> parentHeap; bool texture, view, aliasable;
    MTLTextureUsage resourceUsage; MTLTextureType resourceType;
}
- (id<MTLHeap>)heap;
- (MTLTextureUsage)usage;
- (MTLTextureType)textureType;
- (NSUInteger)sampleCount;
- (MTLStorageMode)storageMode;
- (id<MTLTexture>)parentTexture;
- (id<MTLBuffer>)buffer;
- (BOOL)isAliasable;
- (NSUInteger)heapOffset;
- (NSUInteger)allocatedSize;
@end
@implementation CPUResource
- (BOOL)conformsToProtocol:(Protocol*)p {
    if (protocol_isEqual(p, @protocol(MTLTexture))) return texture;
    return [super conformsToProtocol:p];
}
- (id<MTLHeap>)heap { return parentHeap; }
- (MTLTextureUsage)usage { return resourceUsage; }
- (MTLTextureType)textureType { return resourceType; }
- (NSUInteger)sampleCount { return 1; }
- (MTLStorageMode)storageMode { return MTLStorageModePrivate; }
- (id<MTLTexture>)parentTexture { return view ? (id<MTLTexture>)self : nil; }
- (id<MTLBuffer>)buffer { return nil; }
- (BOOL)isAliasable { return aliasable; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize { return 256; }
@end

using Resource = id<MTLResource>;
using Heap = id<MTLHeap>;
using Ledger = MVKEncoderHeapLedger<Resource, Heap>;
static unsigned checks = 0, negativeChecks = 0;
static void need(bool ok, const char* what) {
    ++checks;
    if (!ok) throw std::runtime_error(what);
}
template<class F> static void changedHeapRejected(F action) {
    bool rejected = false;
    try { action(); }
    catch (const std::logic_error& e) {
        rejected = std::string(e.what()) == "retained resource changed heap identity";
    }
    need(rejected, "genuine heap change was not rejected with exact logic_error");
    ++negativeChecks;
}

struct Fixture {
    std::vector<Resource> resources;
    std::vector<CPUHeap*> heaps;
    Resource excluded = nil;
    Heap makeHeap() {
        CPUHeap* h = [CPUHeap new]; h->kind = MTLHeapTypeAutomatic;
        heaps.push_back(h); return (Heap)h;
    }
    Resource add(Heap heap, bool isTexture = true) {
        CPUResource* r = [CPUResource new];
        r->parentHeap = heap; r->texture = isTexture;
        r->resourceUsage = MTLTextureUsageShaderRead;
        r->resourceType = MTLTextureType2D;
        resources.push_back((Resource)r); return (Resource)r;
    }
    Fixture() {
        Heap bulk = makeHeap(), precise = makeHeap();
        for (unsigned i = 0; i < 128; ++i) add(bulk);
        excluded = add(precise);
        ((CPUResource*)excluded)->resourceUsage |= MTLTextureUsageShaderWrite;
        ((CPUResource*)add(precise))->resourceUsage |= MTLTextureUsageRenderTarget;
        ((CPUResource*)add(precise))->view = true;
        ((CPUResource*)add(precise))->resourceType = MTLTextureType3D;
        ((CPUResource*)add(precise))->aliasable = true;
        add(nil); // A truly heapless sampled texture shares the historical bucket.
    }
    ~Fixture() {
        for (Resource r : resources) [r release];
        for (CPUHeap* h : heaps) [h release];
    }
};

struct State { uint32_t stages = 0; bool writes = false, precise = false; };
struct Info { Heap heap = nil; bool heapKnown = false; uint32_t stages = 0; bool writes = false; };
struct Caller {
    const std::vector<Resource>& resources;
    Ledger ledger;
    std::map<Resource, Info> used;
    std::map<Resource, State> required, native;
    unsigned flushes = 0, resets = 0;
    explicit Caller(const std::vector<Resource>& owned) : resources(owned) {}
    void queue(Resource r, Info& info) {
        // bindHeapPlansAndReset / ownHeapPlanResource: query only unknown heaps.
        if (!info.heapKnown) { info.heap = r.heap; info.heapKnown = true; }
        if (info.writes) ledger.queueWrite(r, info.heap, info.stages);
        else ledger.queuePreciseRead(r, info.heap, info.stages);
    }
    void precise(Resource r, uint32_t stages, bool write = false) {
        auto& want = required[r]; want.stages |= stages; want.precise = true;
        want.writes |= write;
        auto& info = used[r]; info.stages |= stages; info.writes |= write;
        queue(r, info);
    }
    void fetch(uint32_t stages) {
        // texture.read() rejects sampled-only plans and uses precise declarations.
        for (Resource r : resources) precise(r, stages);
    }
    void sample(const BufferHeapReadPlan& plan, uint32_t stages, bool actualHeap) {
        need(plan.eligibleResourceCount(2) >= 128, "sample plan not admitted by real threshold");
        for (const auto& group : plan.groups) {
            if (group.resources.size() < 2) continue;
            ledger.queueHeapRead(group.heap, stages, 1);
            for (Resource r : group.resources) required[r].stages |= stages;
        }
        // Mirrors the caller's exact addPrecise metadata assignment, followed by
        // the pending flush. Only the historical bucket heap argument differs.
        auto addPrecise = [&](Resource r, Heap heap) {
            auto& info = used[r]; info.heap = heap; info.heapKnown = true;
            precise(r, stages);
        };
        for (Resource r : plan.nilHeapResources) addPrecise(r, actualHeap ? r.heap : nil);
        for (const auto& group : plan.groups)
            if (group.resources.size() < 2)
                for (Resource r : group.resources) addPrecise(r, group.heap);
    }
    unsigned incorrectHeapMetadata() const {
        unsigned n = 0;
        for (const auto& pair : used) n += pair.second.heap != pair.first.heap;
        return n;
    }
    void flush() {
        ledger.flush([&](Heap heap, uint32_t stages) {
            for (Resource r : resources)
                if (r.heap == heap) native[r] = {stages, false, false};
        }, [&](Resource r, uint32_t stages) { native[r] = {stages, false, true}; },
        [&](Resource r, uint32_t stages) { native[r] = {stages, true, true}; }, [] {});
        ++flushes;
        for (const auto& pair : required) {
            auto it = native.find(pair.first);
            need(it != native.end(), "missing resource declaration");
            const auto& got = it->second; const auto& want = pair.second;
            need((got.stages & want.stages) == want.stages, "stage coverage lost");
            need(!want.writes || got.writes, "write downgraded");
            need(!want.precise || got.precise, "precise fallback lost");
        }
    }
    void reset() {
        ledger.reset(); used.clear(); native.clear(); required.clear(); ++resets;
    }
};

static bool currentCallerUsesActualHeap(const char* source) {
    std::ifstream f(source); need(bool(f), "cannot read actual caller source");
    std::string text((std::istreambuf_iterator<char>(f)), {}), compact;
    for (unsigned char c : text) if (!std::isspace(c)) compact += char(c);
    auto start = compact.find("boolMVKUseResourceHelper::tryAddBufferHeapSnapshot(");
    auto end = compact.find("id<MTLHeap>MVKUseResourceHelper::ownHeapPlanResource", start);
    need(start != std::string::npos && end != std::string::npos, "caller boundaries not found");
    auto body = compact.substr(start, end - start);
    const std::string fixed = "for(id<MTLResource>resource:plan.nilHeapResources)addPrecise(resource,resource.heap);";
    const std::string old = "for(id<MTLResource>resource:plan.nilHeapResources)addPrecise(resource,nil);";
    need((body.find(fixed) != std::string::npos) != (body.find(old) != std::string::npos),
         "unrecognized or ambiguous actual caller heap argument");
    return body.find(fixed) != std::string::npos;
}

int main(int argc, char** argv) { @autoreleasepool { try {
    need(argc == 3, "usage: control report.json actual-MVKCommandEncoderState.mm");
    const bool actualCaller = currentCallerUsesActualHeap(argv[2]);
    Fixture f;
    BufferHeapReadPlan plan(f.resources, true);
    need(plan.resourceCount() == 134, "fixture count");
    need(plan.eligibleResourceCount(2) == 128, "eligible sampled group changed");
    need(plan.nilHeapResources.size() == 6, "real plan exclusion bucket changed");
    unsigned backed = 0;
    for (Resource r : plan.nilHeapResources) backed += r.heap != nil;
    need(backed == 5, "excluded heap-backed textures not actually classified");

    Caller legacy(f.resources);
    legacy.fetch(1); legacy.flush();
    bool reproduced = false;
    try { legacy.sample(plan, 2, false); }
    catch (const std::logic_error& e) {
        reproduced = std::string(e.what()) == "retained resource changed heap identity";
    }
    need(reproduced, "old caller no longer reproduces exact observed exception");
    Caller reverseLegacy(f.resources);
    reverseLegacy.sample(plan, 1, false); reverseLegacy.flush();
    reverseLegacy.fetch(2); reverseLegacy.flush();
    need(reverseLegacy.incorrectHeapMetadata() == 5, "old reverse-order false nil metadata not exercised");

    unsigned orderCases = 0, flushes = 0, resets = 0;
    Heap other = f.makeHeap();
    for (bool fetchFirst : {true, false}) {
        Caller fixed(f.resources);
        for (unsigned encoder = 0; encoder < 2; ++encoder) {
            bool order = encoder ? !fetchFirst : fetchFirst;
            if (order) { fixed.fetch(1); fixed.flush(); fixed.sample(plan, 2, actualCaller); }
            else { fixed.sample(plan, 1, actualCaller); fixed.flush(); fixed.fetch(2); }
            fixed.flush();
            need(fixed.incorrectHeapMetadata() == 0, "caller overwrote actual heap with nil");
            fixed.fetch(4); fixed.flush(); // Stage upgrade after both paths.
            fixed.precise(f.excluded, 8, true); fixed.flush();
            fixed.sample(plan, 16, actualCaller); fixed.flush();
            need(fixed.native.at(f.excluded).writes && fixed.native.at(f.excluded).stages == 31,
                 "sample path lost prior fetch/write/stage coverage");
            changedHeapRejected([&] { fixed.ledger.queuePreciseRead(f.resources.front(), other, 1); });
            changedHeapRejected([&] { fixed.ledger.queueWrite(f.excluded, other, 1); });
            ++orderCases;
            fixed.reset();
        }
        flushes += fixed.flushes; resets += fixed.resets;
    }
    // A real identity change stays forbidden in either direction in one encoder.
    Ledger genuine;
    Resource resource = f.excluded;
    genuine.queuePreciseRead(resource, resource.heap, 1);
    changedHeapRejected([&] { genuine.queuePreciseRead(resource, nil, 2); });
    genuine.reset(); genuine.queuePreciseRead(resource, nil, 1);
    changedHeapRejected([&] { genuine.queuePreciseRead(resource, resource.heap, 2); });
    genuine.reset(); genuine.queuePreciseRead(resource, other, 1); // New encoder permits new identity.

    // Buffer-only mode keeps grouping real buffers and does not widen sampled eligibility.
    std::vector<Resource> buffers;
    for (unsigned i = 0; i < 128; ++i) buffers.push_back(f.add(other, false));
    BufferHeapReadPlan bufferPlan(buffers, false), rejectedSampleBuffers(buffers, true);
    need(bufferPlan.eligibleResourceCount(2) == 128, "buffer path regressed");
    need(rejectedSampleBuffers.eligibleResourceCount(2) == 0, "buffers became sampled textures");

    std::ofstream out(argv[1]);
    out << "{\"passed\":true,\"CPUOnly\":true,\"realPlanHeader\":true,\"realLedgerHeader\":true,"
        << "\"actualCallerUsesResourceHeap\":" << (actualCaller ? "true" : "false")
        << ",\"eligibleSampledTextures\":128,\"excludedHeapBackedTextures\":5,\"trueNilHeapTextures\":1,"
        << "\"oldFetchThenSampleExactLogicErrorReproduced\":true,\"oldSampleThenFetchWrongNilMetadata\":5,"
        << "\"correctedOrderAndResetCases\":" << orderCases << ",\"flushes\":" << flushes
        << ",\"resets\":" << resets << ",\"genuineHeapChangeRejections\":" << negativeChecks
        << ",\"checks\":" << checks << ",\"MetalDevicesCreated\":0,\"GPUCommandsSubmitted\":0,"
        << "\"gameOperated\":false,\"scope\":\"CPU property doubles execute actual plan and ledger; caller metadata boundary modeled; full native helper and Metal driver not executed\"}\n";
    need(bool(out), "report write failed");
    std::cout << "passed; old exception reproduced; corrected order/reset cases=" << orderCases
              << "; genuine heap changes rejected=" << negativeChecks << '\n';
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 2; } } }
