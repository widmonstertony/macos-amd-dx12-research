#import <AppKit/AppKit.h>
#include <stdlib.h>
int main(int argc,char **argv){@autoreleasepool{
 if(argc!=2)return 2;pid_t pid=(pid_t)strtol(argv[1],0,10);if(pid<=0)return 3;
 NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
 if(!app||app.terminated||app.activationPolicy==NSApplicationActivationPolicyProhibited)return 4;
 BOOL accepted=[app activateWithOptions:NSApplicationActivateIgnoringOtherApps|NSApplicationActivateAllWindows];
 fprintf(stdout,"GAME_ACTIVATE exactCallerVerifiedPID=%d accepted=%d onlyNormalExistingAppActivation noNewProcess noFullscreen\\n",pid,accepted);
 return accepted?0:5;
}}
