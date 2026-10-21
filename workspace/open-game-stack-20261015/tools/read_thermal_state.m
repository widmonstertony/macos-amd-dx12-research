#import <Foundation/Foundation.h>
int main(){@autoreleasepool{
    NSProcessInfo*p=NSProcessInfo.processInfo;
    printf("{\"thermalState\":%ld,\"lowPowerModeEnabled\":%s,\"activeProcessorCount\":%lu}\n",
           (long)p.thermalState,p.lowPowerModeEnabled?"true":"false",(unsigned long)p.activeProcessorCount);
}return 0;}
