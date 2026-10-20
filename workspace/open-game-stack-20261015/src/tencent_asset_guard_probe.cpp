// Checks access only: never writes, truncates, renames or deletes game assets.
#include <windows.h>
static void out(const char *s) { DWORD n=0,w; while(s[n])++n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&w,0); }
extern "C" void mainCRTStartup() {
 const wchar_t *asset=L"Y:\\Volumes\\Applications\\Program Files (x86)\\Steam\\steamapps\\common\\StellarBlade\\SB.exe";
 HANDLE h=CreateFileW(asset,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);
 bool read=h!=INVALID_HANDLE_VALUE; if(read)CloseHandle(h);
 out(read?"asset.read=PASS\n":"asset.read=FAIL\n");
 SetLastError(0);
 h=CreateFileW(asset,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,0,0);
 DWORD err=GetLastError(); bool denied=h==INVALID_HANDLE_VALUE&&err==ERROR_ACCESS_DENIED;
 if(h!=INVALID_HANDLE_VALUE)CloseHandle(h);
 out(denied?"asset.write_access_denied=PASS\n":"asset.write_access_denied=FAIL\n");
 out("scope=Open existing asset handles only; zero game bytes written\n");
 ExitProcess(read&&denied?0:1);
}
