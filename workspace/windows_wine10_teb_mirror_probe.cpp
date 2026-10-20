// Own-process compatibility hypothesis only. No Apple or Wine binary edits.
// Source evidence:
// Wine 10 signal_x86_64.c, signal_start_thread: Instrumentation[0] mirrors
// pthread_teb on macOS. Wine 11.16 keeps pthread_teb at TEB offset 0x320 but
// no longer writes Instrumentation[0] (TEB offset 0x16b8, winternl.h).
// This restores that mirror ONLY on this probe's current/main Wine thread.
// It does not claim to fix threads subsequently created by a graphics runtime.
#define mainCRTStartup unmodifiedProbeEntry
#ifdef COMPAT_GPU_PROBE
#include "d3d12_probe.cpp"
#else
#include "windows_load_library_probe.cpp"
#endif
#undef mainCRTStartup

static void compatPointerHex(U64 value) {
    char buffer[19] = "0x0000000000000000";
    for (U32 i = 0; i < 16; ++i) buffer[17-i] = "0123456789abcdef"[(value >> (i*4)) & 15];
    text(buffer);
}
static void restoreMainThreadWine10Mirror() {
    unsigned char *teb = nullptr;
    __asm__ volatile("movq %%gs:0x30, %0" : "=r"(teb));
    text("WINE10_TEB_MIRROR_SCOPE=OWN_PROBE_MAIN_THREAD_ONLY\n");
    if (!teb) { text("WINE10_TEB_MIRROR.result=NO_TEB\n"); return; }
    auto **pthreadField = reinterpret_cast<void **>(teb + 0x320);
    auto **oldMirror = reinterpret_cast<void **>(teb + 0x16b8);
    void *pthreadTeb = *pthreadField;
    void *previousMirror = *oldMirror;
    text("WINE10_TEB_MIRROR.teb="); compatPointerHex(reinterpret_cast<U64>(teb));
    text(" pthreadTeb="); compatPointerHex(reinterpret_cast<U64>(pthreadTeb));
    text(" previousMirror="); compatPointerHex(reinterpret_cast<U64>(previousMirror)); text("\n");
    if (!pthreadTeb) { text("WINE10_TEB_MIRROR.result=NO_PTHREAD_TEB\n"); return; }
    if (previousMirror && previousMirror != pthreadTeb) {
        text("WINE10_TEB_MIRROR.result=REFUSED_NONZERO_CONFLICT\n"); return;
    }
    *oldMirror = pthreadTeb;
    text("WINE10_TEB_MIRROR.result=RESTORED_PUBLIC_WINE10_COMPATIBILITY_FIELD\n");
}
extern "C" __declspec(noreturn) void mainCRTStartup() {
    restoreMainThreadWine10Mirror();
    unmodifiedProbeEntry();
}

