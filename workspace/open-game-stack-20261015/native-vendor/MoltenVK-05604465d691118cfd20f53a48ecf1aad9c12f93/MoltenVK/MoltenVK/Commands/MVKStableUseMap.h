// Append-only CPU map for encoder resource-use state. Deque values keep stable
// addresses for the recent-resource cache while the flat index can grow.
#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <utility>
#include <vector>

template<class Key, class Value> class MVKStableUseMap {
    struct Slot { Key key{}; std::size_t indexPlusOne = 0; };
    using Entries = std::deque<std::pair<Key, Value>>;
    Entries entries;
    std::vector<Slot> slots;
    void rehash(std::size_t capacity) {
        slots.assign(capacity, Slot{});
        for (std::size_t n=0;n<entries.size();++n) {
            auto i=std::hash<Key>{}(entries[n].first)&(capacity-1);
            while(slots[i].indexPlusOne)i=(i+1)&(capacity-1);
            slots[i]={entries[n].first,n+1};
        }
    }
public:
    using iterator=typename Entries::iterator;
    void reserve(std::size_t count) {
        if(count<=slots.size()/2)return;
        std::size_t capacity=16;
        while(capacity/2<count)capacity*=2;
        if(capacity>slots.size())rehash(capacity);
    }
    iterator begin() { return entries.begin(); }
    iterator end() { return entries.end(); }
    std::size_t size() const { return entries.size(); }
    iterator find(Key key) {
        if(slots.empty())return end();
        auto i=std::hash<Key>{}(key)&(slots.size()-1);
        while(slots[i].indexPlusOne) {
            if(slots[i].key==key)return entries.begin()+slots[i].indexPlusOne-1;
            i=(i+1)&(slots.size()-1);
        }
        return end();
    }
    std::pair<iterator,bool> emplace(Key key, const Value& value) {
        if(slots.empty())reserve(1);
        auto i=std::hash<Key>{}(key)&(slots.size()-1);
        while(slots[i].indexPlusOne) {
            if(slots[i].key==key)return {entries.begin()+slots[i].indexPlusOne-1,false};
            i=(i+1)&(slots.size()-1);
        }
        if(entries.size()+1>slots.size()/2) {
            reserve(entries.size()+1);
            i=std::hash<Key>{}(key)&(slots.size()-1);
            while(slots[i].indexPlusOne)i=(i+1)&(slots.size()-1);
        }
        entries.emplace_back(key,value);
        slots[i]={key,entries.size()};
        return {entries.end()-1,true};
    }
    void clear() {
        entries.clear();
        std::fill(slots.begin(),slots.end(),Slot{});
    }
};
