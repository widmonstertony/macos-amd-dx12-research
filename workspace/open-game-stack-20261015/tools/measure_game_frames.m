#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>

typedef CGImageRef (*CreateWindowImageFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

static uint64_t sampleHash(CGImageRef image) {
    CGDataProviderRef provider = CGImageGetDataProvider(image);
    CFDataRef bytes = CGDataProviderCopyData(provider);
    const UInt8 *data = CFDataGetBytePtr(bytes);
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    size_t rowBytes = CGImageGetBytesPerRow(image), pixelBytes = CGImageGetBitsPerPixel(image) / 8;
    uint64_t hash = 1469598103934665603ULL;
    for (size_t y = 0; y < height; y += MAX((size_t)1, height / 72)) {
        for (size_t x = 0; x < width; x += MAX((size_t)1, width / 128)) {
            const UInt8 *pixel = data + y * rowBytes + x * pixelBytes;
            for (size_t b = 0; b < MIN(pixelBytes, (size_t)4); ++b) {
                hash ^= pixel[b];
                hash *= 1099511628211ULL;
            }
        }
    }
    CFRelease(bytes);
    return hash;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if ((argc != 2 && argc != 3) || !CGPreflightScreenCaptureAccess()) return 2;
        pid_t pid = atoi(argv[1]);
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
        CGWindowID selected = kCGNullWindowID;
        for (NSDictionary *row in windows) {
            if ([row[(id)kCGWindowOwnerPID] intValue] != pid) continue;
            NSString *title = row[(id)kCGWindowName] ?: @"";
            NSDictionary *bounds = row[(id)kCGWindowBounds];
            CGRect rect = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &rect);
            if ([title hasPrefix:@"StellarBlade"] && rect.size.width > 300 && rect.size.height > 200) {
                selected = [row[(id)kCGWindowNumber] unsignedIntValue];
                break;
            }
        }
        if (selected == kCGNullWindowID) { fprintf(stderr, "No game window for pid %d\n",pid); return 3; }
        CreateWindowImageFn createWindowImage = (CreateWindowImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        if (!createWindowImage) return 5;
        if (argc == 3) {
            CGImageRef frame = createWindowImage(CGRectNull, kCGWindowListOptionIncludingWindow,
                                                 selected, kCGWindowImageBoundsIgnoreFraming);
            if (!frame) return 6;
            NSBitmapImageRep* bitmap = [[NSBitmapImageRep alloc] initWithCGImage:frame];
            NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            BOOL written = [png writeToFile:@(argv[2]) atomically:YES];
            CGImageRelease(frame);
            if (!written) return 7;
            printf("{\"pid\":%d,\"windowID\":%u,\"snapshot\":\"%s\"}\n",pid,selected,argv[2]);
            return 0;
        }
        const int samples = 100;
        int changes = 0, captured = 0;
        uint64_t previous = 0;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < samples; ++i) {
            @autoreleasepool {
                CGImageRef image = createWindowImage(CGRectNull, kCGWindowListOptionIncludingWindow,
                                                     selected, kCGWindowImageBoundsIgnoreFraming);
                if (image) {
                    uint64_t hash = sampleHash(image);
                    if (captured && hash != previous) ++changes;
                    previous = hash;
                    ++captured;
                    CGImageRelease(image);
                }
            }
            usleep(50000);
        }
        double seconds = CFAbsoluteTimeGetCurrent() - start;
        printf("{\"pid\":%d,\"windowID\":%u,\"seconds\":%.3f,\"captured\":%d,\"changedIntervals\":%d,\"changedIntervalsPerSecond\":%.3f}\n",
               pid, selected, seconds, captured, changes, changes / seconds);
        return captured ? 0 : 4;
    }
}
