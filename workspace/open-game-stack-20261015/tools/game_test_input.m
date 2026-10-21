// Scoped, explicit input for the already-running StellarBlade test window.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,const char**argv) {
 @autoreleasepool {
  if(argc!=4 || !AXIsProcessTrusted()) return 2;
  pid_t pid=atoi(argv[1]); int key=atoi(argv[2]), millis=atoi(argv[3]);
  if(pid<2 || key < -3 || key>126 || millis<1 || millis>3000) return 3;
  if(key == -2) {printf("{\"pid\":%d,\"active\":%s}\n",pid,[NSRunningApplication runningApplicationWithProcessIdentifier:pid].active?"true":"false");return 0;}
  // Full-screen windows in another Space can temporarily disappear from AX.
  // Activate only after independently verifying a named CG window owned by PID.
  BOOL knownCG=NO;
  NSArray* cgWindows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
  for(NSDictionary* row in cgWindows) {
   NSString* title=row[(id)kCGWindowName]?:@"";
   if([row[(id)kCGWindowOwnerPID] intValue]==pid && ([title hasPrefix:@"StellarBlade"] || [title hasPrefix:@"SB-Win64-Shipp"])) {knownCG=YES;break;}
  }
  if(!knownCG)return 7;
  [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateAllWindows];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
  AXUIElementRef app=AXUIElementCreateApplication(pid); CFTypeRef raw=NULL;
  AXUIElementSetMessagingTimeout(app,2);
  AXUIElementSetAttributeValue(app,kAXFrontmostAttribute,kCFBooleanTrue);
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
  if(AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&raw)!=kAXErrorSuccess) {CFRelease(app);return 4;}
  BOOL found=NO;
  for(id w in (__bridge NSArray*)raw) {
   CFTypeRef title=NULL;
   if(AXUIElementCopyAttributeValue((__bridge AXUIElementRef)w,kAXTitleAttribute,&title)==kAXErrorSuccess) {
    if(([(__bridge NSString*)title hasPrefix:@"StellarBlade"] || [(__bridge NSString*)title hasPrefix:@"SB-Win64-Shipp"])) {found=YES;AXUIElementSetAttributeValue((__bridge AXUIElementRef)w,kAXMinimizedAttribute,kCFBooleanFalse);AXUIElementPerformAction((__bridge AXUIElementRef)w,kAXRaiseAction);}
    CFRelease(title);
   }
  }
  CFRelease(raw);if(!found){CFRelease(app);return 5;}
  AXError frontError=AXUIElementSetAttributeValue(app,kAXFrontmostAttribute,kCFBooleanTrue);
  CFRelease(app);
  [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateAllWindows];
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.5]];
  BOOL active=[NSRunningApplication runningApplicationWithProcessIdentifier:pid].active;
  fprintf(stderr,"gamePID=%d active=%d frontmostAttributeResult=%d\n",pid,active,frontError);
  if(key == -1) {printf("{\"pid\":%d,\"focused\":%s}\n",pid,active?"true":"false");return active?0:6;}
  if(!active || [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier!=pid)return 6;
  if(key == -3) {
   NSArray* visible=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
   BOOL targetFound=NO;CGPoint point=CGPointZero;
   for(NSDictionary* row in visible) {
    NSString* title=row[(id)kCGWindowName]?:@"";
    if([row[(id)kCGWindowOwnerPID] intValue]!=pid || ![title hasPrefix:@"StellarBlade"])continue;
    CGRect bounds=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&bounds);
    if(bounds.size.width>300 && bounds.size.height>200) {point=CGPointMake(CGRectGetMidX(bounds),CGRectGetMidY(bounds));targetFound=YES;break;}
   }
   if(!targetFound)return 8;
   CGEventRef down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,point,kCGMouseButtonLeft);
   CGEventRef up=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseUp,point,kCGMouseButtonLeft);
   CGEventPostToPid(pid,down);usleep(millis*1000);CGEventPostToPid(pid,up);CFRelease(down);CFRelease(up);
   printf("{\"pid\":%d,\"button\":\"left\",\"holdMS\":%d,\"sent\":true}\n",pid,millis);return 0;
  }
  CGEventRef down=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,true);
  CGEventRef up=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,false);
  CGEventPostToPid(pid,down);usleep(millis*1000);CGEventPostToPid(pid,up);
  CFRelease(down);CFRelease(up);
  printf("{\"pid\":%d,\"keyCode\":%d,\"holdMS\":%d,\"sent\":true}\n",pid,key,millis);
 }
 return 0;
}
