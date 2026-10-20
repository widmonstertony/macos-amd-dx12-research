#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(void) {
  @autoreleasepool {
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    // An earlier isolated bounds test received the original native assertion
    // "attachmentIndex(4) must be < 4". Keep the runnable probe in bounds.
    for (NSUInteger index = 0; index < 4; ++index) {
      @try {
        MTLRenderPassSampleBufferAttachmentDescriptor *attachment = descriptor.sampleBufferAttachments[index];
        fprintf(stderr,"PUBLIC sampleBufferAttachments[%lu] object=%p\n",(unsigned long)index,(__bridge void *)attachment);
      } @catch (NSException *exception) {
        fprintf(stderr,"PUBLIC sampleBufferAttachments index=%lu exception=%s reason=%s\n",(unsigned long)index,exception.name.UTF8String,exception.reason.UTF8String);
        return 0;
      }
    }
    return 0;
  }
}
