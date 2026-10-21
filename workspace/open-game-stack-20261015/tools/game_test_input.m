// Scoped, explicit input for the already-running StellarBlade test window.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,const char**argv) {
 @autoreleasepool {
  if(argc!=4 || !AXIsProcessTrusted()) return 2;
  pid_t pid=atoi(argv[1]); int key=atoi(argv[2]), millis=atoi(argv[3]);
  if(pid<2 || key < -2 || key>126 || millis<1 || millis>3000) return 3;
  if(key == -2) {printf("{\"pid\":%d,\"active\":%s}\n",pid,[NSRunningApplication runningApplicationWithProcessIdentifier:pid].active?"true":"false");return 0;}
  AXUIElementRef app=AXUIElementCreateApplication(pid); CFTypeRef raw=NULL;
  AXUIElementSetMessagingTimeout(app,2);
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
  CGEventRef down=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,true);
  CGEventRef up=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,false);
  CGEventPostToPid(pid,down);usleep(millis*1000);CGEventPostToPid(pid,up);
  CFRelease(down);CFRelease(up);
  printf("{\"pid\":%d,\"keyCode\":%d,\"holdMS\":%d,\"sent\":true}\n",pid,key,millis);
 }
 return 0;
}
