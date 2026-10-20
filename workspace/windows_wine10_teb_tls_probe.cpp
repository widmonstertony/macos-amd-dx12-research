// Own PE's public Windows TLS callback, restoring the removed public Wine 10
// compatibility mirror on this probe's Wine-managed threads. No binary edits.
#include "windows_wine10_teb_mirror_probe.cpp"

extern "C" void __stdcall wine10CompatibilityTlsCallback(void *, U32 reason, void *) {
    if (reason != 1 && reason != 2) return; // PROCESS_ATTACH / THREAD_ATTACH
    unsigned char *teb = nullptr;
    __asm__ volatile("movq %%gs:0x30, %0" : "=r"(teb));
    text("WINE10_TEB_TLS_CALLBACK scope=OWN_PROBE_PROCESS_THREADS reason="); hex(reason);
    if (!teb) { text(" result=NO_TEB\n"); return; }
    void *pthreadTeb = *reinterpret_cast<void **>(teb + 0x320);
    auto **oldMirror = reinterpret_cast<void **>(teb + 0x16b8);
    void *previousMirror = *oldMirror;
    text(" threadId="); compatPointerHex(*reinterpret_cast<U64 *>(teb + 0x48));
    text(" teb="); compatPointerHex(reinterpret_cast<U64>(teb));
    text(" pthreadTeb="); compatPointerHex(reinterpret_cast<U64>(pthreadTeb));
    text(" previousMirror="); compatPointerHex(reinterpret_cast<U64>(previousMirror));
    if (!pthreadTeb || (previousMirror && previousMirror != pthreadTeb)) {
        text(" result=REFUSED_NULL_OR_CONFLICT\n"); return;
    }
    *oldMirror = pthreadTeb;
    text(" result=RESTORED_WINE10_FIELD\n");
}

using TlsCallback = void (__stdcall *)(void *, U32, void *);
struct ImageTlsDirectory64 {
    U64 startAddressOfRawData;
    U64 endAddressOfRawData;
    U64 addressOfIndex;
    U64 addressOfCallbacks;
    U32 sizeOfZeroFill;
    U32 characteristics;
};
static_assert(sizeof(ImageTlsDirectory64) == 40, "PE32+ TLS directory layout");
#pragma section(".tls$AAA", read, write)
#pragma section(".tls$ZZZ", read, write)
#pragma section(".CRT$XLB", read)
#pragma section(".rdata$T", read)
extern "C" {
__declspec(allocate(".tls$AAA")) unsigned char wine10CompatTlsStart = 0;
__declspec(allocate(".tls$ZZZ")) unsigned char wine10CompatTlsEnd = 0;
U32 _tls_index = 0;
__declspec(allocate(".CRT$XLB")) TlsCallback wine10CompatCallbacks[] = {wine10CompatibilityTlsCallback, nullptr};
__declspec(allocate(".rdata$T")) extern const ImageTlsDirectory64 _tls_used = {
    reinterpret_cast<U64>(&wine10CompatTlsStart),
    reinterpret_cast<U64>(&wine10CompatTlsEnd),
    reinterpret_cast<U64>(&_tls_index),
    reinterpret_cast<U64>(&wine10CompatCallbacks[0]),
    0, 0
};
}

