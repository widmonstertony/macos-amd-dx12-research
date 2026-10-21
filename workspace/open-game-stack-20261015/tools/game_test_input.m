// Scoped, explicit input for the already-running StellarBlade test window.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,const char**argv) {
 @autoreleasepool {
  if((argc!=4 && argc!=6) || !AXIsProcessTrusted()) return 2;
  pid_t pid=atoi(argv[1]); int key=atoi(argv[2]), millis=atoi(argv[3]);
  if(pid<2 || key < -5 || key>126 || millis<1 || millis>3000) return 3;
  double relativeX=.5, relativeY=.5;
  if(argc==6) {
   if(key!=-4 && key!=-5)return 3;
   char *endX=NULL,*endY=NULL;
   relativeX=strtod(argv[4],&endX);relativeY=strtod(argv[5],&endY);
   if(!endX || *endX || !endY || *endY || !isfinite(relativeX) || !isfinite(relativeY) ||
      relativeX<.02 || relativeX>.98 || relativeY<.15 || relativeY>.98)return 3;
  }
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
  if(key == -3 || key == -4 || key == -5) {
   BOOL hid=key!=-3, right=key==-5;
   NSArray* visible=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
   BOOL targetFound=NO;CGPoint point=CGPointZero;NSNumber* targetWindow=nil;
   for(NSDictionary* row in visible) {
    NSString* title=row[(id)kCGWindowName]?:@"";
    if([row[(id)kCGWindowOwnerPID] intValue]!=pid || ![title hasPrefix:@"StellarBlade"])continue;
    CGRect bounds=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&bounds);
    if(bounds.size.width>300 && bounds.size.height>200) {point=CGPointMake(bounds.origin.x+bounds.size.width*relativeX,bounds.origin.y+bounds.size.height*relativeY);targetWindow=row[(id)kCGWindowNumber];targetFound=YES;break;}
   }
   if(!targetFound)return 8;
   if(hid) {
    NSDictionary* hit=nil;
    for(NSDictionary* row in visible) {
     if([row[(id)kCGWindowAlpha] doubleValue]<.01)continue;
     CGRect bounds=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&bounds);
     if(CGRectContainsPoint(bounds,point)){hit=row;break;}
    }
    if(!hit||![hit[(id)kCGWindowNumber] isEqual:targetWindow]) {
     // CG ordering includes click-through Dock overlays. Ask the accessibility
     // hit-test for the actual input recipient before rejecting or clicking.
     AXUIElementRef system=AXUIElementCreateSystemWide(),recipient=NULL;
     AXError hitError=AXUIElementCopyElementAtPosition(system,point.x,point.y,&recipient);
     pid_t recipientPID=0;
     if(recipient)AXUIElementGetPid(recipient,&recipientPID);
     if(recipient)CFRelease(recipient);CFRelease(system);
     fprintf(stderr,"CGOverlay targetWindow=%u hitWindow=%u hitPID=%d hitLayer=%d\n",
       targetWindow.unsignedIntValue,[hit[(id)kCGWindowNumber] unsignedIntValue],
       [hit[(id)kCGWindowOwnerPID] intValue],[hit[(id)kCGWindowLayer] intValue]);
     fprintf(stderr,"accessibilityHitPID=%d hitError=%d\n",recipientPID,hitError);
     if(hitError!=kAXErrorSuccess||recipientPID!=pid)return 9;
    }
   }
   if(argc==6 && hid) {
    CGEventRef move=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,point,kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap,move);CFRelease(move);usleep(50000);
    if([NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier!=pid)return 6;
   }
   CGEventRef down=CGEventCreateMouseEvent(NULL,right?kCGEventRightMouseDown:kCGEventLeftMouseDown,point,right?kCGMouseButtonRight:kCGMouseButtonLeft);
   CGEventRef up=CGEventCreateMouseEvent(NULL,right?kCGEventRightMouseUp:kCGEventLeftMouseUp,point,right?kCGMouseButtonRight:kCGMouseButtonLeft);
   if(hid)CGEventPost(kCGHIDEventTap,down);else CGEventPostToPid(pid,down);
   usleep(millis*1000);
   if(hid && [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier==pid)CGEventPost(kCGHIDEventTap,up);else CGEventPostToPid(pid,up);
   CFRelease(down);CFRelease(up);
   printf("{\"pid\":%d,\"button\":\"%s\",\"holdMS\":%d,\"HIDHitVerified\":%s,\"sent\":true}\n",pid,right?"right":"left",millis,hid?"true":"false");return 0;
  }
  CGEventRef down=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,true);
  CGEventRef up=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,false);
  CGEventPostToPid(pid,down);usleep(millis*1000);CGEventPostToPid(pid,up);
  CFRelease(down);CFRelease(up);
  printf("{\"pid\":%d,\"keyCode\":%d,\"holdMS\":%d,\"sent\":true}\n",pid,key,millis);
 }
 return 0;
}
