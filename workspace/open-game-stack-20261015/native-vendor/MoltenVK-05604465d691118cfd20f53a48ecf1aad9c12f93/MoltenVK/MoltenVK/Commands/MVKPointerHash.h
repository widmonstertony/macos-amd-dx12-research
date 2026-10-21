#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>

// Preserve pointer identity/equality while distributing aligned addresses over
// power-of-two bucket counts (libc++ uses them after reserve(1024)).
template<class Pointer> struct MVKPointerHash {
    std::size_t operator()(Pointer pointer) const noexcept {
        uint64_t x = std::hash<Pointer>{}(pointer);
        x ^= x >> 30; x *= UINT64_C(0xbf58476d1ce4e5b9);
        x ^= x >> 27; x *= UINT64_C(0x94d049bb133111eb);
        return x ^ (x >> 31);
    }
};
