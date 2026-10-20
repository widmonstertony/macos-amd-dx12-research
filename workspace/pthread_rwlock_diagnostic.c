// Read-only public POSIX-call diagnostics for our isolated Wine process.
// Never fixes or suppresses an invalid call; the original function still runs.
#include <pthread.h>
#include <execinfo.h>
#include <stdio.h>
#include <unistd.h>

static int diagnostic_rdlock(pthread_rwlock_t *lock) {
    if (!lock) {
        const char heading[] = "PTHREAD_DIAGNOSTIC pthread_rwlock_rdlock(NULL), original call follows\n";
        write(STDERR_FILENO, heading, sizeof(heading) - 1);
        void *frames[48];
        int count = backtrace(frames, 48);
        backtrace_symbols_fd(frames, count, STDERR_FILENO);
    }
    return pthread_rwlock_rdlock(lock);
}

static int diagnostic_setname(const char *name) {
    void *gs0, *gs30;
    __asm__ volatile("movq %%gs:0x00,%0\n\tmovq %%gs:0x30,%1" : "=r"(gs0), "=r"(gs30));
    fprintf(stderr, "PTHREAD_DIAGNOSTIC setname=%s pthread=%p gs0=%p gs30=%p\n",
            name ? name : "<NULL>", (void *)pthread_self(), gs0, gs30);
    if (!gs0) {
        void *frames[32];
        backtrace_symbols_fd(frames, backtrace(frames, 32), STDERR_FILENO);
    }
    return pthread_setname_np(name);
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *original;
} interpose[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)diagnostic_rdlock, (const void *)pthread_rwlock_rdlock},
    {(const void *)diagnostic_setname, (const void *)pthread_setname_np},
};
