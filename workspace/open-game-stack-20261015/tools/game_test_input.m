// Scoped, explicit input for the already-running StellarBlade test window.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,const char**argv) {
 @autoreleasepool {
  if(argc!=4 || !AXIsProcessTrusted()) return 2;
  pid_t pid=atoi(argv[1]); int key=atoi(argv[2]), millis=atoi(argv[3]);
  if(pid<2 || key < -1 || key>126 || millis<1 || millis>3000) return 3;
  AXUIElementRef app=AXUIElementCreateApplication(pid); CFTypeRef raw=NULL;
  AXUIElementSetMessagingTimeout(app,2);
  if(AXUIElementCopyAttributeValue(app,kAXWindowsAttribute,&raw)!=kAXErrorSuccess) {CFRelease(app);return 4;}
  BOOL found=NO;
  for(id w in (__bridge NSArray*)raw) {
   CFTypeRef title=NULL;
   if(AXUIElementCopyAttributeValue((__bridge AXUIElementRef)w,kAXTitleAttribute,&title)==kAXErrorSuccess) {
    if([(__bridge NSString*)title hasPrefix:@"StellarBlade"]) {found=YES;AXUIElementPerformAction((__bridge AXUIElementRef)w,kAXRaiseAction);}
    CFRelease(title);
   }
  }
  CFRelease(raw);CFRelease(app);if(!found)return 5;
  [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:NSApplicationActivateIgnoringOtherApps];
  usleep(300000);
  if(key == -1) {printf("{\"pid\":%d,\"focused\":true}\n",pid);return 0;}
  CGEventRef down=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,true);
  CGEventRef up=CGEventCreateKeyboardEvent(NULL,(CGKeyCode)key,false);
  CGEventPostToPid(pid,down);usleep(millis*1000);CGEventPostToPid(pid,up);
  CFRelease(down);CFRelease(up);
  printf("{\"pid\":%d,\"keyCode\":%d,\"holdMS\":%d,\"sent\":true}\n",pid,key,millis);
 }
 return 0;
}
