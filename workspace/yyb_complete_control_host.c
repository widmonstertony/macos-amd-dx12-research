#include <mach-o/dyld.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
// LaunchServices gives Tencent's own Cocoa server the native application
// context it expects. Re-apply the write guard before executing any SDK code.
int main(void) {
    char raw[PATH_MAX], path[PATH_MAX]; unsigned int size=sizeof(raw);
    if (_NSGetExecutablePath(raw,&size) || !realpath(raw,path)) return 2;
    for (int i=0;i<4;i++) {char *end=strrchr(path,'/'); if(!end)return 3;*end=0;}
    if(chdir(path)) return 4;
    execl("/usr/bin/sandbox-exec","sandbox-exec","-f","yyb-complete-control.sb",
          "/bin/bash","run_yyb_complete_control.sh","server",(char*)0);
    return 5;
}
