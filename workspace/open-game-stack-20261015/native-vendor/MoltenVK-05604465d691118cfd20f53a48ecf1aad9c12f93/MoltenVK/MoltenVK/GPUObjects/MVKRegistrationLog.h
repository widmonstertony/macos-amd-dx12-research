/* Copyright 2026 macos-amd-dx12-research contributors. SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>

// Identities only: never dereference an object or keep its allocation alive.
// Publication shares the ring lock, so concurrent writers cannot publish a
// newer sequence and then overwrite it with an older one.
template<class Key, size_t Capacity = 4096, size_t QueryBudget = 64>
class MVKRegistrationLog {
    static_assert(Capacity > 0 && QueryBudget > 0, "Nonempty bounded log required");
    std::array<Key, Capacity> keys{};
    std::mutex lock;
    std::atomic<uint64_t> published{0};
public:
    uint64_t current() const { return published.load(std::memory_order_acquire); }
    void append(Key key) {
        std::lock_guard<std::mutex> guard(lock);
        uint64_t next = published.load(std::memory_order_relaxed) + 1;
        keys[(next - 1) % Capacity] = key;
        published.store(next, std::memory_order_release);
    }
    template<class Contains>
    bool requiresValidation(uint64_t since, Contains contains, uint64_t& observed) {
        std::array<Key, QueryBudget> recent{};
        size_t count = 0;
        {
            std::lock_guard<std::mutex> guard(lock);
            observed = published.load(std::memory_order_relaxed);
            // Overrun, excessive churn, or a future generation always uses the
            // original full validation path. No cached absence survives it.
            if (since > observed || observed - since > Capacity || observed - since > QueryBudget) return true;
            count = static_cast<size_t>(observed - since);
            for (size_t i = 0; i < count; ++i) recent[i] = keys[(since + i) % Capacity];
        }
        // Membership inspection must not hold up unrelated registrations.
        for (size_t i = 0; i < count; ++i) if (contains(recent[i])) return true;
        return false;
    }
};
