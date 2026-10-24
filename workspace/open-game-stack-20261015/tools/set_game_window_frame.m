// Resize only the verified, already-running StellarBlade window.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static BOOL copyBoolSettable(AXUIElementRef element, CFStringRef attribute) {
    Boolean settable = false;
    return AXUIElementIsAttributeSettable(element, attribute, &settable) == kAXErrorSuccess && settable;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if ((argc != 2 && argc != 4) || !AXIsProcessTrusted()) return 2;
        pid_t pid = atoi(argv[1]);
        BOOL apply = argc == 4;
        double requestedWidth = apply ? strtod(argv[2], NULL) : 0;
        double requestedHeight = apply ? strtod(argv[3], NULL) : 0;
        if (pid < 2 || (apply && (requestedWidth < 640 || requestedWidth > 2560 ||
                                 requestedHeight < 360 || requestedHeight > 1600))) return 3;

        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app || app.terminated) return 4;
        AXUIElementRef axApp = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(axApp, 2.0);
        CFTypeRef rawWindows = NULL;
        if (AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, &rawWindows) != kAXErrorSuccess) {
            CFRelease(axApp);
            return 5;
        }

        BOOL found = NO;
        AXError sizeSet = kAXErrorSuccess, positionSet = kAXErrorSuccess;
        CGSize beforeSize = CGSizeZero, afterSize = CGSizeZero;
        CGPoint beforePosition = CGPointZero, afterPosition = CGPointZero;
        BOOL sizeSettable = NO, positionSettable = NO;
        for (id item in (__bridge NSArray *)rawWindows) {
            AXUIElementRef window = (__bridge AXUIElementRef)item;
            CFTypeRef rawTitle = NULL;
            if (AXUIElementCopyAttributeValue(window, kAXTitleAttribute, &rawTitle) != kAXErrorSuccess) continue;
            NSString *title = (__bridge NSString *)rawTitle;
            BOOL named = [title hasPrefix:@"StellarBlade"] || [title hasPrefix:@"SB-Win64-Shipp"];
            CFRelease(rawTitle);
            if (!named) continue;
            found = YES;

            CFTypeRef rawSize = NULL, rawPosition = NULL;
            if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &rawSize) == kAXErrorSuccess) {
                AXValueGetValue((AXValueRef)rawSize, kAXValueCGSizeType, &beforeSize);
                CFRelease(rawSize);
            }
            if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &rawPosition) == kAXErrorSuccess) {
                AXValueGetValue((AXValueRef)rawPosition, kAXValueCGPointType, &beforePosition);
                CFRelease(rawPosition);
            }
            sizeSettable = copyBoolSettable(window, kAXSizeAttribute);
            positionSettable = copyBoolSettable(window, kAXPositionAttribute);

            if (apply) {
                NSScreen *screen = NSScreen.mainScreen;
                NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, requestedWidth, requestedHeight);
                CGSize requestedSize = CGSizeMake(MIN(requestedWidth, visible.size.width),
                                                  MIN(requestedHeight, visible.size.height));
                // Accessibility coordinates use a top-left origin.
                CGPoint requestedPosition = CGPointMake(MAX(0.0, visible.origin.x + (visible.size.width - requestedSize.width) / 2.0),
                                                        MAX(0.0, (visible.size.height - requestedSize.height) / 2.0));
                AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &requestedSize);
                AXValueRef positionValue = AXValueCreate(kAXValueCGPointType, &requestedPosition);
                sizeSet = sizeSettable ? AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue) : kAXErrorAttributeUnsupported;
                positionSet = positionSettable ? AXUIElementSetAttributeValue(window, kAXPositionAttribute, positionValue) : kAXErrorAttributeUnsupported;
                CFRelease(sizeValue);
                CFRelease(positionValue);
                AXUIElementPerformAction(window, kAXRaiseAction);
                [app activateWithOptions:NSApplicationActivateAllWindows];
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
            }

            rawSize = NULL; rawPosition = NULL;
            if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &rawSize) == kAXErrorSuccess) {
                AXValueGetValue((AXValueRef)rawSize, kAXValueCGSizeType, &afterSize);
                CFRelease(rawSize);
            }
            if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &rawPosition) == kAXErrorSuccess) {
                AXValueGetValue((AXValueRef)rawPosition, kAXValueCGPointType, &afterPosition);
                CFRelease(rawPosition);
            }
            break;
        }
        CFRelease(rawWindows);
        CFRelease(axApp);
        if (!found) return 6;
        printf("{\"pid\":%d,\"apply\":%s,\"sizeSettable\":%s,\"positionSettable\":%s,"
               "\"sizeSetError\":%d,\"positionSetError\":%d,"
               "\"before\":{\"x\":%.0f,\"y\":%.0f,\"width\":%.0f,\"height\":%.0f},"
               "\"after\":{\"x\":%.0f,\"y\":%.0f,\"width\":%.0f,\"height\":%.0f}}\n",
               pid, apply ? "true" : "false", sizeSettable ? "true" : "false",
               positionSettable ? "true" : "false", sizeSet, positionSet,
               beforePosition.x, beforePosition.y, beforeSize.width, beforeSize.height,
               afterPosition.x, afterPosition.y, afterSize.width, afterSize.height);
        return apply && (sizeSet != kAXErrorSuccess || positionSet != kAXErrorSuccess) ? 7 : 0;
    }
}
