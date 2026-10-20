#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "software_residency_adapter.h"
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

static void experimentTimeout(int signalNumber) {
  (void)signalNumber;
  const char message[] = "GPU_ADAPTER testHostTimeout; terminating only this isolated process\n";
  write(STDERR_FILENO, message, sizeof(message) - 1);
  _exit(124);
}
__attribute__((constructor)) static void experimentBegin(void) {
  const char *timeoutText = getenv("GPU_ADAPTER_TIMEOUT_SECONDS");
  unsigned timeoutSeconds = timeoutText ? (unsigned)strtoul(timeoutText, NULL, 10) : 12;
  if (timeoutSeconds > 120) timeoutSeconds = 120;
  if (!timeoutSeconds) return; // Wine child lifetimes are controlled by the test runner.
  signal(SIGALRM, experimentTimeout);
  alarm(timeoutSeconds);
}

// A process-local public Metal API adapter for an isolated, own test host.
// It changes no Apple binaries or user runtime files.
// GPU_ADAPTER_MODE=trace: every property is genuine (control).
// GPU_ADAPTER_MODE=name: changes only the display name, not capabilities.
// GPU_ADAPTER_MODE=gate: EXPERIMENTAL Apple7 classification override, not real
// Apple7 support. This remains an isolated compatibility experiment, not a
// statement of hardware support or a deployment to the user's live runtime.
// Subsequent D3D12 operations must execute on the real GPU and pass readback.
// All outputs identify this adapter so results cannot be mistaken as original.
@interface ExperimentMetalDevice : NSProxy {
  id<MTLDevice> _device;
  NSString *_mode;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
@end

@implementation ExperimentMetalDevice
- (void)dealloc {
  fprintf(stderr, "GPU_ADAPTER proxyDeallocated genuine=%s\n", _device.name.UTF8String);
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
  const char *mode = getenv("GPU_ADAPTER_MODE");
  _mode = mode ? @(mode) : @"trace";
  // Trace/name controls keep every native behavior. The isolated gate
  // experiment uses actual legacy resource declarations and completion-time
  // retention rather than returning nil for unsupported residency sets.
  _device = [_mode isEqualToString:@"gate"] ? SRWrapMetalDeviceForSoftwareResidency(device) : device;
  fprintf(stderr, "GPU_ADAPTER genuineDevice=%s mode=%s actualMetal3=%d actualApple7=%d\n",
    _device.name.UTF8String, _mode.UTF8String,
    [_device supportsFamily:MTLGPUFamilyMetal3], [_device supportsFamily:MTLGPUFamilyApple7]);
  return self;
}
- (NSString *)name {
  NSString *name = [_mode isEqualToString:@"name"] ? @"Apple M3 Max" : _device.name;
  fprintf(stderr, "GPU_ADAPTER selector=name genuine=%s returned=%s\n", _device.name.UTF8String, name.UTF8String);
  return name;
}
- (BOOL)supportsFamily:(MTLGPUFamily)family {
  BOOL supported = [_device supportsFamily:family];
  BOOL returned = supported;
  if ([_mode isEqualToString:@"gate"] && family == MTLGPUFamilyApple7) returned = YES;
  fprintf(stderr, "GPU_ADAPTER selector=supportsFamily: family=%ld actual=%d returned=%d%s\n", (long)family, supported, returned,
    returned != supported ? " EXPERIMENTAL_CLASSIFICATION_OVERRIDE_NOT_REAL_SUPPORT" : "");
  return returned;
}
- (id<MTLResidencySet>)newResidencySetWithDescriptor:(MTLResidencySetDescriptor *)descriptor error:(NSError **)error {
  id<MTLResidencySet> result = [_device newResidencySetWithDescriptor:descriptor error:error];
  fprintf(stderr, "GPU_ADAPTER residencySet=%p implementation=%s error=%s\n", (__bridge void *)result,
    [_mode isEqualToString:@"gate"] ? "software-execution-residency" : "native",
    error && *error ? (*error).localizedDescription.UTF8String : "none");
  return result;
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)count {
  return [_device newCommandQueueWithMaxCommandBufferCount:count];
}
- (BOOL)respondsToSelector:(SEL)selector {
  BOOL supported = selector == @selector(name) || selector == @selector(supportsFamily:) || [_device respondsToSelector:selector];
  if (getenv("GPU_ADAPTER_VERBOSE")) fprintf(stderr, "GPU_ADAPTER selector=respondsToSelector: target=%s returned=%d\n", sel_getName(selector), supported);
  return supported;
}
- (BOOL)conformsToProtocol:(Protocol *)protocol { return [_device conformsToProtocol:protocol]; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
  return [(NSObject *)_device methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
  if (getenv("GPU_ADAPTER_VERBOSE")) fprintf(stderr, "GPU_ADAPTER forwardedPublicSelector=%s\n", sel_getName(invocation.selector));
  [invocation invokeWithTarget:_device];
}
@end

static NSMutableArray *processLifetimeDevices;
static id<MTLDevice> adaptDevice(id<MTLDevice> device) {
  id proxy = [[ExperimentMetalDevice alloc] initWithDevice:device];
  // Real MTLDevice objects are process-global driver devices. Keep the proxy
  // just as stable even if a factory uses an unowned Metal-device reference.
  // Wine/native worker threads can enumerate the device concurrently.
  // Serialize both publication and mutations of the lifetime registry.
  @synchronized ([ExperimentMetalDevice class]) {
    if (!processLifetimeDevices) processLifetimeDevices = [NSMutableArray array];
    [processLifetimeDevices addObject:proxy];
  }
  return (id<MTLDevice>)proxy;
}
// Match Metal's retained-return contract exactly. Missing this annotation in
// an ARC replacement would return autoreleased objects to a caller expecting
// +1 ownership and crash when DXGI drains its autorelease pool.
static NSArray<id<MTLDevice>> *experimentCopyDevices(void) NS_RETURNS_RETAINED {
  NSArray<id<MTLDevice>> *actual = MTLCopyAllDevices();
  NSMutableArray<id<MTLDevice>> *wrapped = [NSMutableArray array];
  for (id<MTLDevice> device in actual) {
    // This is a genuine AMD-only device selection, not a capability override.
    if ([device.name containsString:@"AMD"]) [wrapped addObject:adaptDevice(device)];
  }
  fprintf(stderr, "GPU_ADAPTER MTLCopyAllDevices genuineAMDCount=%lu\n", (unsigned long)wrapped.count);
  return [wrapped copy];
}
static id<MTLDevice> experimentCreateDefaultDevice(void) NS_RETURNS_RETAINED {
  NSArray<id<MTLDevice>> *actual = MTLCopyAllDevices();
  for (id<MTLDevice> device in actual) {
    if ([device.name containsString:@"AMD"]) return adaptDevice(device);
  }
  fprintf(stderr, "GPU_ADAPTER defaultDevice hasNoAMDDevice\n");
  return nil;
}

// Standard dyld interposing applies only to this launched experiment process.
__attribute__((used)) static struct {
  const void *replacement;
  const void *original;
} interpose[] __attribute__((section("__DATA,__interpose"))) = {
  {(const void *)experimentCopyDevices, (const void *)MTLCopyAllDevices},
  {(const void *)experimentCreateDefaultDevice, (const void *)MTLCreateSystemDefaultDevice},
};
