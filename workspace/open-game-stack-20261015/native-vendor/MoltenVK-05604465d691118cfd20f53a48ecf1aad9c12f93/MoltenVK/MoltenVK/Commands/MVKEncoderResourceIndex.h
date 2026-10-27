// Encoder-local identity -> dense-state index. No ownership, erasure or native
// residency decisions. Clear invalidates every entry and retains slot capacity
// so encoder boundaries do not allocate/free one hash node per resource.
#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <limits>
#include <stdexcept>
#include <vector>

template<class Key, class Hash = std::hash<Key>> class MVKEncoderResourceIndex {
    struct Slot { Key key{}; size_t value=0; uint64_t generation=0; };
    std::vector<Slot> _slots;
    size_t _size=0;
    uint64_t _generation=1;
    static size_t bucket(Key key, size_t mask) {
        // Metal object pointers are aligned. Mix high bits before masking;
        // identity hashing alone clusters them in a power-of-two table.
        uint64_t h=static_cast<uint64_t>(Hash{}(key));
        h^=h>>30;h*=UINT64_C(0xbf58476d1ce4e5b9);
        h^=h>>27;h*=UINT64_C(0x94d049bb133111eb);h^=h>>31;
        return static_cast<size_t>(h)&mask;
    }
    void grow() {
        if(_slots.size()>std::numeric_limits<size_t>::max()/2)
            throw std::length_error("encoder resource index capacity overflow");
        size_t capacity=_slots.empty()?16:_slots.size()*2;
        std::vector<Slot> next(capacity);
        for(const auto& old:_slots) {
            if(old.generation!=_generation)continue;
            size_t i=bucket(old.key,capacity-1);
            while(next[i].generation==_generation)i=(i+1)&(capacity-1);
            next[i]=old;
        }
        _slots.swap(next);
    }
public:
    // Returned pointers survive lookups, but not insertion/growth or clear.
    const size_t* findValue(Key key) const {
        if(_slots.empty())return nullptr;
        size_t i=bucket(key,_slots.size()-1);
        while(_slots[i].generation==_generation) {
            if(_slots[i].key==key)return &_slots[i].value;
            i=(i+1)&(_slots.size()-1);
        }
        return nullptr;
    }
    void emplace(Key key,size_t value) {
        if(findValue(key))return;
        if(_slots.empty()||_size>=_slots.size()/2)grow();
        size_t i=bucket(key,_slots.size()-1);
        while(_slots[i].generation==_generation)i=(i+1)&(_slots.size()-1);
        _slots[i]={key,value,_generation};++_size;
    }
    void clear() {
        _size=0;
        if(++_generation==0) {
            for(auto& slot:_slots)slot.generation=0;
            _generation=1;
        }
    }
    size_t size() const { return _size; }
};
