#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN
// Experimental Metal 3 residency implementation for an isolated test host.
// Does not change GPU-family/feature reporting. Device must be the genuine
// native device, before the separate experimental classification proxy.
FOUNDATION_EXPORT id<MTLDevice> SRWrapMetalDeviceForSoftwareResidency(id<MTLDevice> device);
// Allows resources created outside the wrapped device to be explicitly tracked.
// Only genuine resources/heaps on this device are accepted; otherwise throws.
FOUNDATION_EXPORT void SRRegisterMetalAllocation(id<MTLDevice> device, id<MTLAllocation> allocation);
FOUNDATION_EXPORT NSDictionary *SRSoftwareResidencyStatistics(id<MTLDevice> device);
NS_ASSUME_NONNULL_END
