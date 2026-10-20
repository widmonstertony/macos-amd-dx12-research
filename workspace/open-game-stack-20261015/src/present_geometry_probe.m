/* Loaded only in our isolated D3D12 probe, never the game or Steam. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>

static void inspect(NSView *view, NSView *root, unsigned depth, unsigned tick) {
    NSRect frame = [view convertRect:view.bounds toView:root];
    if (tick == 50 || tick == 250)
        fprintf(stderr, "native_geometry.view depth=%u class=%s frame=%.1f,%.1f,%.1f,%.1f hidden=%d layer=%s\n",
                depth, object_getClassName(view), frame.origin.x, frame.origin.y,
                frame.size.width, frame.size.height, view.hidden,
                view.layer ? object_getClassName(view.layer) : "none");
    if ([view.layer isKindOfClass:[CAMetalLayer class]] && !view.isHiddenOrHasHiddenAncestor) {
        NSRect bounds = root.bounds;
        BOOL covers = fabs(frame.origin.x - bounds.origin.x) <= 1 && fabs(frame.origin.y - bounds.origin.y) <= 1 &&
                      fabs(frame.size.width - bounds.size.width) <= 1 && fabs(frame.size.height - bounds.size.height) <= 1;
        if (tick >= 200 && tick % 50 == 0)
            fprintf(stderr, "native_geometry.metal_covers_client=%s client=%.1fx%.1f metal=%.1fx%.1f tick=%u\n",
                    covers ? "PASS" : "FAIL", bounds.size.width, bounds.size.height,
                    frame.size.width, frame.size.height, tick);
    }
    for (NSView *child in view.subviews) inspect(child, root, depth + 1, tick);
}

static void tick(unsigned n, unsigned attempts) {
    if (attempts > 2000 || n > 350) return;
    for (NSWindow *window in NSApp.windows) {
        if (![window.title containsString:@"D3D12 Intel presentation probe - stress active"]) continue;
        if (n == 0) {
            NSRect rect = window.frame;
            rect.size = NSMakeSize(800, 620);
            [window setFrame:rect display:YES];
        }
        inspect(window.contentView, window.contentView, 0, n);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ tick(n + 1, attempts + 1); });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ tick(n, attempts + 1); });
}

__attribute__((constructor)) static void begin(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ tick(0, 0); });
}
