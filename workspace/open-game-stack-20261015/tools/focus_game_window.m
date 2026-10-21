#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

static id copyAttribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || !AXIsProcessTrusted()) return 2;
        pid_t pid = (pid_t)atoi(argv[1]);
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app) return 3;

        [app activateWithOptions:NSApplicationActivateAllWindows |
                                 NSApplicationActivateIgnoringOtherApps];
        AXUIElementRef axApp = AXUIElementCreateApplication(pid);
        AXUIElementSetMessagingTimeout(axApp, 2.0);
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute, kCFBooleanTrue);

        NSArray *windows = copyAttribute(axApp, kAXWindowsAttribute);
        BOOL found = NO;
        for (id item in windows) {
            AXUIElementRef window = (__bridge AXUIElementRef)item;
            NSString *title = [copyAttribute(window, kAXTitleAttribute) description];
            if (![title hasPrefix:@"StellarBlade"] && ![title hasPrefix:@"SB-Win64-Shipp"]) continue;
            found = YES;
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, kCFBooleanFalse);
            CGPoint position = CGPointMake(80, 80);
            CGSize size = CGSizeMake(950, 600);
            AXValueRef positionValue = AXValueCreate(kAXValueCGPointType, &position);
            AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
            AXError positionError = AXUIElementSetAttributeValue(window, kAXPositionAttribute, positionValue);
            AXError sizeError = AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
            AXError raiseError = AXUIElementPerformAction(window, kAXRaiseAction);
            CFRelease(positionValue);
            CFRelease(sizeValue);
            printf("{\"pid\":%d,\"title\":\"StellarBlade\",\"positionError\":%d,\"sizeError\":%d,\"raiseError\":%d}\n",
                   pid, positionError, sizeError, raiseError);
            break;
        }
        CFRelease(axApp);
        return found ? 0 : 4;
    }
}
