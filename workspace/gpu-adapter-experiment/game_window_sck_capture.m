#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <unistd.h>
int main(int argc,const char**argv){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 if(argc!=4||!CGPreflightScreenCaptureAccess()){fprintf(stderr,"Existing screen permission absent; no capture/request\n");return 2;}
 pid_t pid=atoi(argv[1]);CGWindowID wid=(CGWindowID)strtoul(argv[2],NULL,10);NSString *path=@(argv[3]);
 if(![path hasPrefix:@"/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/yyb-game-window-"]||![path hasSuffix:@".png"])return 3;
 dispatch_semaphore_t done=dispatch_semaphore_create(0);__block int result=4;
 [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent*c,NSError*error){
  if(error){fprintf(stderr,"Shareable metadata error code=%ld\n",(long)error.code);dispatch_semaphore_signal(done);return;}
  SCWindow *target=nil;NSUInteger matches=0;for(SCWindow*w in c.windows)if(w.windowID==wid&&w.owningApplication.processID==pid&&w.windowLayer==0){target=w;++matches;}
  if(matches!=1||target.frame.size.width<100||target.frame.size.height<100){fprintf(stderr,"Exact game window missing; no capture\n");dispatch_semaphore_signal(done);return;}
  SCContentFilter *filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:target];SCStreamConfiguration *cfg=[SCStreamConfiguration new];cfg.width=(size_t)(target.frame.size.width*2);cfg.height=(size_t)(target.frame.size.height*2);cfg.showsCursor=NO;cfg.captureResolution=SCCaptureResolutionBest;
  [SCScreenshotManager captureImageWithFilter:filter configuration:cfg completionHandler:^(CGImageRef image,NSError*failure){
   if(failure||!image){fprintf(stderr,"Game-only image error code=%ld\n",(long)failure.code);dispatch_semaphore_signal(done);return;}
   CGImageDestinationRef dst=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],(__bridge CFStringRef)UTTypePNG.identifier,1,NULL);
   if(dst){CGImageDestinationAddImage(dst,image,NULL);if(CGImageDestinationFinalize(dst)){result=0;printf("Captured only verified game pid=%d window=%u\n",pid,wid);}CFRelease(dst);}dispatch_semaphore_signal(done);
  }];
 }];
 if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC))){fprintf(stderr,"Game-only capture timeout\n");return 5;}return result;
}}
