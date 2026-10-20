/* Read only the already-stopped reporter's fault registers and code returns. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>

int main(void)
{
    HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, 0x0ae4);
    if (!thread) { printf("context.open.error=%lu\n", GetLastError()); return 2; }
    DWORD pid = GetProcessIdOfThread(thread);
    HANDLE process = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    wchar_t path[1024]; DWORD size = 1024;
    if (!process || !QueryFullProcessImageNameW(process, 0, path, &size)) return 3;
    wchar_t *name = wcsrchr(path, L'\\');
    if (!name || _wcsicmp(name + 1, L"crs-handler.exe")) return 4;
    CONTEXT context = {0}; context.ContextFlags = CONTEXT_FULL;
    if (!GetThreadContext(thread, &context)) { printf("context.get.error=%lu\n", GetLastError()); return 5; }
    printf("context.reporter.pid=%lu tid=0ae4 rip=%llx rsp=%llx r12=%llx\n",
           pid, context.Rip, context.Rsp, context.R12);
    if (context.Rip != 0x140013509ULL) return 6;
    unsigned long long metadata = 1, returns[128]; SIZE_T read = 0;
    if (!ReadProcessMemory(process, (void *)(context.Rsp + 0x48), &metadata, sizeof(metadata), &read) || read != sizeof(metadata)) return 7;
    printf("context.metadata=%llx\n", metadata);
    if (ReadProcessMemory(process, (void *)context.Rsp, returns, sizeof(returns), &read))
        for (unsigned i = 0; i < read / 8; ++i)
            if (returns[i] >= 0x140001000ULL && returns[i] < 0x1400d0000ULL)
                printf("context.code_stack.offset=%x return=%llx\n", i * 8, returns[i]);
    CloseHandle(thread); CloseHandle(process);
    printf("context.null_metadata=%s\n", !context.R12 && !metadata ? "CONFIRMED" : "NOT_CONFIRMED");
    return !context.R12 && !metadata ? 0 : 8;
}
