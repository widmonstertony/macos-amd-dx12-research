// Measure the exact liveness-validation crossover using real AMD Metal objects.
// Both paths retain every accepted object; no GPU feature is emulated or skipped.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "MVKDevice.h"
#include <chrono>
#include <fstream>
#include <stdexcept>

static void need(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

int main(int argc, const char** argv) { @autoreleasepool { try {
    need(argc == 2, "report path required");
    id<MTLDevice> device = nil;
    for (id<MTLDevice> candidate in MTLCopyAllDevices()) {
        if ([candidate.name containsString:@"5600M"]) { device = [candidate retain]; break; }
    }
    need(device != nil, "Radeon Pro 5600M required");

    constexpr unsigned maximum = 4096;
    std::vector<id<MTLBuffer>> buffers;
    buffers.reserve(maximum);
    MVKLiveList live;
    for (unsigned i = 0; i < maximum; ++i) {
        id<MTLBuffer> buffer = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        need(buffer != nil, "Metal buffer allocation failed");
        buffers.push_back(buffer);
        live.add(buffer);
    }

    const unsigned sizes[] = {1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096};
    std::ofstream report(argv[1]);
    report << "{\"device\":\"Radeon Pro 5600M\",\"rows\":[";
    bool first = true;
    for (unsigned size : sizes) {
        auto snapshot = std::make_shared<MVKDescriptorUseCache::Resources>();
        snapshot->reserve(size);
        for (unsigned i = 0; i < size; ++i) snapshot->push_back(buffers[i]);
        unsigned iterations = std::max(64u, 131072u / size);

        uintptr_t sink = 0;
        auto directStart = std::chrono::steady_clock::now();
        for (unsigned iteration = 0; iteration < iterations; ++iteration) {
            for (id<MTLResource> resource : *snapshot) {
                auto accepted = live.isLive(resource);
                sink += bool(accepted);
            }
        }
        double directMS = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - directStart).count();

        auto shardStart = std::chrono::steady_clock::now();
        for (unsigned iteration = 0; iteration < iterations; ++iteration) {
            auto accepted = live.retainedSnapshotOnce(snapshot);
            sink += accepted->size();
        }
        double shardMS = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - shardStart).count();
        need(sink == uintptr_t(size) * iterations * 2, "validation path lost a live object");

        if (!first) report << ',';
        first = false;
        report << "{\"resources\":" << size
               << ",\"iterations\":" << iterations
               << ",\"directMilliseconds\":" << directMS
               << ",\"shardedMilliseconds\":" << shardMS
               << ",\"shardedToDirect\":" << shardMS / directMS << '}';
    }
    report << "],\"semanticsMatched\":true}\n";
    for (id<MTLBuffer> buffer : buffers) { live.remove(buffer); [buffer release]; }
    [device release];
    return 0;
  } catch (const std::exception& error) {
    fprintf(stderr, "ERROR %s\n", error.what());
    return 2;
  }
} }
