// CPU-only controls of immutable descriptor-set identity deltas. No GPU work.
#import <Metal/Metal.h>
#include "MVKDescriptorUseCache.h"
#include <random>
#include <set>
#include <stdexcept>
#include <cstdio>
#include <string>
#include <iterator>
using Key=id<MTLResource>;
using Set=std::set<Key>;
static void need(bool v,const char* why){if(!v)throw std::runtime_error(why);}
static Key key(unsigned n){return n?(Key)(uintptr_t(0x100000)+n*64):nil;}
static Set identities(const std::vector<Key>& slots){Set s(slots.begin(),slots.end());s.erase(nil);return s;}
int main(){@autoreleasepool{try{
 MVKDescriptorUseCache cache;std::vector<Key> slots(2048);
 for(unsigned i=0;i<slots.size();++i)slots[i]=key(i%1500+1);
 auto snapshot=[&]{return cache.resources((const char*)slots.data(),slots.size(),sizeof(Key));};
 auto old=snapshot();
 {auto write=cache.beginWrite((const char*)&slots[0],sizeof(Key));slots[0]=key(2000);}
 auto now=snapshot();need(now!=old&&now->previous.lock()==old,"small edit has no parent");
 need(now->added.size()==1&&now->removed.empty(),"duplicate removal changed identity membership");
 auto same=now;
 {auto write=cache.beginWrite((const char*)&slots[1],2*sizeof(Key));std::swap(slots[1],slots[2]);}
 now=snapshot();need(now==same,"slot shuffle needlessly replaced the immutable snapshot");
 std::mt19937 rng(3489700);unsigned deltas=0,unchanged=0;
 for(unsigned pass=0;pass<6000;++pass){
  old=now;Set before(old->begin(),old->end());unsigned pos=rng()%slots.size();
  {auto write=cache.beginWrite((const char*)&slots[pos],sizeof(Key));slots[pos]=key(rng()%2200);}
  now=snapshot();Set truth=identities(slots);need(Set(now->begin(),now->end())==truth,"snapshot differs from slot oracle");
  Set added,removed;
  std::set_difference(truth.begin(),truth.end(),before.begin(),before.end(),std::inserter(added,added.end()));
  std::set_difference(before.begin(),before.end(),truth.begin(),truth.end(),std::inserter(removed,removed.end()));
  if(added.empty()&&removed.empty()){need(now==old,"unchanged set lost identity");++unchanged;}
  else{need(now->previous.lock()==old,"delta does not name exact immutable parent");need(Set(now->added.begin(),now->added.end())==added&&Set(now->removed.begin(),now->removed.end())==removed,"net delta differs from independent set difference");++deltas;}
 }
 old=now;{auto write=cache.beginWrite((const char*)&slots[0],sizeof(Key));slots[0]=key(5000);}now=snapshot();
 std::weak_ptr<const MVKDescriptorUseCache::Resources> weak=old;old.reset();
 // Only the last two local snapshots were retained, never a strong ancestry.
 same.reset();need(weak.expired(),"snapshot ancestry retained an obsolete table");
 MVKDescriptorUseCache large;std::vector<Key> full(5000,key(1));
 auto initial=large.resources((const char*)full.data(),full.size(),sizeof(Key));
 {auto write=large.beginWrite();std::fill(full.begin(),full.end(),key(2));}
 auto fallback=large.resources((const char*)full.data(),full.size(),sizeof(Key));
 need(fallback->previous.expired()&&fallback->size()==1&&(*fallback)[0]==key(2),"large update failed full-scan fallback");
 puts((std::string("{\"passed\":true,\"GPUWorkSubmitted\":false,\"randomEdits\":6000,\"deltaCases\":")+std::to_string(deltas)+",\"unchangedCases\":"+std::to_string(unchanged)+",\"oracleMismatches\":0,\"weakAncestryChecked\":true}").c_str());return 0;
}catch(const std::exception& e){fprintf(stderr,"%s\n",e.what());return 2;}}}
