// Read-only foreground/visibility evidence. Never activates or inputs to apps.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

static BOOL gameTitle(NSString* title) {
    return [title hasPrefix:@"StellarBlade"] || [title hasPrefix:@"SB-Win64-Shipp"];
}

static NSString* windowTitle(NSDictionary* window) {
    id title=window[(id)kCGWindowName];
    return [title isKindOfClass:NSString.class] ? title : @"";
}

static CGRect windowBounds(NSDictionary* window) {
    CGRect bounds=CGRectZero;
    id dictionary=window[(id)kCGWindowBounds];
    if ([dictionary isKindOfClass:NSDictionary.class])
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)dictionary,&bounds);
    if (!isfinite(bounds.origin.x) || !isfinite(bounds.origin.y) ||
        !isfinite(bounds.size.width) || !isfinite(bounds.size.height)) return CGRectZero;
    return bounds;
}

static BOOL windowOwnerAndSize(NSDictionary* window,pid_t pid) {
    if ([window[(id)kCGWindowOwnerPID] intValue]!=pid) return NO;
    CGRect bounds=windowBounds(window);
    return bounds.size.width>300 && bounds.size.height>200;
}

// Pure selection logic also used by the CPU-only synthetic control. An
// OnScreenOnly miss is not evidence that an app or its fullscreen Space closed.
static NSDictionary* classifyGameWindows(NSArray* all,NSArray* onScreen,pid_t pid,CGWindowID knownID) {
    NSDictionary* selected=nil;
    NSDictionary* knownWithoutTitle=nil;
    NSUInteger matchedAll=0,matchedOnScreen=0;
    for (NSDictionary* window in all) {
        if (!windowOwnerAndSize(window,pid)) continue;
        NSString* title=windowTitle(window);
        CGWindowID wid=[window[(id)kCGWindowNumber] unsignedIntValue];
        if (gameTitle(title)) {
            ++matchedAll;
            if (!selected || wid==knownID) selected=window;
        } else if (!title.length && knownID && wid==knownID) {
            // Only a previously PID/title-verified ID may survive a missing
            // title. Never promote a new generic Wine/Steam/error window.
            knownWithoutTitle=window;
        }
    }
    NSDictionary* visibleWindow=nil;
    for (NSDictionary* window in onScreen) {
        if (!windowOwnerAndSize(window,pid) || !gameTitle(windowTitle(window))) continue;
        ++matchedOnScreen;
        if (!visibleWindow || [window[(id)kCGWindowNumber] unsignedIntValue]==knownID)
            visibleWindow=window;
    }
    if (visibleWindow) selected=visibleWindow;
    BOOL strictTitle=selected!=nil;
    if (!selected) selected=knownWithoutTitle;
    BOOL exists=selected!=nil;
    CGRect bounds=exists ? windowBounds(selected) : CGRectZero;
    CGWindowID wid=exists ? [selected[(id)kCGWindowNumber] unsignedIntValue] : 0;
    NSString* reason=visibleWindow ? @"on-screen" :
        exists && !onScreen ? @"on-screen-list-unavailable" :
        exists && !strictTitle ? @"known-window-observed-title-unavailable" :
        exists ? @"offscreen-or-other-space-or-hidden" :
        !all ? @"all-window-list-unavailable" : @"no-matching-game-window-observed";
    return @{@"visible":@(visibleWindow!=nil),
        @"matchedWindowExists":@(exists),@"matchedAllWindowCount":@(matchedAll),
        @"matchedOnScreenWindowCount":@(matchedOnScreen),
        @"allWindowListAvailable":@(all!=nil),@"onScreenWindowListAvailable":@(onScreen!=nil),
        @"visibilityReason":reason,@"windowID":@(wid),
        @"lastKnownWindowID":@(strictTitle ? wid : knownID),
        @"matchBasis":strictTitle ? @"pid-and-title" : exists ? @"pid-and-known-id-title-unavailable" : @"none",
        @"title":exists ? windowTitle(selected) : @"",
        @"cgWindowIsOnscreenFlag":@(exists && [selected[(id)kCGWindowIsOnscreen] boolValue]),
        @"pointX":@(bounds.origin.x),@"pointY":@(bounds.origin.y),
        @"pointWidth":@(bounds.size.width),@"pointHeight":@(bounds.size.height),
        @"boundsSource":exists ? @"current-window-list" : @"unavailable"};
}

int main(int argc,const char** argv) { @autoreleasepool {
    if(argc!=4)return 2;
    pid_t pid=atoi(argv[1]);int seconds=atoi(argv[2]);
    if(pid<2 || seconds<5 || seconds>180)return 3;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    FILE* file=fopen(argv[3],"wx");if(!file)return 4;
    CGWindowID knownID=0;
    for(int i=0;i<seconds;++i) { @autoreleasepool {
        NSRunningApplication* app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSArray* all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
        NSArray* onScreen=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));
        NSMutableDictionary* record=[classifyGameWindows(all,onScreen,pid,knownID) mutableCopy];
        knownID=[record[@"lastKnownWindowID"] unsignedIntValue];
        int previousErrno=errno;
        BOOL processExists=kill(pid,0)==0 || errno==EPERM;
        errno=previousErrno;
        pid_t frontmost=[NSWorkspace sharedWorkspace].frontmostApplication.processIdentifier;
        record[@"time"]=@([NSDate timeIntervalSinceReferenceDate]);
        record[@"pid"]=@(pid);
        record[@"alive"]=@(processExists);
        record[@"aliveSource"]=@"process-existence-check";
        record[@"active"]=@(app.active);
        record[@"frontmostPID"]=@(frontmost);
        record[@"foreground"]=@(frontmost==pid);
        record[@"nativeApplicationStateAvailable"]=@(app!=nil);
        record[@"nativeApplicationState"]=!app ? @"unavailable" : app.terminated ? @"terminated" : @"available";
        NSError* error=nil;
        NSData* data=[NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
        if (!data || fwrite(data.bytes,1,data.length,file)!=data.length || fputc('\n',file)==EOF) {
            fclose(file);return 5;
        }
        fflush(file);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    }}
    fclose(file);return 0;
}}
