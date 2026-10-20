#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    CGDirectDisplayID display = CGMainDisplayID();
    CGError capture = CGDisplayCapture(display);
    printf("captureResult=%d\n", capture);
    if (capture != kCGErrorSuccess) return 2;
    usleep(1200000);
    CGError release = CGDisplayRelease(display);
    printf("releaseResult=%d\n", release);
    return release == kCGErrorSuccess ? 0 : 3;
}
