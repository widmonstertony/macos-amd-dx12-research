// Only loaded into our isolated presentation probe. Exercise public Cocoa
// window geometry notifications alongside the unmodified Wine Vulkan path.
#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#include <stdio.h>

static void resize_tick(unsigned iteration, unsigned attempts) {
    if (attempts > 2000) return;
    if (iteration >= 450) {
        fprintf(stderr, "native_resize.completed=450\n");
        return;
    }
    for (NSWindow *window in NSApp.windows) {
        if (![window.title containsString:@"D3D12 Intel presentation probe - stress active"]) continue;
        NSRect frame = window.frame;
        frame.size = NSMakeSize(300 + (iteration % 2) * 32,
                                310 + (iteration % 3) * 16);
        frame.origin.x = 160 + (iteration % 2) * 5;
        [window setFrame:frame display:YES];
        if (iteration % 100 == 0)
            fprintf(stderr, "native_resize.iteration=%u\n", iteration);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ resize_tick(iteration + 1, attempts + 1); });
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ resize_tick(iteration, attempts + 1); });
}

__attribute__((constructor)) static void start_resize_probe(void) {
    fprintf(stderr, "native_resize.test_retain=%s test_blocking=%s\n",
            getenv("WINE_MACDRV_TEST_RETAIN_FRAME_LOCK") ?: "unset",
            getenv("WINE_MACDRV_TEST_BLOCKING_SURFACES") ?: "unset");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ resize_tick(0, 0); });
}
