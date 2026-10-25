#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include <thread>
#include <atomic>
#include <unistd.h>
#include <fcntl.h>
#include "MVKStutterNativeTrace.h"
int main(int argc,char**argv){@autoreleasepool{
 if(argc!=2)return 2;setenv("MVK_AMD_STUTTER_COVERAGE","1",1);setenv("MVK_CONFIG_SHADER_DUMP_DIR",argv[1],1);NSString*arm=[NSString stringWithFormat:@"/tmp/mvk-native-graph-%d.arm",getpid()];setenv("MVK_AMD_STUTTER_ARM_PATH",arm.UTF8String,1);unlink(arm.UTF8String);
 auto touch=[&]{int fd=open(arm.UTF8String,O_CREAT|O_WRONLY,0600);futimens(fd,nullptr);close(fd);usleep(120000);};
 id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name containsString:@"5600"]){d=x;break;}if(!d)return 2;auto q0=[d newCommandQueue];auto q1=[d newCommandQueue];auto q2=[d newCommandQueue];auto event=[d newSharedEvent];auto src=[d newBufferWithLength:64 options:MTLResourceStorageModeShared];auto dst=[d newBufferWithLength:64 options:MTLResourceStorageModeShared];memset(src.contents,0,64);memset(dst.contents,0,64);
 auto late=[[q0 commandBuffer]retain];mvkStutterBeginNativeCB(late,0,0);mvkStutterTagNativeCB(late,40,0,900);auto le=[late blitCommandEncoder];[le fillBuffer:dst range:NSMakeRange(0,64) value:0];[le endEncoding];
 touch();auto session1=mvkStutterNativeArm().session;mvkStutterNativePhase(late,"commitRequested");mvkStutterMarkNativeCommit(late);[late commit];[late waitUntilCompleted];mvkStutterNativePhase(late,"completed");
 auto a=[[q1 commandBuffer]retain];mvkStutterBeginNativeCB(a,2,0);mvkStutterTagNativeCB(a,42,1,901);mvkStutterSubmissionPhase(42,2,0,"created",1234);auto ae=[a blitCommandEncoder];[ae fillBuffer:src range:NSMakeRange(0,64) value:0x5a];[ae endEncoding];mvkStutterNativeEvent(a,event,7,"signal-encoded");[a encodeSignalEvent:event value:7];
 touch();auto session2=mvkStutterNativeArm().session;auto b=[[q2 commandBuffer]retain];mvkStutterBeginNativeCB(b,3,1);mvkStutterTagNativeCB(b,43,2,902);mvkStutterNativeEvent(b,event,7,"wait-encoded");[b encodeWaitForEvent:event value:7];auto be=[b blitCommandEncoder];[be copyFromBuffer:src sourceOffset:0 toBuffer:dst destinationOffset:0 size:64];[be endEncoding];
 std::atomic<unsigned> incoherent{0};auto*incoherentPtr=&incoherent;auto done=dispatch_semaphore_create(0);for(id<MTLCommandBuffer> cb:@[a,b]){[cb addScheduledHandler:^(id<MTLCommandBuffer>x){for(unsigned i=0;i<100;++i){auto s=mvkStutterNativeSnapshot(x);if(!s.nativeID)incoherentPtr->fetch_add(1);}mvkStutterNativePhase(x,"scheduled");}];[cb addCompletedHandler:^(id<MTLCommandBuffer>x){mvkStutterNativePhase(x,"completed",x==a?1:2,1,true,false);mvkStutterNativeEvent(x,event,7,"completion-observed",0,event.signaledValue,event.signaledValue>=7);dispatch_semaphore_signal(done);}];}
 mvkStutterNativePhase(a,"commitRequested");mvkStutterMarkNativeCommit(a);[a commit];mvkStutterNativePhase(b,"commitRequested");mvkStutterMarkNativeCommit(b);[b commit];std::thread writer([&]{@autoreleasepool{for(unsigned i=0;i<100;++i){mvkStutterTagNativeCB(a,42,1,901);mvkStutterTagNativeCB(b,43,2,902);}}});writer.join();[a waitUntilCompleted];[b waitUntilCompleted];bool handlers=dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0&&dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0;
 unsigned wrong=0;for(unsigned i=0;i<64;++i)if(((uint8_t*)dst.contents)[i]!=0x5a)++wrong;auto sa=mvkStutterNativeSnapshot(a),sb=mvkStutterNativeSnapshot(b),sl=mvkStutterNativeSnapshot(late);auto writerRows=mvkStutterNativeWriter().sessions.size();
 // This row tests output formatting/correlation only; there is no drawable.
 mvkStutterPresentedFrame(902,(void*)0x1234,0,17,session2);
 mvkStutterPresentedFrame(903,(void*)0x1234,0,18,0,sb.nativeID);
 mvkStutterNativeEvent(nil,event,7,"hostWaitBegin",42,0,false,session1,true);
 mvkStutterNativeEvent(nil,event,7,"hostWaitEnd",42,event.signaledValue,true,session1,true);
 // Inject only the admission counter to exercise the real cap boundary without
 // writing 200,000 redundant test rows. This is a synthetic boundary setup.
 {auto&w=mvkStutterNativeWriter();std::lock_guard<std::mutex>g(w.lock);w.sessions[session2].rows=200000;}
 for(unsigned i=0;i<1024;++i)mvkStutterNativePhase(b,"synthetic-budget-drop");
 NSDictionary*out=@{@"device":d.name,@"GPUValuesChecked":@64,@"GPUValueMismatches":@(wrong),@"metadataIncoherentReads":@(incoherent.load()),@"handlersCompleted":@(handlers),@"oldSession":@(session1),@"newSession":@(session2),@"producerSession":@(sa.session),@"consumerSession":@(sb.session),@"lateSession":@(sl.session),@"latePartialPrefix":@(sl.partialPrefix),@"nativeA":@(sa.nativeID),@"nativeB":@(sb.nativeID),@"producerGPUStart":@(a.GPUStartTime),@"producerGPUEnd":@(a.GPUEndTime),@"consumerGPUStart":@(b.GPUStartTime),@"consumerGPUEnd":@(b.GPUEndTime),@"sessionBudgets":@(writerRows),@"syntheticPresentFormattingOnly":@YES,@"syntheticBudgetBoundaryRowsInjected":@200000,@"logFile":[NSString stringWithFormat:@"%s/stutter-native-%d.jsonl",argv[1],getpid()]};auto json=[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);[a release];[b release];[late release];[event release];[src release];[dst release];[q0 release];[q1 release];[q2 release];dispatch_release(done);unlink(arm.UTF8String);return wrong||incoherent.load()||!handlers||!sl.partialPrefix||session1==session2?1:0;
}}
