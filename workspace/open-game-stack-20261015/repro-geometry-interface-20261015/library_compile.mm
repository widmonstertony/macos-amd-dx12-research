#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
int main(int argc,const char**argv) { @autoreleasepool {
 if(argc!=3)return 2;id<MTLDevice> device=nil;
 for(id<MTLDevice> d in MTLCopyAllDevices())if([d.name isEqualToString:@"AMD Radeon Pro 5600M"])device=d;
 if(!device)return 3;NSError* error=nil;NSString* source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
 MTLCompileOptions* options=[MTLCompileOptions new];options.languageVersion=MTLLanguageVersion4_0;
 bool fast=strcmp(argv[2],"fast")==0;options.mathMode=fast?MTLMathModeFast:MTLMathModeSafe;
 options.mathFloatingPointFunctions=fast?MTLMathFloatingPointFunctionsFast:MTLMathFloatingPointFunctionsPrecise;
 id<MTLLibrary> library=source?[device newLibraryWithSource:source options:options error:&error]:nil;
 NSDictionary* result=@{@"libraryCreated":@(library!=nil),@"error":error.localizedDescription?:@"",@"device":device.name,@"math":fast?@"fast":@"safe",@"entryPoints":library.functionNames?:@[],@"GPUCommandsSubmitted":@NO};
 NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);puts("");return library?0:5;
}}
