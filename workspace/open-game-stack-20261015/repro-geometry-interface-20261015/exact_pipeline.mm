#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=4&&argc!=5)return 2;
 id<MTLDevice>d=nil;for(id<MTLDevice>x in MTLCopyAllDevices())if([x.name isEqualToString:@"AMD Radeon Pro 5600M"])d=x;if(!d)return 3;
 NSMutableArray*held=[NSMutableArray array];const char*preload=getenv("REPRO_PRELOAD_DIR");
 if(preload){unsigned n=0;for(NSString*name in [[[NSFileManager defaultManager]contentsOfDirectoryAtPath:@(preload) error:nil] sortedArrayUsingSelector:@selector(compare:)]){if(![name hasPrefix:@"source-"]||![name hasSuffix:@".metal"])continue;NSString*s=[NSString stringWithContentsOfFile:[@(preload) stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];MTLCompileOptions*o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion4_0;o.mathMode=MTLMathModeSafe;id<MTLLibrary>l=[d newLibraryWithSource:s options:o error:nil];if(l){[held addObject:l];id<MTLFunction>f=[l newFunctionWithName:@"main0"];if(f)[held addObject:f];}if(++n>=(getenv("REPRO_PRELOAD_LIMIT")?strtoul(getenv("REPRO_PRELOAD_LIMIT"),nullptr,10):80))break;}fprintf(stderr,"preloaded %u sources held %lu objects\n",n,(unsigned long)held.count);fflush(stderr);}
 id<MTLFunction>f[3]={nil,nil,nil};NSMutableArray*stages=[NSMutableArray array];
 for(int i=0;i<3;i++){
  NSError*e=nil;NSString*s=[NSString stringWithContentsOfFile:@(argv[i+1]) encoding:NSUTF8StringEncoding error:&e];
  MTLCompileOptions*o=[MTLCompileOptions new];o.languageVersion=MTLLanguageVersion4_0;o.mathMode=MTLMathModeSafe;o.preserveInvariance=i<2;
  const char* mode=getenv("REPRO_MATH_MODE");if(mode){o.mathMode=strcmp(mode,"fast")==0?MTLMathModeFast:MTLMathModeRelaxed;o.mathFloatingPointFunctions=strcmp(mode,"fast")==0?MTLMathFloatingPointFunctionsFast:MTLMathFloatingPointFunctionsPrecise;}
  if(getenv("REPRO_NO_INVARIANCE"))o.preserveInvariance=NO;
  __block id<MTLLibrary>l=nil;
  if(s&&getenv("REPRO_ASYNC")){dispatch_semaphore_t wait=dispatch_semaphore_create(0);[d newLibraryWithSource:s options:o completionHandler:^(id<MTLLibrary>lib,NSError*err){l=lib;dispatch_semaphore_signal(wait);}];dispatch_semaphore_wait(wait,DISPATCH_TIME_FOREVER);}else if(s)l=[d newLibraryWithSource:s options:o error:&e];
  f[i]=[l newFunctionWithName:@"main0"];
  [stages addObject:@{@"stage":@(i),@"libraryCreated":@(l!=nil),@"functionCreated":@(f[i]!=nil),@"error":e.localizedDescription?:@""}];
  fprintf(stderr,"stage %d library=%d function=%d\n",i,l!=nil,f[i]!=nil);fflush(stderr);
  if(!f[i]){NSData*j=[NSJSONSerialization dataWithJSONObject:stages options:NSJSONWritingPrettyPrinted error:nil];fwrite(j.bytes,1,j.length,stdout);return 4;}
 }
 bool depth16=argc==5;NSError*e=nil;MTLMeshRenderPipelineDescriptor*pd=[MTLMeshRenderPipelineDescriptor new];pd.objectFunction=f[0];pd.meshFunction=f[1];pd.fragmentFunction=f[2];pd.rasterSampleCount=1;pd.depthAttachmentPixelFormat=depth16?MTLPixelFormatDepth16Unorm:MTLPixelFormatDepth32Float;pd.maxTotalThreadsPerObjectThreadgroup=1;pd.maxTotalThreadsPerMeshThreadgroup=1;
 if(getenv("REPRO_DEFAULT_THREADS")){pd.maxTotalThreadsPerObjectThreadgroup=0;pd.maxTotalThreadsPerMeshThreadgroup=0;}
 if(getenv("REPRO_CONCURRENT")){NSMutableArray*results=[NSMutableArray array];dispatch_group_t group=dispatch_group_create();for(unsigned i=0;i<16;i++){dispatch_group_enter(group);dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{@autoreleasepool{NSError*err=nil;MTLMeshRenderPipelineDescriptor*copy=[pd copy];id<MTLRenderPipelineState>state=[d newRenderPipelineStateWithMeshDescriptor:copy options:MTLPipelineOptionNone reflection:nil error:&err];@synchronized(results){[results addObject:@{@"created":@(state!=nil),@"error":err.localizedDescription?:@""}];}dispatch_group_leave(group);}});}dispatch_group_wait(group,DISPATCH_TIME_FOREVER);NSData*j=[NSJSONSerialization dataWithJSONObject:results options:NSJSONWritingPrettyPrinted error:nil];fwrite(j.bytes,1,j.length,stdout);puts("");for(NSDictionary*r in results)if(![r[@"created"]boolValue])return 6;return 0;}
 __block id<MTLRenderPipelineState>ps=nil;__block NSError*asyncError=nil;
 if(getenv("REPRO_ASYNC")){dispatch_semaphore_t wait=dispatch_semaphore_create(0);[d newRenderPipelineStateWithMeshDescriptor:pd options:MTLPipelineOptionNone completionHandler:^(id<MTLRenderPipelineState>state,MTLRenderPipelineReflection*reflection,NSError*error){ps=state;asyncError=error;dispatch_semaphore_signal(wait);}];dispatch_semaphore_wait(wait,DISPATCH_TIME_FOREVER);e=asyncError;}else ps=[d newRenderPipelineStateWithMeshDescriptor:pd options:MTLPipelineOptionNone reflection:nil error:&e];
 NSDictionary*r=@{@"device":d.name,@"stages":stages,@"pipelineCreated":@(ps!=nil),@"errorCode":@(e.code),@"error":e.localizedDescription?:@"",@"GPUCommandsSubmitted":@NO,@"depthFormat":depth16?@"Depth16Unorm":@"Depth32Float",@"colorAttachments":@0};
 NSData*j=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingPrettyPrinted error:nil];fwrite(j.bytes,1,j.length,stdout);puts("");return ps?0:5;
}}
