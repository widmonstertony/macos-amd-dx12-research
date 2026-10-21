// Activate only an exposed title bar belonging to the verified game process.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,const char**argv){@autoreleasepool{
 BOOL thumbnail=argc==3&&!strcmp(argv[2],"--allow-thumbnail");
 if((argc!=2&&!thumbnail)||!AXIsProcessTrusted())return 2;pid_t pid=atoi(argv[1]);
 NSArray*rows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
 NSDictionary*target=nil;CGRect bounds=CGRectZero;
 for(NSDictionary*r in rows){if([r[(id)kCGWindowOwnerPID] intValue]!=pid)continue;NSString*t=r[(id)kCGWindowName]?:@"";if(![t hasPrefix:@"StellarBlade"])continue;CGRect b;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r[(id)kCGWindowBounds],&b);if(b.size.width>(thumbnail?60:250)&&b.size.height>(thumbnail?60:150)){target=r;bounds=b;break;}}
 if(!target){fprintf(stderr,"No visible verified game window\n");return 3;}
 CGPoint point=CGPointMake(CGRectGetMidX(bounds),bounds.origin.y+12);
 NSDictionary*hit=nil;
 for(NSDictionary*r in rows){if([r[(id)kCGWindowAlpha] doubleValue]<.01)continue;CGRect b;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)r[(id)kCGWindowBounds],&b);if(CGRectContainsPoint(b,point)){hit=r;break;}}
 if(!hit||![hit[(id)kCGWindowNumber] isEqual:target[(id)kCGWindowNumber]]){printf("{\"clicked\":false,\"reason\":\"game title bar covered\",\"coverPID\":%d}\n",[hit[(id)kCGWindowOwnerPID] intValue]);return 4;}
 CGEventRef down=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseDown,point,kCGMouseButtonLeft);CGEventRef up=CGEventCreateMouseEvent(NULL,kCGEventLeftMouseUp,point,kCGMouseButtonLeft);CGEventPost(kCGHIDEventTap,down);usleep(60000);CGEventPost(kCGHIDEventTap,up);CFRelease(down);CFRelease(up);
 [[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
 printf("{\"clicked\":true,\"pid\":%d,\"windowID\":%u,\"active\":%s}\n",pid,[target[(id)kCGWindowNumber] unsignedIntValue],[NSRunningApplication runningApplicationWithProcessIdentifier:pid].active?"true":"false");return 0;
}}
