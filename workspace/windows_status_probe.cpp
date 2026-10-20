// Read-only Wine/Windows window inventory. No SDK or CRT required.
// user32 is loaded dynamically; default inventory is read-only. The explicit
// --show-steam-login mode restores only a uniquely identified login window.
// A bounded, read-only
// WM_GETTEXT query is used only for Static/Button dialog controls, never Edit
// controls or password fields. GetWindowText cannot read those other-process
// dialog details on its own.
// ABI reference: Microsoft winuser EnumWindows / EnumChildWindows /
// GetWindowTextW / GetClassNameW / GetWindowThreadProcessId / IsWindowVisible.
using U32 = unsigned int;
using I32 = int;
using U64 = unsigned long long;
using I64 = long long;
using Handle = void *;
static_assert(sizeof(void *) == 8 && sizeof(wchar_t) == 2, "Windows x64 ABI");

extern "C" {
__declspec(dllimport) Handle __stdcall LoadLibraryW(const wchar_t *);
__declspec(dllimport) void *__stdcall GetProcAddress(Handle, const char *);
__declspec(dllimport) U32 __stdcall GetLastError();
__declspec(dllimport) Handle __stdcall GetStdHandle(U32);
__declspec(dllimport) I32 __stdcall WriteFile(Handle, const void *, U32, U32 *, void *);
__declspec(dllimport) I32 __stdcall WideCharToMultiByte(U32, U32, const wchar_t *, I32, char *, I32, const char *, I32 *);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(U32);
void *memset(void *destination, int value, U64 count) {
  auto *bytes = static_cast<volatile unsigned char *>(destination);
  for (U64 i = 0; i < count; ++i) bytes[i] = static_cast<unsigned char>(value);
  return destination;
}
void *memcpy(void *destination, const void *source, U64 count) {
  auto *out = static_cast<unsigned char *>(destination);
  auto *in = static_cast<const unsigned char *>(source);
  for (U64 i = 0; i < count; ++i) out[i] = in[i];
  return destination;
}
}
using EnumCallback = I32 (__stdcall *)(Handle, I64);
using EnumWindowsFn = I32 (__stdcall *)(EnumCallback, I64);
using EnumChildWindowsFn = I32 (__stdcall *)(Handle, EnumCallback, I64);
using GetWindowTextWFn = I32 (__stdcall *)(Handle, wchar_t *, I32);
using GetClassNameWFn = I32 (__stdcall *)(Handle, wchar_t *, I32);
using GetWindowThreadProcessIdFn = U32 (__stdcall *)(Handle, U32 *);
using IsWindowVisibleFn = I32 (__stdcall *)(Handle);
struct Rect { I32 left, top, right, bottom; };
using GetWindowRectFn = I32 (__stdcall *)(Handle, Rect *);
using GetWindowLongPtrWFn = I64 (__stdcall *)(Handle, I32);
using GetSystemMetricsFn = I32 (__stdcall *)(I32);
using ShowWindowAsyncFn = I32 (__stdcall *)(Handle, I32);
using SetWindowPosFn = I32 (__stdcall *)(Handle, Handle, I32, I32, I32, I32, U32);
using SetForegroundWindowFn = I32 (__stdcall *)(Handle);
using GetCommandLineWFn = const wchar_t *(__stdcall *)();
using GetDCFn = Handle (__stdcall *)(Handle);
using ReleaseDCFn = I32 (__stdcall *)(Handle, Handle);
using GetPixelFn = U32 (__stdcall *)(Handle, I32, I32);
using SendMessageTimeoutWFn = I64 (__stdcall *)(Handle, U32, U64, I64, U32, U32, U64 *);
static EnumWindowsFn enumerate;
static EnumChildWindowsFn enumerateChildren;
static GetWindowTextWFn windowText;
static GetClassNameWFn className;
static GetWindowThreadProcessIdFn windowProcess;
static IsWindowVisibleFn visible;
static GetWindowRectFn windowRect;
static GetSystemMetricsFn systemMetrics;
static Handle steamLoginWindow = nullptr;
static Handle steamLoginSurface = nullptr;
static U32 steamLoginCount = 0;
static Handle steamLoginContainer=nullptr, steamLoginWidget=nullptr;
static U32 steamLoginContainerCount=0,steamLoginWidgetCount=0;
static Handle steamServiceErrorWindow = nullptr;
static U32 steamServiceErrorCount = 0;
static Handle clrErrorWindow=nullptr;
static U32 clrErrorCount=0;
static bool clrErrorMissingResources=false;
static SendMessageTimeoutWFn readControlText;
static U32 topCount = 0, childCount = 0;

static void text(const char *value) {
  U32 length = 0, written = 0;
  while (value[length]) ++length;
  WriteFile(GetStdHandle(static_cast<U32>(-11)), value, length, &written, nullptr);
}
static void number(U64 value) {
  char digits[32]; U32 position = 31; digits[position] = 0;
  do { digits[--position] = '0' + value % 10; value /= 10; } while (value);
  text(digits + position);
}
static void pointer(Handle value) {
  char digits[19] = "0x0000000000000000";
  U64 bits = reinterpret_cast<U64>(value);
  for (U32 i = 0; i < 16; ++i) digits[17-i] = "0123456789abcdef"[(bits >> (4*i)) & 15];
  text(digits);
}
static void signedNumber(I32 value) {
  I64 wide = value;
  if (wide < 0) { text("-"); wide = -wide; }
  number(static_cast<U64>(wide));
}
static bool equalWide(const wchar_t *a, const wchar_t *b) {
  while (*a && *a == *b) { ++a; ++b; }
  return *a == *b;
}
static bool isSteamLoginTitle(const wchar_t *caption) {
  return equalWide(caption,L"Sign in to Steam") || equalWide(caption,L"登录 Steam");
}
static bool equalWideAsciiFold(const wchar_t *a,const wchar_t *b) {
  while(*a && *b){wchar_t x=*a++,y=*b++;if(x>=L'A'&&x<=L'Z')x+=32;if(y>=L'A'&&y<=L'Z')y+=32;if(x!=y)return false;}
  return *a==*b;
}
static bool hasArgument(const wchar_t *line, const wchar_t *argument) {
  if (!line) return false;
  for (; *line; ++line) {
    const wchar_t *a = line, *b = argument;
    while (*b && *a == *b) { ++a; ++b; }
    if (!*b && (!*a || *a == L' ' || *a == L'\"')) return true;
  }
  return false;
}
static void quotedWide(const wchar_t *value) {
  // EnumWindows is synchronous on this probe's single thread. Keep large
  // formatting buffers off the stack so no CRT __chkstk import is needed.
  static char utf8[4096];
  I32 length = WideCharToMultiByte(65001, 0, value, -1, utf8, sizeof(utf8), nullptr, nullptr);
  text("\"");
  if (length > 0) {
    static char escaped[8192]; U32 position = 0;
    for (I32 i = 0; i < length - 1 && position + 7 < sizeof(escaped); ++i) {
      unsigned char c = static_cast<unsigned char>(utf8[i]);
      if (c == '\"' || c == '\\') { escaped[position++] = '\\'; escaped[position++] = c; }
      else if (c < 32) {
        escaped[position++] = '\\'; escaped[position++] = 'u';
        escaped[position++] = '0'; escaped[position++] = '0';
        escaped[position++] = "0123456789abcdef"[c >> 4];
        escaped[position++] = "0123456789abcdef"[c & 15];
      } else escaped[position++] = c;
    }
    escaped[position] = 0; text(escaped);
  }
  text("\"");
}
static void emitWindow(Handle window, const char *kind, Handle parent) {
  wchar_t caption[1024] = {}, classBuffer[256] = {};
  U32 pid = 0;
  U32 thread = windowProcess(window, &pid);
  I32 captionCharacters = windowText(window, caption, 1024);
  I32 classCharacters = className(window, classBuffer, 256);
  if(kind[0]=='t' && equalWide(classBuffer,L"vguiPopupWindow") && equalWide(caption,L"Steam Service Error")) {
    steamServiceErrorWindow=window;
    ++steamServiceErrorCount;
  }
  if(kind[0]=='t' && equalWide(classBuffer,L"#32770") && equalWide(caption,L"rundll32.exe - Error")) {
    clrErrorWindow=window;++clrErrorCount;
  }
  if (kind[0] == 't' && equalWide(classBuffer, L"SDL_app") &&
      isSteamLoginTitle(caption)) {
    steamLoginWindow = window;
    ++steamLoginCount;
  }
  if (kind[0] == 'c' && parent == steamLoginWindow &&
      equalWide(classBuffer, L"Chrome_RenderWidgetHostHWND")) steamLoginSurface = window;
  if(kind[0]=='c' && parent==steamLoginWindow && equalWide(classBuffer,L"CefBrowserWindow")) {
    steamLoginContainer=window;++steamLoginContainerCount;
  }
  if(kind[0]=='c' && parent==steamLoginWindow && equalWide(classBuffer,L"Chrome_WidgetWin_1")) {
    steamLoginWidget=window;++steamLoginWidgetCount;
  }
  // Match exact standard dialog classes without a CRT. Restrict the cross-
  // process read to labels and buttons; arbitrary text input is out of scope.
  bool isStatic = classBuffer[0] == L'S' && classBuffer[1] == L't' &&
    classBuffer[2] == L'a' && classBuffer[3] == L't' && classBuffer[4] == L'i' &&
    classBuffer[5] == L'c' && classBuffer[6] == 0;
  bool isButton = classBuffer[0] == L'B' && classBuffer[1] == L'u' &&
    classBuffer[2] == L't' && classBuffer[3] == L't' && classBuffer[4] == L'o' &&
    classBuffer[5] == L'n' && classBuffer[6] == 0;
  if (readControlText && kind[0] == 'c' && (isStatic || isButton)) {
    U64 characters = 0;
    static wchar_t controlText[1024];
    for (U32 i = 0; i < 1024; ++i) controlText[i] = 0;
    // WM_GETTEXT=0x000D; SMTO_ABORTIFHUNG=2, 250ms maximum per control.
    if (readControlText(window, 0x000D, 1024,
          reinterpret_cast<I64>(controlText), 2, 250, &characters) && characters < 1024) {
      for (U32 i = 0; i <= characters; ++i) caption[i] = controlText[i];
      captionCharacters = static_cast<I32>(characters);
    }
  }
  if(kind[0]=='c' && parent==clrErrorWindow && isStatic && equalWide(caption,
      L"A fatal error occurred. However, mscorees.dll could not be loaded to display the appropriate error message.\n\nPlease reinstall the .NET Framework.")) clrErrorMissingResources=true;
  text("{\"kind\":\""); text(kind); text("\",\"hwnd\":\""); pointer(window);
  text("\",\"top_parent\":\""); pointer(parent);
  text("\",\"pid\":"); number(pid); text(",\"tid\":"); number(thread);
  text(",\"visible\":"); text(visible(window) ? "true" : "false");
  text(",\"class\":"); quotedWide(classBuffer);
  text(",\"class_characters\":"); number(classCharacters > 0 ? classCharacters : 0);
  text(",\"text\":"); quotedWide(caption);
  text(",\"text_characters\":"); number(captionCharacters > 0 ? captionCharacters : 0);
  Rect rect = {};
  if (windowRect && windowRect(window, &rect)) {
    text(",\"rect\":["); signedNumber(rect.left); text(","); signedNumber(rect.top);
    text(","); signedNumber(rect.right); text(","); signedNumber(rect.bottom); text("]");
  }
  Handle user = LoadLibraryW(L"user32.dll");
  auto getLong = reinterpret_cast<GetWindowLongPtrWFn>(GetProcAddress(user,"GetWindowLongPtrW"));
  if(getLong){text(",\"style\":");number(static_cast<U32>(getLong(window,-16)));
    text(",\"ex_style\":");number(static_cast<U32>(getLong(window,-20)));}
  text("}\n");
}
static I32 __stdcall visitChild(Handle window, I64 parent) {
  ++childCount;
  emitWindow(window, "child", reinterpret_cast<Handle>(parent));
  return 1;
}
static I32 __stdcall visitTop(Handle window, I64) {
  if (!visible(window)) {
    // Steam initially creates its login window hidden and off-screen. Include
    // only this exact non-credential title/class, never arbitrary hidden UI.
    wchar_t caption[64] = {}, classBuffer[64] = {};
    windowText(window, caption, 64); className(window, classBuffer, 64);
    if (!equalWide(classBuffer, L"SDL_app") ||
        !isSteamLoginTitle(caption)) return 1;
  }
  ++topCount;
  emitWindow(window, "top", window);
  enumerateChildren(window, visitChild, reinterpret_cast<I64>(window));
  return 1;
}
extern "C" void mainCRTStartup() {
  Handle ownNtdll=LoadLibraryW(L"ntdll.dll");
  text("{\"own_probe_ntdll_base\":\"");pointer(ownNtdll);text("\"}\n");
  Handle library = LoadLibraryW(L"user32.dll");
  if (!library) { text("{\"error\":\"LoadLibrary(user32)\",\"code\":"); number(GetLastError()); text("}\n"); ExitProcess(2); }
#define LOAD_USER_API(variable, type, name) \
  variable = reinterpret_cast<type>(GetProcAddress(library, name)); \
  if (!variable) { text("{\"error\":\"Missing user32 API: " name "\"}\n"); ExitProcess(3); }
  LOAD_USER_API(enumerate, EnumWindowsFn, "EnumWindows");
  LOAD_USER_API(enumerateChildren, EnumChildWindowsFn, "EnumChildWindows");
  LOAD_USER_API(windowText, GetWindowTextWFn, "GetWindowTextW");
  LOAD_USER_API(className, GetClassNameWFn, "GetClassNameW");
  LOAD_USER_API(windowProcess, GetWindowThreadProcessIdFn, "GetWindowThreadProcessId");
  LOAD_USER_API(visible, IsWindowVisibleFn, "IsWindowVisible");
  LOAD_USER_API(windowRect, GetWindowRectFn, "GetWindowRect");
  LOAD_USER_API(systemMetrics, GetSystemMetricsFn, "GetSystemMetrics");
  readControlText = reinterpret_cast<SendMessageTimeoutWFn>(GetProcAddress(library, "SendMessageTimeoutW"));
  text("{\"probe\":\"windows_status_probe\",\"scope\":\"read-only visible top-level Wine windows and all their child controls; captions may be unavailable across processes\"}\n");
  text("{\"virtual_screen\":[");
  for (I32 metric = 76; metric <= 79; ++metric) {
    if (metric != 76) text(",");
    signedNumber(systemMetrics(metric));
  }
  text("]}\n");
  I32 ok = enumerate(visitTop, 0);
  text("{\"summary\":true,\"enum_windows_ok\":"); text(ok ? "true" : "false");
  text(",\"visible_top_windows\":"); number(topCount);
  text(",\"child_controls\":"); number(childCount); text("}\n");
  if (steamLoginCount == 1) {
    // Only coarse statistics of the top static heading/background strip.
    // Do not sample credential fields/QR, save images, or print pixel values.
    auto getDC = reinterpret_cast<GetDCFn>(GetProcAddress(library, "GetDC"));
    auto releaseDC = reinterpret_cast<ReleaseDCFn>(GetProcAddress(library, "ReleaseDC"));
    Handle gdi = LoadLibraryW(L"gdi32.dll");
    auto pixel = reinterpret_cast<GetPixelFn>(GetProcAddress(gdi, "GetPixel"));
    Rect rect = {};
    if (getDC && releaseDC && pixel && windowRect(steamLoginWindow, &rect)) {
      Handle sampledWindow = steamLoginSurface ? steamLoginSurface : steamLoginWindow;
      Handle dc = getDC(sampledWindow);
      if (dc) {
        U32 colors[128] = {}, distinct = 0, valid = 0;
        for (I32 row = 0; row < 4; ++row) for (I32 col = 0; col < 32; ++col) {
          U32 color = pixel(dc, (rect.right-rect.left) * (col*2+1) / 64, 8+row*14);
          if (color == 0xffffffff) continue;
          ++valid;
          bool known = false;
          for (U32 i = 0; i < distinct; ++i) if (colors[i] == color) known = true;
          if (!known) colors[distinct++] = color;
        }
        releaseDC(sampledWindow, dc);
        text("{\"login_static_heading_gdi_samples\":"); number(valid);
        text(",\"distinct_colors\":"); number(distinct);
        text(",\"scope\":\"GDI client DC only; not compositor or content proof; no credentials/QR sampled\"}\n");
      }
    }
  }
  Handle kernel = LoadLibraryW(L"kernel32.dll");
  auto commandLine = reinterpret_cast<GetCommandLineWFn>(GetProcAddress(kernel, "GetCommandLineW"));
  if(commandLine && hasArgument(commandLine(),L"--dismiss-clr-resource-error")) {
    if(clrErrorCount!=1 || !clrErrorMissingResources || !readControlText)ExitProcess(21);
    U64 result=0;
    I32 sent=readControlText(clrErrorWindow,0x0111,1,0,2,1000,&result); // WM_COMMAND, IDOK
    text("{\"original_clr_failure_acknowledged\":");number(sent?1:0);text("}\n");
    ExitProcess(sent?0:22);
  }
  if(commandLine && hasArgument(commandLine(),L"--reset-own-steam-login-frontend")) {
    if(steamLoginCount!=1)ExitProcess(16);
    U32 pid=0;windowProcess(steamLoginWindow,&pid);
    auto open=reinterpret_cast<Handle(__stdcall *)(U32,I32,U32)>(GetProcAddress(kernel,"OpenProcess"));
    auto imageName=reinterpret_cast<I32(__stdcall *)(Handle,U32,wchar_t*,U32*)>(GetProcAddress(kernel,"QueryFullProcessImageNameW"));
    auto terminate=reinterpret_cast<I32(__stdcall *)(Handle,U32)>(GetProcAddress(kernel,"TerminateProcess"));
    auto close=reinterpret_cast<I32(__stdcall *)(Handle)>(GetProcAddress(kernel,"CloseHandle"));
    if(!pid||!open||!imageName||!terminate||!close)ExitProcess(17);
    Handle process=open(0x1001,0,pid);if(!process)ExitProcess(18);
    static wchar_t path[1024];U32 length=1024;
    const wchar_t *expected=L"Z:\\Users\\tonytan\\Documents\\GitHub\\gptk-intel-research-20261011\\SteamClient\\bin\\cef\\cef.win64\\steamwebhelper.exe";
    if(!imageName(process,0,path,&length)||!equalWideAsciiFold(path,expected)){close(process);ExitProcess(19);}
    I32 stopped=terminate(process,0);close(process);
    text("{\"own_verified_steam_frontend_reset\":");number(stopped?1:0);text(",\"windows_pid\":");number(pid);text("}\n");
    ExitProcess(stopped?0:20);
  }
  if(commandLine && hasArgument(commandLine(),L"--repair-steam-login-layout")) {
    if(steamLoginCount!=1 || steamLoginContainerCount!=1 || steamLoginWidgetCount!=1)ExitProcess(11);
    U32 owner=0,containerOwner=0,widgetOwner=0;
    windowProcess(steamLoginWindow,&owner);windowProcess(steamLoginContainer,&containerOwner);windowProcess(steamLoginWidget,&widgetOwner);
    if(!owner || owner!=containerOwner || owner!=widgetOwner)ExitProcess(12);
    auto clientRect=reinterpret_cast<GetWindowRectFn>(GetProcAddress(library,"GetClientRect"));
    auto position=reinterpret_cast<SetWindowPosFn>(GetProcAddress(library,"SetWindowPos"));
    Rect client={};if(!clientRect||!position||!clientRect(steamLoginWindow,&client))ExitProcess(13);
    I32 width=client.right-client.left,height=client.bottom-client.top;
    if(width<=0||height<=0||width>4096||height>4096)ExitProcess(14);
    // SWP_ASYNCWINDOWPOS: never synchronously wait on a hung foreign UI thread.
    I32 container=position(steamLoginContainer,nullptr,0,0,width,height,0x4054);
    I32 widget=position(steamLoginWidget,nullptr,0,0,width,height,0x4054);
    text("{\"repair_login_layout_queued\":");number(container&&widget?1:0);
    text(",\"width\":");number(width);text(",\"height\":");number(height);text("}\n");
    ExitProcess(container&&widget?0:15);
  }
  if(commandLine && hasArgument(commandLine(),L"--dismiss-steam-service-error")) {
    if(steamServiceErrorCount!=1 || !readControlText) {
      text("{\"dismiss_service_error\":\"NO_UNIQUE_TARGET\"}\n");ExitProcess(9);
    }
    U64 result=0;
    I32 closed=readControlText(steamServiceErrorWindow,0x0010,0,0,2,1000,&result);
    text("{\"dismiss_service_error_close_sent\":");number(closed?1:0);text("}\n");
    ExitProcess(closed?0:10);
  }
  bool refreshLogin = commandLine && hasArgument(commandLine(), L"--refresh-steam-login");
  if (commandLine && (hasArgument(commandLine(), L"--show-steam-login") || refreshLogin)) {
    // Explicit mutation mode is limited to the exact login class/title in
    // this independent Wine server, and refuses absent/ambiguous targets.
    if (steamLoginCount != 1) {
      text("{\"show_steam_login\":\"NO_UNIQUE_TARGET\",\"count\":"); number(steamLoginCount); text("}\n"); ExitProcess(5);
    }
    auto restore = reinterpret_cast<ShowWindowAsyncFn>(GetProcAddress(library, "ShowWindowAsync"));
    auto position = reinterpret_cast<SetWindowPosFn>(GetProcAddress(library, "SetWindowPos"));
    auto foreground = reinterpret_cast<SetForegroundWindowFn>(GetProcAddress(library, "SetForegroundWindow"));
    if (!restore || !position || !foreground) ExitProcess(6);
    Rect rect = {};
    if (!windowRect(steamLoginWindow, &rect)) ExitProcess(7);
    I32 width = rect.right - rect.left, height = rect.bottom - rect.top;
    if (width <= 0 || height <= 0) ExitProcess(8);
    I32 screenWidth = systemMetrics(78), screenHeight = systemMetrics(79);
    if (width > screenWidth) width = screenWidth;
    if (height > screenHeight) height = screenHeight;
    I32 x = systemMetrics(76) + (screenWidth - width) / 2;
    I32 y = systemMetrics(77) + (screenHeight - height) / 2;
    if(refreshLogin){
      // Genuine minimize/restore transition is a CEF-documented remedy for
      // startup visibility bugs. Do not close, recreate, or inspect contents.
      restore(steamLoginWindow,6); // SW_MINIMIZE
      auto pause = reinterpret_cast<void(__stdcall *)(U32)>(GetProcAddress(kernel,"Sleep"));
      if(pause)pause(300);
    }
    I32 restored = restore(steamLoginWindow, 9); // SW_RESTORE
    I32 raised = position(steamLoginWindow, reinterpret_cast<Handle>(static_cast<I64>(-1)), x,y,width,height,0x4040);
    I32 activated = foreground(steamLoginWindow);
    I32 normal = position(steamLoginWindow, reinterpret_cast<Handle>(static_cast<I64>(-2)),0,0,0,0,0x4043);
    if(refreshLogin){
      auto redraw=reinterpret_cast<I32(__stdcall *)(Handle,const Rect*,Handle,U32)>(GetProcAddress(library,"RedrawWindow"));
      if(redraw)redraw(steamLoginWindow,nullptr,nullptr,0x581); // INVALIDATE|ALLCHILDREN|UPDATENOW|FRAME
    }
    text("{\"show_steam_login\":\"APPLIED\",\"restored\":"); number(restored != 0);
    text(",\"raised\":"); number(raised != 0); text(",\"foreground\":"); number(activated != 0);
    text(",\"normal_z_order\":"); number(normal != 0); text("}\n");
    ExitProcess(raised && normal ? 0 : 9);
  }
  ExitProcess(ok ? 0 : 4);
}
