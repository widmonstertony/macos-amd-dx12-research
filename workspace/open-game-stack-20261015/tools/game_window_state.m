#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
int main(int argc,const char**argv){@autoreleasepool{
 if(argc!=2)return 2;pid_t pid=atoi(argv[1]);NSRunningApplication*app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
 NSMutableArray*axRows=[NSMutableArray array];AXError axResult=kAXErrorFailure;
 AXUIElementRef axApp=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(axApp,1.0);CFTypeRef axWindows=NULL;
 axResult=AXUIElementCopyAttributeValue(axApp,kAXWindowsAttribute,&axWindows);
 if(axWindows){for(id w in (__bridge NSArray*)axWindows){CFTypeRef title=NULL;AXError err=AXUIElementCopyAttributeValue((__bridge AXUIElementRef)w,kAXTitleAttribute,&title);[axRows addObject:@{@"titleError":@(err),@"title":title?[(__bridge id)title description]:@""}];if(title)CFRelease(title);}CFRelease(axWindows);}CFRelease(axApp);
 NSMutableArray*rows=[NSMutableArray array];NSArray*all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
 for(NSDictionary*r in all)if([r[(id)kCGWindowOwnerPID] intValue]==pid)[rows addObject:@{@"windowID":r[(id)kCGWindowNumber]?:@0,@"title":r[(id)kCGWindowName]?:@"",@"bounds":r[(id)kCGWindowBounds]?:@{},@"onscreen":r[(id)kCGWindowIsOnscreen]?:@NO,@"layer":r[(id)kCGWindowLayer]?:@0}];
 NSData*d=[NSJSONSerialization dataWithJSONObject:@{@"pid":@(pid),@"active":@(app.active),@"hidden":@(app.hidden),@"terminated":@(app.terminated),@"AXTrusted":@(AXIsProcessTrusted()),@"AXWindowsResult":@(axResult),@"AXWindows":axRows,@"activationPolicy":@(app.activationPolicy),@"appKnown":@(app!=nil),@"bundleIdentifier":app.bundleIdentifier?:@"",@"windows":rows} options:NSJSONWritingPrettyPrinted error:nil];fwrite(d.bytes,1,d.length,stdout);puts("");
}}
