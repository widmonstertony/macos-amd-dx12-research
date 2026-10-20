// Confirm the foreground Steam launch interstitial without inspecting controls.
// Refuse to send input unless the visible foreground window is exactly Steam's
// SDL top-level window. This helper sends one Enter key pair and exits.
using U32 = unsigned int;
using U16 = unsigned short;
using I32 = int;
using H = void*;
using UPtr = unsigned long long;

struct KeyboardInput {
    U16 virtual_key;
    U16 scan_code;
    U32 flags;
    U32 time;
    UPtr extra_info;
};
struct Input {
    U32 type;
    U32 padding;
    KeyboardInput keyboard;
};

extern "C" {
__declspec(dllimport) H __stdcall LoadLibraryW(const wchar_t*);
__declspec(dllimport) void* __stdcall GetProcAddress(H, const char*);
__declspec(dllimport) void __stdcall ExitProcess(U32);
}

static bool equal(const wchar_t* left, const wchar_t* right) {
    while (*left && *left == *right) { ++left; ++right; }
    return *left == *right;
}

extern "C" void mainCRTStartup() {
    H user = LoadLibraryW(L"user32.dll");
    if (!user) ExitProcess(2);
    auto foreground = (H (__stdcall*)())GetProcAddress(user, "GetForegroundWindow");
    auto get_text = (I32 (__stdcall*)(H, wchar_t*, I32))GetProcAddress(user, "GetWindowTextW");
    auto get_class = (I32 (__stdcall*)(H, wchar_t*, I32))GetProcAddress(user, "GetClassNameW");
    auto send_input = (U32 (__stdcall*)(U32, Input*, I32))GetProcAddress(user, "SendInput");
    if (!foreground || !get_text || !get_class || !send_input) ExitProcess(3);
    H window = foreground();
    wchar_t title[64] = {}, cls[64] = {};
    get_text(window, title, 64);
    get_class(window, cls, 64);
    if (!equal(title, L"Steam") || !equal(cls, L"SDL_app")) ExitProcess(4);
    constexpr U16 VK_RETURN = 0x0d;
    constexpr U32 INPUT_KEYBOARD = 1;
    constexpr U32 KEYEVENTF_KEYUP = 2;
    Input input[2] = {};
    input[0].type = INPUT_KEYBOARD;
    input[0].keyboard.virtual_key = VK_RETURN;
    input[1].type = INPUT_KEYBOARD;
    input[1].keyboard.virtual_key = VK_RETURN;
    input[1].keyboard.flags = KEYEVENTF_KEYUP;
    if (send_input(2, input, sizeof(Input)) != 2) ExitProcess(5);
    ExitProcess(0);
}
