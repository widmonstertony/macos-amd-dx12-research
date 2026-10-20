// Restore the last game-proven Tencent Steam launch path.
// Exact original engine, exact original Steam, no direct game executable mode.
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <sandbox.h>

int main(int argc, char **argv) {
 if (argc != 2 || strcmp(argv[1], "steam")) return 64;
 const char *engine = "/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/MacOS/winelauncher";
 const char *steam = "/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/Program Files (x86)/Steam/Steam.exe";
 const char *steam_dir = "/Users/tonytan/Library/Application Support/com.tencent.yybmac.wine.engine/wine/drive_c/Program Files (x86)/Steam";
 const char *guard = "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/tencent-normal-original-guard.sb";
 const char *known_good = "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/moltenvk-binary-archive-compute-render/MoltenVK";

 if (chdir(steam_dir)) { perror("original Steam cwd"); return 74; }
 const char *probe_only[] = {"WINEPREFIX", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEDLLOVERRIDES", "YYB_NTDLL_PATH", "YYB_WINESERVER_HOST_APP", 0};
 for (unsigned i = 0; probe_only[i]; ++i) unsetenv(probe_only[i]);

 int protected = !getenv("YYB_OPEN_CLIENT_CONTROL_ONLY");
 if (protected) {
  FILE *pf = fopen(guard, "rb"); if (!pf) return 72;
  if (fseek(pf, 0, SEEK_END)) return 72;
  long n = ftell(pf); if (n <= 0 || n > 65536) return 72;
  rewind(pf);
  char *profile = calloc((size_t)n + 1, 1); if (!profile) return 73;
  if (fread(profile, 1, (size_t)n, pf) != (size_t)n) return 72;
  fclose(pf);
  char *err = 0;
  int result = sandbox_init(profile, 0, &err);
  free(profile);
  if (result) {
   fprintf(stderr, "original asset guard failed: %s\n", err ? err : "unknown");
   if (err) sandbox_free_error(err);
   return 77;
  }
 }

 const char *record = getenv("YYB_OPEN_ENTRY_RECORD");
 if (record) {
  FILE *f = fopen(record, "w");
  if (f) {
   fprintf(f, "{\"entryPID\":%d,\"parentPID\":%d,\"selfAppliedOriginalAssetGuard\":%s,\"originalEngine\":true,\"originalPrefix\":true,\"gameDirectMode\":false,\"knownGoodRestore\":true}\n", getpid(), getppid(), protected ? "true" : "false");
   fclose(f);
  }
 }

 // The 2026-10-17 licensed Steam game run mapped this exact directory and
 // crossed D3D12 initialization. Keep selection explicit and inherited by the
 // original Tencent winelauncher; do not substitute a proxy or stock MoltenVK.
 setenv("DYLD_LIBRARY_PATH", known_good, 1);
 setenv("DYLD_FALLBACK_LIBRARY_PATH", "/Users/tonytan/Library/Application Support/YYBIntelLauncher/.runtime/wine-engine.app/Contents/Frameworks", 1);

 char *args[] = {(char *)engine, (char *)steam, 0};
 execv(engine, args);
 perror("known-good original Steam entry");
 return 71;
}
