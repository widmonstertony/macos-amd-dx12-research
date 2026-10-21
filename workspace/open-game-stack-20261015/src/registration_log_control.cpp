// SPDX-License-Identifier: Apache-2.0
#include "../native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKRegistrationLog.h"
#include <cassert>
#include <thread>
#include <vector>
#include <iostream>
int main() {
    MVKRegistrationLog<uintptr_t, 8, 4> log;
    uint64_t observed=99;
    auto contains=[](uintptr_t key) { return key==17; };
    assert(!log.requiresValidation(0, contains, observed) && observed==0);
    log.append(3);log.append(5);
    assert(!log.requiresValidation(0, contains, observed) && observed==2);
    log.append(17);
    assert(log.requiresValidation(0, contains, observed) && observed==3);
    assert(!log.requiresValidation(3, contains, observed));
    // Removing/re-registering an identity is represented by another append.
    log.append(17);assert(log.requiresValidation(3, contains, observed));
    for (int i=0;i<5;++i) log.append(23+i);
    assert(log.requiresValidation(4, contains, observed)); // query budget
    assert(log.requiresValidation(0, contains, observed)); // history overrun
    assert(log.requiresValidation(100, contains, observed)); // future sequence
    assert(!log.requiresValidation(8, contains, observed) && observed==9);
    MVKRegistrationLog<uintptr_t> shared;
    std::vector<std::thread> writers;
    for (int w=0;w<4;++w) writers.emplace_back([&,w] {
        for (int i=0;i<25000;++i) shared.append(1+w*25000+i);
    });
    uint64_t prior=0,reads=0;
    while (shared.current()<100000) {
        uint64_t now=shared.current();assert(now>=prior);prior=now;++reads;
        shared.requiresValidation(prior, [](uintptr_t){return false;}, observed);
        assert(observed>=prior);
    }
    for(auto& thread:writers) thread.join();
    assert(shared.current()==100000);
    std::cout << "{\"passed\":true,\"concurrentAppends\":100000,\"monotonicReads\":" << reads << ",\"boundedFallbacksTested\":true}\n";
}
