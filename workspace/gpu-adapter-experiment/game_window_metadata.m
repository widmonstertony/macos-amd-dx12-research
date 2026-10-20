#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#include <stdlib.h>
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=2)return 2;pid_t pid=(pid_t)strtol(argv[1],0,10);if(pid<=0)return 3;
 NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
 NSMutableArray *found=[NSMutableArray array];
 for(NSDictionary *w in windows){
  if([w[(id)kCGWindowOwnerPID] intValue]!=pid||[w[(id)kCGWindowLayer] intValue]!=0)continue;
  NSDictionary *b=w[(id)kCGWindowBounds];if([b[@"Width"] doubleValue]<100||[b[@"Height"] doubleValue]<100)continue;
  [found addObject:@{@"id":w[(id)kCGWindowNumber],@"ownerPID":@(pid),@"bounds":b,@"sharingState":w[(id)kCGWindowSharingState]?:@(-1),@"onScreen":w[(id)kCGWindowIsOnscreen]?:@NO,@"alpha":w[(id)kCGWindowAlpha]?:@(-1)}];
 }
 NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
 NSDictionary *out=@{@"scope":@"Exact caller-selected game PID window metadata; no title/body/other-app content",@"screenCaptureAlreadyAllowed":@(CGPreflightScreenCaptureAccess()),@"gameIsMacFrontmost":@([NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier==pid),@"gameRegisteredAsMacApp":@(app!=nil),@"gameActivationPolicy":@(app?app.activationPolicy:-1),@"gameIsActive":@(app.active),@"gameIsHidden":@(app.hidden),@"windows":found};
 NSData *json=[NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];fwrite(json.bytes,1,json.length,stdout);return 0;
}}
