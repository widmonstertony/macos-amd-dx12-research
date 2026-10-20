#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <unistd.h>

static long modeDistance(CGDisplayModeRef a, CGDisplayModeRef b) {
    long dw = labs((long)CGDisplayModeGetWidth(a) - (long)CGDisplayModeGetWidth(b));
    long dh = labs((long)CGDisplayModeGetHeight(a) - (long)CGDisplayModeGetHeight(b));
    long dpw = labs((long)CGDisplayModeGetPixelWidth(a) - (long)CGDisplayModeGetPixelWidth(b));
    long dph = labs((long)CGDisplayModeGetPixelHeight(a) - (long)CGDisplayModeGetPixelHeight(b));
    return dw + dh + dpw * 4 + dph * 4;
}

int main(void) {
    @autoreleasepool {
        CGDirectDisplayID display = CGMainDisplayID();
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
        if (!current) return 2;
        NSDictionary *options = @{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES};
        CFArrayRef all = CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options);
        CGDisplayModeRef alternate = NULL;
        long best = LONG_MAX;
        for (CFIndex i = 0; all && i < CFArrayGetCount(all); ++i) {
            CGDisplayModeRef mode = (CGDisplayModeRef)CFArrayGetValueAtIndex(all, i);
            if (CGDisplayModeGetIODisplayModeID(mode) == CGDisplayModeGetIODisplayModeID(current)) continue;
            if (CGDisplayModeGetWidth(mode) < 1024 || CGDisplayModeGetHeight(mode) < 640) continue;
            IOOptionBits flags = CGDisplayModeGetIOFlags(mode);
            if (flags & (kDisplayModeInterlacedFlag | kDisplayModeStretchedFlag)) continue;
            long score = modeDistance(current, mode);
            if (score < best) { best = score; alternate = mode; }
        }
        if (!alternate) { if (all) CFRelease(all); CGDisplayModeRelease(current); return 3; }
        printf("current=%zux%zu pixels=%zux%zu alternate=%zux%zu pixels=%zux%zu\n",
               CGDisplayModeGetWidth(current), CGDisplayModeGetHeight(current),
               CGDisplayModeGetPixelWidth(current), CGDisplayModeGetPixelHeight(current),
               CGDisplayModeGetWidth(alternate), CGDisplayModeGetHeight(alternate),
               CGDisplayModeGetPixelWidth(alternate), CGDisplayModeGetPixelHeight(alternate));
        CGError first = CGDisplaySetDisplayMode(display, alternate, NULL);
        usleep(900000);
        CGError second = CGDisplaySetDisplayMode(display, current, NULL);
        printf("alternateResult=%d restoreResult=%d\n", first, second);
        if (all) CFRelease(all);
        CGDisplayModeRelease(current);
        return (first == kCGErrorSuccess && second == kCGErrorSuccess) ? 0 : 4;
    }
}
