#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc,const char**argv){@autoreleasepool{
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 if(argc!=4||!CGPreflightScreenCaptureAccess())return 2;pid_t pid=atoi(argv[1]);CGWindowID wid=(CGWindowID)strtoul(argv[2],0,10);NSString*path=@(argv[3]);
 dispatch_semaphore_t done=dispatch_semaphore_create(0);__block int result=3;
 [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent*content,NSError*error){
  if(error){fprintf(stderr,"shareableContentError=%s\n",error.localizedDescription.UTF8String);dispatch_semaphore_signal(done);return;}
  SCWindow*target=nil;for(SCWindow*w in content.windows)if(w.windowID==wid&&w.owningApplication.processID==pid){target=w;break;}
  if(!target){fprintf(stderr,"Target game window absent in ScreenCaptureKit\n");dispatch_semaphore_signal(done);return;}
  SCContentFilter*filter=[[SCContentFilter alloc]initWithDesktopIndependentWindow:target];SCStreamConfiguration*config=[SCStreamConfiguration new];config.width=(size_t)target.frame.size.width*2;config.height=(size_t)target.frame.size.height*2;config.showsCursor=NO;
  [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef image,NSError*captureError){
   if(captureError||!image){fprintf(stderr,"captureError=%s\n",captureError.localizedDescription.UTF8String);dispatch_semaphore_signal(done);return;}
   NSBitmapImageRep*bitmap=[[NSBitmapImageRep alloc]initWithCGImage:image];NSData*png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];result=[png writeToFile:path atomically:YES]?0:4;printf("{\"pid\":%d,\"windowID\":%u,\"modernCapture\":true,\"saved\":%s}\n",pid,wid,result?"false":"true");dispatch_semaphore_signal(done);
  }];
 }];
 NSDate*limit=[NSDate dateWithTimeIntervalSinceNow:15];while(dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)!=0){if(limit.timeIntervalSinceNow<0)return 5;[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.05]];}return result;
}}
