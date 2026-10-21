#import <Foundation/Foundation.h>
#include "MVKEncodedWorkRing.h"
#include <thread>
#include <atomic>
#include <chrono>
#include <cassert>
int main(){@autoreleasepool{
 for(uint64_t count: {0ull,1ull,16ull,17ull,64ull,65ull,115ull,10000ull}) {
  NSMutableData* data=mvkNewEncodedWorkRing();
  for(uint64_t i=0;i<count;i++)mvkAppendEncodedWork(data,(void*)0x1234,@"pipeline",@"known-shader");
  NSDictionary* snapshot=mvkSnapshotEncodedWork(data);assert([snapshot[@"workCount"] unsignedLongLongValue]==count);NSArray*events=snapshot[@"workEvents"];assert(events.count==std::min<uint64_t>(count,64));
  for(size_t i=0;i<events.count;i++){uint64_t wanted=i<16||count<=64?i:count-48+i-16;assert([events[i][@"index"] unsignedLongLongValue]==wanted);assert([events[i][@"label"] isEqual:@"known-shader"]);}
 }
 NSMutableData* data=mvkNewEncodedWorkRing();std::atomic<bool> finished{false};
 std::thread writer([&]{@autoreleasepool{for(int i=0;i<100000;i++)mvkAppendEncodedWork(data,(void*)0x5678,@"fence-wait",@"fence=123 stage=2");finished=true;}});
 unsigned snapshots=0;while(!finished){@autoreleasepool{NSDictionary*s=mvkSnapshotEncodedWork(data);assert([s[@"workEvents"] count]<=64);++snapshots;}}
 writer.join();assert([mvkSnapshotEncodedWork(data)[@"workCount"] unsignedLongLongValue]==100000);
 auto t=std::chrono::steady_clock::now();for(int i=0;i<100000;i++)mvkAppendEncodedWork(data,(void*)0x5678,@"pipeline",@"known-shader");double ring=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();
 NSMutableArray* old=[NSMutableArray array];t=std::chrono::steady_clock::now();
 for(unsigned i=0;i<100000;i++){@autoreleasepool{if(old.count>=64)[old removeObjectAtIndex:16];[old addObject:@{@"index":@(i),@"kind":@"pipeline",@"label":@"known-shader",@"encoder":[NSString stringWithFormat:@"%p",(void*)0x5678],@"time":@([NSDate timeIntervalSinceReferenceDate])}];}}
 double previous=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t).count();
 printf("{\"passed\":true,\"retentionCases\":8,\"concurrentSnapshots\":%u,\"concurrentWrites\":100000,\"eventCapacity\":64,\"ringBytes\":%zu,\"ringMilliseconds\":%.3f,\"previousAllocationMilliseconds\":%.3f,\"gameFPSNotMeasured\":true}\n",snapshots,sizeof(MVKEncodedWorkRing),ring,previous);
}}
