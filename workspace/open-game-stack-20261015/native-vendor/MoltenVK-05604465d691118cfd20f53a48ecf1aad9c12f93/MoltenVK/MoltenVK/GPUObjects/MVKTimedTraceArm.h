// Copyright 2026 macos-amd-dx12-research contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <chrono>
#include <ctime>
#include <sys/stat.h>

// Diagnostic work capture is normally disabled. An owned marker enables at
// most 30 seconds, and filesystem checks occur at most four times/sec/thread.
// This never changes GPU commands, waits, signals or result codes.
class MVKTimedTraceArm {
    const char* path;
public:
    explicit MVKTimedTraceArm(const char* value) : path(value) {}
    bool enabled() const {
        if (!path || !path[0]) return false;
        struct Cache { const void* owner=nullptr; std::chrono::steady_clock::time_point next{}; bool armed=false; };
        static thread_local Cache cache;
        auto now = std::chrono::steady_clock::now();
        if (cache.owner != this || now >= cache.next) {
            cache.owner = this;
            cache.next = now + std::chrono::milliseconds(250);
            struct stat info{};
            std::time_t wall = std::time(nullptr);
            cache.armed = stat(path, &info) == 0 && S_ISREG(info.st_mode) &&
                info.st_mtime <= wall && wall - info.st_mtime < 30;
        }
        return cache.armed;
    }
};
