// Native replacement for the shell hop in the research frontend only.
// Exact original engine, exact original Steam, no game executable mode.
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sandbox.h>
#include <sys/wait.h>

#include "tencent_original_guard_profile.inc"

static void trace_step(const char *step) {
 const char *record=getenv("YYB_OPEN_ENTRY_RECORD");
 if(!record||!*record)return;
 char path[4096];
 int n=snprintf(path,sizeof(path),"%s.trace",record);
 if(n<0||(size_t)n>=sizeof(path))return;
 int fd=open(path,O_WRONLY|O_CREAT|O_APPEND,0644);
 if(fd<0)return;
 dprintf(fd,"pid=%d ppid=%d step=%s\n",getpid(),getppid(),step);
 fsync(fd);
 close(fd);
}

static int run_and_wait(char *const args[]) {
 pid_t child=fork();
 if(child<0)return -1;
 if(child==0){
  int nullfd=open("/dev/null",O_RDWR);
  if(nullfd>=0){
   (void)dup2(nullfd,STDIN_FILENO);
   (void)dup2(nullfd,STDOUT_FILENO);
   (void)dup2(nullfd,STDERR_FILENO);
   if(nullfd>STDERR_FILENO)close(nullfd);
  }
  execv(args[0],args);
  _exit(127);
 }
 int status=0;
 while(waitpid(child,&status,0)<0){}
 return WIFEXITED(status)?WEXITSTATUS(status):-1;
}

static int engine_server_running(void) {
 char *args[]={"/usr/bin/pgrep","-f",
  "/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/MacOS/wineserver",0};
 return run_and_wait(args)==0;
}

static int prepare_engine_cold_start(void) {
 if(engine_server_running()){
  trace_step("engine-server-already-running");
  return 0;
 }
 trace_step("engine-cold-start-begin");
 char *args[]={"/usr/bin/open","-n",
  "--env","GFX_BACKEND_PATH=/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/Frameworks/render/dxvk/wine",
  "--env","WINE_RETINA_MODE=1",
  "--env","WINE_RETINA_SCALE=2.0",
  "--env","DXVK_HUD=0",
  "--env","MTL_HUD_ENABLED=0",
  "--env","D3DM_ENABLE_METALFX=0",
  "--env","WINEDEBUG=-all",
  "/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app",0};
 if(run_and_wait(args)!=0){
  trace_step("engine-cold-start-open-failed");
  return -1;
 }
 for(int i=0;i<150 && !engine_server_running();++i)usleep(100000);
 if(!engine_server_running()){
  trace_step("engine-cold-start-timeout");
  return -1;
 }
 trace_step("engine-cold-start-ready");
 sleep(14);
 trace_step("engine-cold-start-settled");
 return 0;
}

static void apply_dedicated_stellar_defaults(void) {
 /* LaunchServices may create a fresh app instance when Steam replaces its
  * bootstrap process. That instance does not inherit `open --env` arguments.
  * This binary belongs only to the research Stellar Blade app, so keep the
  * cumulative candidate and bounded caches as intrinsic defaults. */
 static const char *defaults[][2]={
  {"YYB_OPEN_COHERENT_ATOMICS","1"},
  {"YYB_OPEN_ENCODER_LIVE_CACHE","1"},
  {"YYB_OPEN_LIVE_LOOKUP_FAST_CACHE","1"},
  {"YYB_OPEN_DESCRIPTOR_USE_CACHE","1"},
  {"YYB_OPEN_BINARY_ARCHIVE_CACHE","1"},
  {"YYB_OPEN_ENTRY_RECORD","/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/evidence/stellar-fixed-v3-20261019T-current/native-entry-recursive.json"},
  {"VKD3D_AMD_PROTECTED_SUBSET","1"},
  {"MVK_AMD_REFERENCE_RBA2","1"},
  {"MVK_AMD_REFERENCE_RIA2","1"},
  {"MVK_AMD_REFERENCE_NULL","1"},
  {"MVK_AMD_BYTE_GUARDS","1"},
  {"MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS","1"},
  {"MVK_CONFIG_LOG_LEVEL","1"},
  {"MVK_AMD_RUNTIME_REPLAY_ONLY","1"},
  {"MVK_AMD_RUNTIME_TRACE","1"},
  {"MVK_AMD_REPLAY_FAILED_MESH","1"},
  {"MVK_AMD_SERIALIZE_PIPELINE_LINK","1"},
  {"MVK_AMD_COHERENT_ATOMICS","1"},
  {"MVK_AMD_DESCRIPTOR_USE_CACHE","1"},
  {"MVK_AMD_LIVE_LOOKUP_FAST_CACHE","1"},
  {"MVK_AMD_ENCODER_LIVE_CACHE","1"},
  {"MVK_AMD_TRACE_SLOW_COMPUTE","1"},
  {"MVK_AMD_BATCH_LIVE_USE_RESOURCE","1"},
  {"MVK_AMD_BINARY_ARCHIVE_PATH","/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/game-metal-binary-cache/compute-bounded-v2.metalar"},
  {"MVK_AMD_RENDER_BINARY_ARCHIVE_PATH","/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/game-metal-binary-cache/render-bounded-v2.metalar"},
  {"MVK_AMD_BINARY_ARCHIVE_FLUSH_INTERVAL","64"},
  {"MVK_AMD_BINARY_ARCHIVE_MAX_BYTES","268435456"},
  {"MVK_AMD_BINARY_ARCHIVE_TRACE","1"},
  {"VKD3D_FILTER_DEVICE_NAME","AMD Radeon Pro 5600M"},
  {"VKD3D_DEBUG","warn"},
  {"VKD3D_SHADER_CACHE_PATH","Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\open-game-stack-20261015\\build\\private-shader-cache"},
  {"VKD3D_LOG_FILE","Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\open-game-stack-20261015\\evidence\\stellar-fixed-v3-20261019T-current\\vkd3d-game.log"},
  {"MVK_CONFIG_SHADER_DUMP_DIR","/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/evidence/stellar-fixed-v3-20261019T-current/msl"},
  {0,0}
 };
 for(unsigned i=0;defaults[i][0];++i)
  if(!getenv(defaults[i][0]))setenv(defaults[i][0],defaults[i][1],1);
}

int main(int argc,char **argv) {
 trace_step("main-entered");
 if(argc!=2||strcmp(argv[1],"steam"))return 64;
 apply_dedicated_stellar_defaults();
 trace_step("dedicated-stellar-defaults-ready");
 const char *engine="/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/MacOS/winelauncher";
 const char *steam="/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/Program Files (x86)/Steam/Steam.exe";
 // Match the original shell's `cd "${target:h}"` before its native bridge.
 if(chdir("/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/Program Files (x86)/Steam")){perror("original Steam cwd");return 74;}
 trace_step("steam-cwd-ready");
 // The working original steam shell entry does NOT supply these Wine internals.
 // Let its original PathUtils::prepareWineEnvironment choose its own loader and
 // server; the standalone GPU-probe loader is not a Steam/CEF launch baseline.
 const char *probe_only[]={"WINEPREFIX","WINELOADER","WINESERVER","WINEDLLPATH","WINEDLLOVERRIDES","YYB_NTDLL_PATH","YYB_WINESERVER_HOST_APP",0};
 for(unsigned i=0;probe_only[i];++i)unsetenv(probe_only[i]);
 // LaunchServices does not promise to inherit a caller's sandbox. Apply the
 // unchanged original-asset guard here, before the original Steam host starts.
 int protected=!getenv("YYB_OPEN_CLIENT_CONTROL_ONLY");
 int late_guard=getenv("YYB_OPEN_LATE_ASSET_GUARD")!=0;
 int guard_already=getenv("YYB_OPEN_GUARD_ALREADY_APPLIED")!=0;
 if(protected && !guard_already && !late_guard){
 trace_step("guard-start");
 /* Reading the profile from the workspace can block in open(2) after this
  * process is launched through a signed app bundle.  Embed the exact profile
  * bytes at build time so applying the guard has no filesystem dependency. */
 char *err=0;int result=sandbox_init((const char*)kOriginalAssetGuardProfile,0,&err);
 if(result){fprintf(stderr,"original asset guard failed: %s\n",err?err:"unknown");if(err)sandbox_free_error(err);return 77;}
 trace_step("guard-ready");
 }
 if(protected && guard_already)trace_step("guard-inherited");
 if(protected && late_guard)trace_step("guard-deferred-to-moltenvk");
 const char *record=getenv("YYB_OPEN_ENTRY_RECORD");
 const char *d3dmetal4=getenv("YYB_OPEN_D3DMETAL4");
 int use_d3dmetal4=d3dmetal4 && !strcmp(d3dmetal4,"1");
 if(record){FILE *f=fopen(record,"w");if(f){fprintf(f,"{\"entryPID\":%d,\"parentPID\":%d,\"selfAppliedOriginalAssetGuard\":%s,\"lateAssetGuard\":%s,\"originalEngine\":true,\"originalPrefix\":true,\"gameDirectMode\":false,\"d3dMetal4\":%s}\n",getpid(),getppid(),(protected&&!late_guard)?"true":"false",late_guard?"true":"false",use_d3dmetal4?"true":"false");fclose(f);}}
 // The stock engine resets an unregistered custom host to its default backend.
 // In this mode the normal Dock/App entry supplies the original login and
 // lifecycle context, while the already validated bridge selects GPTK 4 only
 // after the vendor environment has been prepared. The game is still launched
 // by the legitimate Steam client; no game executable is invoked here.
 if(use_d3dmetal4){
  const char *bridge="/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/wine-yyb10-gptk4-isolated.app/Contents/MacOS/yyb-gptk4-steam-bridge";
  const char *root=getenv("YYB_RESEARCH_D3DMETAL_ROOT");
  if(!root||!*root)root="/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/runtime-gptk4b2/redist/lib";
  char framework[4096];
  int framework_len=snprintf(framework,sizeof(framework),"%s/external/D3DMetal.framework/Versions/A/D3DMetal",root);
  if(framework_len<0||(size_t)framework_len>=sizeof(framework))return 78;
  if(access(bridge,X_OK)||access(framework,R_OK))return 78;
  setenv("YYB_RESEARCH_GPTK4_ROOT",root,1);
  setenv("D3DM_MTL4","0",1);
  setenv("D3DM_ENABLE_METALFX","0",1);
  setenv("D3DM_SUPPORT_DXR","0",1);
  setenv("MTL_HUD_ENABLED","0",1);
  // LaunchServices starts the Dock host before this entry point. Injecting the
  // research adapter at `open` time also injects it into that Cocoa host and
  // can block dyld before applicationDidFinishLaunching. Delay the inherited
  // injection until the owned Steam bridge is exec'd.
  const char *adapter=getenv("YYB_D3DMETAL4_ADAPTER");
  if(adapter && *adapter)setenv("DYLD_INSERT_LIBRARIES",adapter,1);
  char *args[]={(char*)bridge,(char*)steam,
    "-cef-disable-gpu","-cef-disable-gpu-compositing","-cef-disable-occlusion",
    "-applaunch","3489700","-dx12","-windowed","-ResX=1280","-ResY=800",0};
  execv(bridge,args);perror("original-app GPTK4 Steam entry");return 71;
 }
 int basic=getenv("YYB_OPEN_BASIC_MOLTENVK")!=0;
 if(basic){
  const char *opts[]={"MVK_AMD_REFERENCE_RBA2","MVK_AMD_REFERENCE_RIA2","MVK_AMD_REFERENCE_NULL","MVK_AMD_BYTE_GUARDS","MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS","MVK_CONFIG_SHADER_DUMP_DIR","MVK_CONFIG_LOG_LEVEL","VKD3D_AMD_PROTECTED_SUBSET","VKD3D_FILTER_DEVICE_NAME","VKD3D_DEBUG","VKD3D_LOG_FILE","VKD3D_SHADER_CACHE_PATH","DXVK_FILTER_DEVICE_NAME","DXVK_LOG_PATH","DXVK_LOG_LEVEL",0};
  for(unsigned i=0;opts[i];++i)unsetenv(opts[i]);
 }
 // Override only the intended driver. Do not put every bundled framework
 // ahead of system libraries used by Steam/CEF; retain its normal fallback.
 const char *native3d=getenv("YYB_OPEN_NATIVE_3D_ATTACHMENT");
 int use_native3d=native3d && !strcmp(native3d,"1");
 const char *typed=getenv("YYB_OPEN_TYPED_ROOTS");
 int use_typed=typed && !strcmp(typed,"1");
 const char *trace=getenv("YYB_OPEN_RUNTIME_TRACE");
 int use_trace=trace && !strcmp(trace,"1");
 const char *replay=getenv("YYB_OPEN_RUNTIME_REPLAY");
 int use_replay=replay && !strcmp(replay,"1");
 const char *cache_fix=getenv("YYB_OPEN_CACHE_FIX");
 int use_cache_fix=cache_fix && !strcmp(cache_fix,"1");
 const char *link_serial=getenv("YYB_OPEN_LINK_SERIAL");
 int use_link_serial=link_serial && !strcmp(link_serial,"1");
 const char *vertex_array=getenv("YYB_OPEN_VERTEX_ARRAY");
 int use_vertex_array=vertex_array && !strcmp(vertex_array,"1");
 const char *coherent_atomics=getenv("YYB_OPEN_COHERENT_ATOMICS");
 int use_coherent_atomics=coherent_atomics && !strcmp(coherent_atomics,"1");
 const char *encoder_live_cache=getenv("YYB_OPEN_ENCODER_LIVE_CACHE");
 int use_encoder_live_cache=encoder_live_cache && !strcmp(encoder_live_cache,"1");
 if(use_encoder_live_cache && !use_coherent_atomics){trace_step("missing-coherent-atomics");return 65;}
 const char *recent=getenv("YYB_OPEN_LIVE_LOOKUP_FAST_CACHE");
 int use_recent=recent && !strcmp(recent,"1");
 if(use_recent && !use_encoder_live_cache){trace_step("missing-encoder-live-cache");return 65;}
 const char *descriptor_cache=getenv("YYB_OPEN_DESCRIPTOR_USE_CACHE");
 int use_descriptor_cache=descriptor_cache && !strcmp(descriptor_cache,"1");
 if(use_descriptor_cache && !use_recent){trace_step("missing-live-lookup-cache");return 65;}
 const char *incremental=getenv("YYB_OPEN_DESCRIPTOR_INCREMENTAL");
 int use_incremental=incremental && !strcmp(incremental,"1");
 if(use_incremental && !use_descriptor_cache){trace_step("missing-descriptor-cache-for-incremental");return 65;}
 const char *binary_archive=getenv("YYB_OPEN_BINARY_ARCHIVE_CACHE");
 int use_binary_archive=binary_archive && !strcmp(binary_archive,"1");
 if(use_binary_archive && !use_descriptor_cache){trace_step("missing-descriptor-cache-for-archive");return 65;}
 setenv("DYLD_LIBRARY_PATH",late_guard ?
   "/private/tmp/mvk-guard-proxy-select" : use_binary_archive ?
   "/Applications/Steam（Windows）.app/Contents/Frameworks/MoltenVK" : use_incremental ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-descriptor-incremental/MoltenVK" : use_descriptor_cache ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-descriptor-use/MoltenVK" : use_recent ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-live-recent/MoltenVK" : use_encoder_live_cache ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-live-dedup/MoltenVK" : use_coherent_atomics ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-replay-only/MoltenVK" : use_vertex_array ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-vertex-array/MoltenVK" : use_link_serial ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-link-serialized/MoltenVK" : use_cache_fix ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-cache-r3/MoltenVK" : use_replay ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-runtime-replay/MoltenVK" : use_trace ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-runtime-trace/MoltenVK" : use_typed ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-typed-roots/MoltenVK" : use_native3d ?
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-native-3d-attachment" :
   "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk/MoltenVK",1);
 setenv("DYLD_FALLBACK_LIBRARY_PATH","/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/Frameworks",1);
 /*
  * Steam's bootstrapper must create its first update/status window without an
  * -applaunch request.  Supplying -applaunch during a cold start reproducibly
  * trips Steam's main.cpp:1433 assertion before the client is ready.  Keep the
  * long-lived Tencent Cocoa host on this plain launch; the already-authenticated
  * client receives Stellar Blade through a short Wine client after it is ready.
  */
 const char *steam_app_id=getenv("YYB_OPEN_STEAM_APP_ID");
 int launch_stellar=steam_app_id && !strcmp(steam_app_id,"3489700");
 if(steam_app_id && !launch_stellar)return 66;
 if(launch_stellar)trace_step("steam-applaunch-deferred-until-client-ready");
 /* The stock YYB script first opens the hidden wine-engine app, waits for its
  * wineserver, and gives the cold engine 14 seconds to finish initialization.
  * Starting winelauncher before that bootstrap can leave it waiting on the
  * prefix lock until it exits without ever creating Steam.exe. */
 if(prepare_engine_cold_start()!=0)return 76;
 char *plain_args[]={(char*)engine,(char*)steam,0};
 char **args=plain_args;
 /* The LaunchServices Dock host sets YYB_DOCK_HOST=1. In that mode the stock
  * launcher execs winelauncher and keeps the NSTask (and therefore the Cocoa
  * event-pump owner) alive for the entire Windows session. A detached child
  * briefly creates Steam.exe, but Steam exits as soon as the host terminates. */
 trace_step("engine-exec-start");
 int nullfd=open("/dev/null",O_RDWR);
 if(nullfd>=0)(void)dup2(nullfd,STDIN_FILENO);
 /* Preserve the exact run's native graphics diagnostics outside the protected
  * game tree. Without this, Metal failures surface only as Unreal's OOM box. */
 int outfd=-1,errfd=-1;
 if(record&&*record){
  char outpath[4096],errpath[4096];
  int on=snprintf(outpath,sizeof(outpath),"%s.client-stdout.log",record);
  int en=snprintf(errpath,sizeof(errpath),"%s.client-stderr.log",record);
  if(on>0&&(size_t)on<sizeof(outpath))outfd=open(outpath,O_WRONLY|O_CREAT|O_APPEND,0644);
  if(en>0&&(size_t)en<sizeof(errpath))errfd=open(errpath,O_WRONLY|O_CREAT|O_APPEND,0644);
 }
 if(outfd<0)outfd=nullfd;
 if(errfd<0)errfd=nullfd;
 if(outfd>=0)(void)dup2(outfd,STDOUT_FILENO);
 if(errfd>=0)(void)dup2(errfd,STDERR_FILENO);
 if(outfd>STDERR_FILENO)close(outfd);
 if(errfd>STDERR_FILENO&&errfd!=outfd)close(errfd);
 if(nullfd>STDERR_FILENO&&nullfd!=outfd&&nullfd!=errfd)close(nullfd);
 execv(engine,args);
 trace_step("engine-exec-failed");
 return 71;
}
