#import <Foundation/Foundation.h>
#define MVKEncodedWorkEvent BaselineEncodedWorkEvent
#define MVKEncodedWorkRing BaselineEncodedWorkRing
#define mvkEncodedWorkSlot baselineWorkSlot
#define mvkNewEncodedWorkRing baselineNewRing
#define mvkAppendEncodedWork baselineAppendWork
#define mvkSnapshotEncodedWork baselineSnapshotWork
#include "controls/encoded_work_ring_full_allocation.h"
#undef MVKEncodedWorkEvent
#undef MVKEncodedWorkRing
#undef mvkEncodedWorkSlot
#undef mvkNewEncodedWorkRing
#undef mvkAppendEncodedWork
#undef mvkSnapshotEncodedWork
#include "MVKEncodedWorkRing.h"
#include <thread>
#include <atomic>
#include <chrono>
#include <stdexcept>
static void need(bool b,const char*m){if(!b)throw std::runtime_error(m);}
static void verify(NSDictionary*s,uint64_t count){
 need([s[@"workCount"]unsignedLongLongValue]==count,"count mismatch");NSArray*es=s[@"workEvents"];
 need(es.count==std::min<uint64_t>(count,1024),"retained size mismatch");
 for(size_t i=0;i<es.count;++i){uint64_t expected=i<64||count<=1024?i:count-960+i-64;need([es[i][@"index"]unsignedLongLongValue]==expected,"retention index mismatch");}
}
static NSString* foundationLabel(void*ptr){return [NSString stringWithFormat:@"mode=%@;pipeline=%@;elements=%u;instances=%u;buffers=%u;textures=%u;samplers=%u;sets=%u;vertexBuffers=%u;vertexBytes=%llu;index=%p;indexOffset=%llu;indexSize=%llu",@"indexed",@"known-pipeline",333u,7u,4u,8u,2u,3u,5u,123456789ull,ptr,42ull,9000ull];}
static void rawLabel(char*text,size_t cap,void*ptr){snprintf(text,cap,"mode=%s;pipeline=%s;elements=%u;instances=%u;buffers=%u;textures=%u;samplers=%u;sets=%u;vertexBuffers=%u;vertexBytes=%llu;index=%p;indexOffset=%llu;indexSize=%llu","indexed","known-pipeline",333u,7u,4u,8u,2u,3u,5u,123456789ull,ptr,42ull,9000ull);}
int main(){@autoreleasepool{try{
 unsigned cases=0;
 for(uint64_t count:{0ull,1ull,16ull,17ull,64ull,65ull,115ull,1024ull,1025ull,10000ull}){@autoreleasepool{
  auto data=mvkNewEncodedWorkRing();auto*ring=(MVKEncodedWorkRing*)data.mutableBytes;
  for(uint64_t i=0;i<count;++i)mvkAppendEncodedWorkBytes(data,(void*)0x1234,"pipeline","known-shader");
  verify(mvkSnapshotEncodedWork(data),count);need((ring->overflow!=nullptr)==(count>64),"overflow allocation threshold mismatch");++cases;
 }}
 auto data=mvkNewEncodedWorkRing();std::atomic<bool>done{false};
 std::thread writer([&]{@autoreleasepool{for(int i=0;i<100000;++i)mvkAppendEncodedWorkBytes(data,(void*)0x5678,"draw","known-shader");done=true;}});
 unsigned snapshots=0;while(!done){@autoreleasepool{auto s=mvkSnapshotEncodedWork(data);verify(s,[s[@"workCount"]unsignedLongLongValue]);++snapshots;}}
 writer.join();verify(mvkSnapshotEncodedWork(data),100000);
 for(void*ptr:{(void*)nullptr,(void*)0x1234}){char text[512];rawLabel(text,sizeof(text),ptr);need(!strcmp(text,foundationLabel(ptr).UTF8String),"draw format mismatch");}
 auto measureAlloc=[&](bool old){auto start=std::chrono::steady_clock::now();for(unsigned i=0;i<10000;++i){@autoreleasepool{auto x=old?baselineNewRing():mvkNewEncodedWorkRing();if(old)baselineAppendWork(x,(void*)0x1234,@"draw",@"known-shader");else mvkAppendEncodedWorkBytes(x,(void*)0x1234,"draw","known-shader");}}return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();};
 double oldAlloc=measureAlloc(true),newAlloc=measureAlloc(false);
 auto oldData=baselineNewRing();auto start=std::chrono::steady_clock::now();
 for(unsigned i=0;i<100000;++i){@autoreleasepool{baselineAppendWork(oldData,(void*)0x1234,@"draw",foundationLabel((void*)0x1234));}}
 double oldFormat=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
 start=std::chrono::steady_clock::now();for(unsigned i=0;i<100000;++i){char text[512];rawLabel(text,sizeof(text),(void*)0x1234);mvkAppendEncodedWorkBytes(data,(void*)0x1234,"draw",text);}
 double newFormat=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
 printf("{\"passed\":true,\"retentionCases\":%u,\"concurrentSnapshots\":%u,\"concurrentWrites\":100000,\"eventCapacity\":1024,\"initialEvents\":64,\"overflowAllocatedOnlyAfter64\":true,\"drawLabelsByteIdentical\":true,\"oldInitialBytes\":%zu,\"newInitialBytes\":%zu,\"oldAllocationMS\":%.3f,\"newAllocationMS\":%.3f,\"oldFormattedDrawMS\":%.3f,\"newFormattedDrawMS\":%.3f,\"gameFPSNotMeasured\":true}\n",cases,snapshots,sizeof(BaselineEncodedWorkRing),sizeof(MVKEncodedWorkRing),oldAlloc,newAlloc,oldFormat,newFormat);
 return 0;
 }catch(const std::exception&e){fprintf(stderr,"%s\n",e.what());return 2;}}}
