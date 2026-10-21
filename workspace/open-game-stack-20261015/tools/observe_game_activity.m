// Read-only foreground/visibility evidence. Never activates or inputs to apps.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>
int main(int argc,const char** argv) { @autoreleasepool {
    if(argc!=4)return 2;
    pid_t pid=atoi(argv[1]);int seconds=atoi(argv[2]);
    if(pid<2 || seconds<5 || seconds>180)return 3;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    FILE* file=fopen(argv[3],"wx");if(!file)return 4;
    for(int i=0;i<seconds;++i) { @autoreleasepool {
        NSRunningApplication* app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        BOOL visible=NO;CGRect frame=CGRectZero;CGWindowID wid=0;
        NSArray* windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
        for(NSDictionary* w in windows) {
            if([w[(id)kCGWindowOwnerPID] intValue]!=pid)continue;
            NSString* title=w[(id)kCGWindowName]?:@"";
            if(![title hasPrefix:@"StellarBlade"] && ![title hasPrefix:@"SB-Win64-Shipp"])continue;
            CGRect rect=CGRectZero;CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds],&rect);
            if(rect.size.width>300 && rect.size.height>200) {visible=YES;frame=rect;wid=[w[(id)kCGWindowNumber] unsignedIntValue];break;}
        }
        fprintf(file,"{\"time\":%.6f,\"pid\":%d,\"alive\":%s,\"active\":%s,\"frontmostPID\":%d,\"visible\":%s,\"windowID\":%u,\"pointWidth\":%.0f,\"pointHeight\":%.0f}\n",
            [NSDate timeIntervalSinceReferenceDate],pid,app && !app.terminated?"true":"false",app.active?"true":"false",
            [NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier,visible?"true":"false",wid,frame.size.width,frame.size.height);
        fflush(file);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    }}
    fclose(file);return 0;
}}
