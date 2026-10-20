/* Check genuine Windows file/lock APIs; never modify installed reports. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

static int check(const wchar_t *name, int expect_writable)
{
    DWORD attributes = GetFileAttributesW(name);
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        printf("metadata.path_missing.error=%lu\n", GetLastError());
        return 0;
    }
    HANDLE file = CreateFileW(name, GENERIC_READ | GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                             OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD error = file == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    printf("metadata.%s.open=%s error=%lu\n", expect_writable ? "private" : "original",
           file == INVALID_HANDLE_VALUE ? "FAIL" : "PASS", error);
    if (!expect_writable) {
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        return file == INVALID_HANDLE_VALUE && (error == ERROR_ACCESS_DENIED || error == ERROR_WRITE_PROTECT);
    }
    if (file == INVALID_HANDLE_VALUE) return 0;
    OVERLAPPED overlapped = {0};
    BOOL locked = LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                             0, MAXDWORD, MAXDWORD, &overlapped);
    printf("metadata.private.lock=%s error=%lu\n", locked ? "PASS" : "FAIL",
           locked ? 0 : GetLastError());
    unsigned char header[16]; DWORD read = 0, written = 0;
    BOOL stored = locked && ReadFile(file, header, sizeof(header), &read, NULL) && read == sizeof(header);
    stored = stored && SetFilePointer(file, 0, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER;
    /* Rewrite identical header bytes only in the disposable/private database. */
    stored = stored && WriteFile(file, header, sizeof(header), &written, NULL) && written == sizeof(header) && FlushFileBuffers(file);
    printf("metadata.private.write_flush=%s\n", stored ? "PASS" : "FAIL");
    BOOL unlocked = locked && UnlockFileEx(file, 0, MAXDWORD, MAXDWORD, &overlapped);
    CloseHandle(file);
    return locked && unlocked && stored;
}

int main(void)
{
    int old_denied = check(L"Y:\\Volumes\\Applications\\Program Files (x86)\\Steam\\steamapps\\common\\StellarBlade\\.crashdata\\metadata", 0);
    int new_ok = check(L"Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\stellar-overlay\\.crashdata\\metadata", 1);
    printf("metadata.result=%s\n", old_denied && new_ok ? "PASS" : "FAIL");
    return old_denied && new_ok ? 0 : 1;
}
