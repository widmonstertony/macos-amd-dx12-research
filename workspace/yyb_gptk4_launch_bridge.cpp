#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <iostream>
#include <libproc.h>
#include <string>
#include <strings.h>
#include <thread>
#include <unistd.h>
#include <vector>

class PathUtils {
public:
    static void init();
    static void prepareWineEnvironment();
};

enum class WapErrorCode : int;

class WapManager {
public:
    static WapManager &instance();
    void executeExeFile(
        const std::string &package,
        const std::string &exe,
        const std::function<void(WapErrorCode, const std::string &)> &callback);
    void doLaunch(
        const std::string &package,
        const std::string &exe,
        const std::vector<std::string> &args,
        const std::function<void(WapErrorCode, const std::string &)> &callback);
};

extern "C" void wine_engine_init();
extern "C" void wine_engine_process_macos_events();

// libengine normally lives inside Tencent's wineserver executable.  These
// server-side hooks are not used by the command-line launch path, but Mach-O's
// flat namespace still requires the symbols to exist when the dylib is loaded.
extern "C" long active_app_process(...) { return 0; }
extern "C" long is_app_process_exist(...) { return 0; }
extern "C" long wineserver_kill_all_processes(...) { return 0; }
extern "C" long wineserver_kill_processe(...) { return 0; }
extern "C" long wineserver_shutdown_timeout(...) { return 0; }
extern "C" long wineserver_wake_launch_thread(...) { return 0; }

static bool executableNamesEqual(const std::string &expected,
                                 const std::string &actual) {
    if (strcasecmp(expected.c_str(), actual.c_str()) == 0) return true;
    const std::filesystem::path expectedPath(expected);
    if (strcasecmp(expectedPath.extension().string().c_str(), ".exe") == 0 &&
        strcasecmp(expectedPath.stem().string().c_str(), actual.c_str()) == 0) {
        return true;
    }
    return false;
}

static bool processWithExecutableIsRunning(
    const std::filesystem::path &target,
    const std::vector<pid_t> *ignoredLoaderPids = nullptr) {
    const int required = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (required <= 0) return false;

    std::vector<pid_t> pids(
        static_cast<size_t>(required) / sizeof(pid_t) + 32);
    const int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.data(),
                                   static_cast<int>(pids.size() *
                                                    sizeof(pid_t)));
    if (bytes <= 0) return false;

    const std::string expected = target.string();
    const std::string expectedName = target.filename().string();
    char path[PROC_PIDPATHINFO_MAXSIZE];
    char name[PROC_PIDPATHINFO_MAXSIZE];
    const size_t count = static_cast<size_t>(bytes) / sizeof(pid_t);
    for (size_t i = 0; i < count; ++i) {
        if (pids[i] <= 0) continue;
        if (ignoredLoaderPids &&
            std::find(ignoredLoaderPids->begin(), ignoredLoaderPids->end(),
                      pids[i]) != ignoredLoaderPids->end()) {
            continue;
        }
        const int length = proc_pidpath(pids[i], path, sizeof(path));
        if (length > 0 && strcasecmp(expected.c_str(), path) == 0) {
            std::cerr << "LIFETIME_MATCH exact pid=" << pids[i]
                      << " path=" << path << "\n";
            return true;
        }
        // Wap first creates a short-lived loader symlink under engine/links.
        // Its basename is also steam.exe, but the Windows Steam PE has not
        // started at that point (a cold prefix may still be in wineboot).
        // Do not let that bootstrap loader satisfy the lifetime check, or the
        // cold-launch retry below is skipped and only Wine system services
        // remain alive.
        if (length > 0) {
            const std::filesystem::path observed(path);
            const std::string observedName = observed.filename().string();
            if (observed.parent_path().filename() == "links" ||
                (!ignoredLoaderPids &&
                 (strcasecmp(observedName.c_str(), "wineloader") == 0 ||
                  strcasecmp(observedName.c_str(), "wineloader64") == 0))) {
                continue;
            }
        }
        const int nameLength = proc_name(pids[i], name, sizeof(name));
        if (nameLength > 0 && executableNamesEqual(expectedName, name)) {
            std::cerr << "LIFETIME_MATCH name pid=" << pids[i]
                      << " proc_path=" << (length > 0 ? path : "<unknown>")
                      << " name=" << name << "\n";
            return true;
        }
    }
    return false;
}

static std::vector<pid_t> pidsWithExecutableName(
    const std::filesystem::path &target) {
    std::vector<pid_t> found;
    const int required = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (required <= 0) return found;
    std::vector<pid_t> pids(
        static_cast<size_t>(required) / sizeof(pid_t) + 32);
    const int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.data(),
                                   static_cast<int>(pids.size() * sizeof(pid_t)));
    if (bytes <= 0) return found;
    const std::string expectedName = target.filename().string();
    char name[PROC_PIDPATHINFO_MAXSIZE];
    const size_t count = static_cast<size_t>(bytes) / sizeof(pid_t);
    for (size_t i = 0; i < count; ++i) {
        if (pids[i] <= 0) continue;
        const int nameLength = proc_name(pids[i], name, sizeof(name));
        if (nameLength > 0 && executableNamesEqual(expectedName, name)) {
            found.push_back(pids[i]);
        }
    }
    return found;
}

static std::vector<pid_t> directChildrenWithExecutableName(
    pid_t parent, const std::filesystem::path &target) {
    std::vector<pid_t> found;
    const int required = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (required <= 0) return found;
    std::vector<pid_t> pids(
        static_cast<size_t>(required) / sizeof(pid_t) + 32);
    const int bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.data(),
                                   static_cast<int>(pids.size() *
                                                    sizeof(pid_t)));
    if (bytes <= 0) return found;

    const std::string expectedName = target.filename().string();
    char path[PROC_PIDPATHINFO_MAXSIZE];
    const size_t count = static_cast<size_t>(bytes) / sizeof(pid_t);
    for (size_t i = 0; i < count; ++i) {
        if (pids[i] <= 0) continue;
        proc_bsdinfo info{};
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info,
                         sizeof(info)) != sizeof(info) ||
            info.pbi_ppid != static_cast<uint32_t>(parent)) {
            continue;
        }
        const int length = proc_pidpath(pids[i], path, sizeof(path));
        if (length <= 0) continue;
        if (executableNamesEqual(
                expectedName,
                std::filesystem::path(path).filename().string())) {
            found.push_back(pids[i]);
        }
    }
    return found;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::cerr << "usage: winelauncher EXE [ARG ...]\n";
        return 64;
    }

    const std::filesystem::path requestedTarget(argv[1]);
    const bool isSteamTarget =
        strcasecmp(requestedTarget.filename().string().c_str(), "Steam.exe") == 0;
    if (!isSteamTarget) return 64; // Dedicated Steam experiment, never Sky.

    wine_engine_init();
    // The stock executable establishes its bundle-relative paths from main().
    // A custom host needs to do this explicitly, but only after engine init has
    // configured YYBMacLog (PathUtils::init logs and traps if called earlier).
    PathUtils::init();

    // Tencent currently resets an unregistered app to its Apple-Silicon GPTK
    // default during initialization.  Re-apply the Intel-safe DXVK path after
    // initialization so the launched Windows process inherits it.
    const std::filesystem::path executable =
        std::filesystem::canonical(std::filesystem::path(argv[0]));
    const std::string dxvk =
        (executable.parent_path().parent_path() /
         "Frameworks/render/dxvk/wine").string();
    setenv("GFX_BACKEND_PATH", dxvk.c_str(), 1);
    setenv("WINE_RETINA_MODE", "1", 1);
    // Use a 2x backing surface for both launchers. Per-process DPI awareness
    // in the prefix keeps FeverGames' logical window size unchanged while
    // avoiding the 1x bitmap upscale that makes its text blurry.
    setenv("WINE_RETINA_SCALE", "2.0", 1);
    if (!isSteamTarget) {
        setenv("QT_ENABLE_HIGHDPI_SCALING", "1", 1);
        setenv("QT_AUTO_SCREEN_SCALE_FACTOR", "1", 1);
        setenv("QT_SCALE_FACTOR", "1", 1);
        setenv(
            "QTWEBENGINE_CHROMIUM_FLAGS",
            "--disable-gpu --disable-gpu-compositing "
            "--disable-direct-composition --force-device-scale-factor=2",
            1);
    }
    setenv("DXVK_HUD", "0", 1);
    setenv("MTL_HUD_ENABLED", "0", 1);
    setenv("D3DM_ENABLE_METALFX", "0", 1);
    setenv("WINEDEBUG", "-all", 1);
    PathUtils::prepareWineEnvironment();
    // Override only this owned launcher's child environment AFTER the vendor
    // setup. Installed Tencent launcher, engine, Sky and global settings stay
    // unchanged. Original GPTK/Apple binaries are loaded, never patched.
    const char *backend=getenv("YYB_RESEARCH_GPTK4_ROOT");
    if (!backend || !*backend) return 78;
    const std::filesystem::path root=std::filesystem::canonical(backend);
    if (!std::filesystem::exists(root/"wine/x86_64-windows/d3d12.dll") ||
        !std::filesystem::exists(root/"external/libd3dshared.dylib")) return 79;
    setenv("GFX_BACKEND_PATH",(root/"wine").string().c_str(),1);
    const char *vendor=getenv("WINEDLLPATH");
    const std::string paths=(root/"wine").string()+":"+(vendor?vendor:"");
    setenv("WINEDLLPATH",paths.c_str(),1);
    setenv("WINEDEBUG","-all,err+all,+loaddll",1);
    // The Dock host must not load the graphics adapter. Delay the insertion
    // until this bridge has initialized, then pass it only to Wap's Wine/Steam
    // descendants.
    if (const char *adapter = getenv("YYB_D3DMETAL4_ADAPTER")) {
        if (*adapter) setenv("DYLD_INSERT_LIBRARIES", adapter, 1);
    }
    fprintf(stderr,"OWN_STEAM_GPTK4_BACKEND=%s; no fragment candidate/game shader substitution\n",root.string().c_str());

    std::vector<std::string> args;
    for (int i = 2; i < argc; ++i) args.emplace_back(argv[i]);
    std::atomic<bool> finished{false};
    int result = 70;
    std::string detail;
    const std::filesystem::path target =
        std::filesystem::canonical(std::filesystem::path(argv[1]));
    std::filesystem::path lifetimeTarget = target;
    if (const char *configuredLifetime =
            std::getenv("YYB_LIFETIME_EXECUTABLE")) {
        if (*configuredLifetime) {
            std::error_code error;
            const auto resolved = std::filesystem::canonical(
                std::filesystem::path(configuredLifetime), error);
            if (!error) lifetimeTarget = resolved;
        }
    }
    const std::string package =
        isSteamTarget
            ? "com.tencent.macexe.com.steampowered.steam"
            : "com.tencent.macexe.com.45a7ca33";
    bool launchedProcessSeen = false;
    std::vector<pid_t> ignoredBootstrapLoaders;
    auto submitLaunch = [&]() {
        finished.store(false);
        result = 70;
        detail.clear();
        const auto callback = [&](WapErrorCode code,
                                  const std::string &message) {
            result = static_cast<int>(code);
            detail = message;
            std::cerr << "WAP_LAUNCH_CALLBACK code=" << result
                      << " detail=" << detail << "\n";
            finished.store(true);
        };
        WapManager::instance().doLaunch(
            package, target.string(), args, callback);
    };

    std::vector<pid_t> bootstrapChildren;
    const bool needsLocalExeBootstrap =
        !isSteamTarget && lifetimeTarget != target &&
        !processWithExecutableIsRunning(lifetimeTarget);
    if (needsLocalExeBootstrap) {
        // Tencent's old Intel engine cannot complete a cold local-EXE request
        // until its prefix wineserver exists. executeExeFile is the engine's
        // own bootstrap path: keep it in this host/session, wait for its loader
        // child, then submit the real argument-bearing Wap request. The first
        // child becomes FeverGames' long-lived main process, so it must remain
        // alive after the argument-bearing bridge creates the CEF web layer.
        finished.store(false);
        WapManager::instance().executeExeFile(
            package, target.string(),
            [&](WapErrorCode code, const std::string &message) {
                result = static_cast<int>(code);
                detail = message;
                finished.store(true);
            });
        for (int i = 0; i < 200 && bootstrapChildren.empty(); ++i) {
            wine_engine_process_macos_events();
            bootstrapChildren = directChildrenWithExecutableName(
                getpid(), target);
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (bootstrapChildren.empty()) {
            if (!detail.empty()) std::cerr << detail << "\n";
            if (!finished.load()) return 75;
            if (result != 0) return result;
            return 76;
        }
        for (int i = 0; i < 60; ++i) {
            wine_engine_process_macos_events();
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        submitLaunch();
        for (int i = 0; i < 600; ++i) {
            wine_engine_process_macos_events();
            if (processWithExecutableIsRunning(lifetimeTarget)) {
                launchedProcessSeen = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    } else {
        // Steam and warm local apps can use the normal path immediately. A
        // cold Steam prefix may acknowledge the first request during wineboot,
        // so retry it once while retaining the same event-pump host.
        for (int attempt = 0; attempt < 2 && !launchedProcessSeen; ++attempt) {
            std::cerr << "WAP_LAUNCH_ATTEMPT " << (attempt + 1) << "\n";
            submitLaunch();
            const int ticks = attempt == 0 ? 150 : 300;
            for (int i = 0; i < ticks; ++i) {
                wine_engine_process_macos_events();
                const auto *ignored = attempt == 0 ? nullptr : &ignoredBootstrapLoaders;
                if (processWithExecutableIsRunning(lifetimeTarget, ignored)) {
                    launchedProcessSeen = true;
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            if (attempt == 0 && !launchedProcessSeen) {
                ignoredBootstrapLoaders = pidsWithExecutableName(lifetimeTarget);
                for (pid_t pid : ignoredBootstrapLoaders) {
                    std::cerr << "IGNORED_BOOTSTRAP_LOADER pid=" << pid << "\n";
                }
            }
            if (!detail.empty()) std::cerr << detail << "\n";
        }
    }
    if (!launchedProcessSeen) {
        if (!finished.load()) return 75;
        if (result != 0) return result;
        return 76;
    }

    // Tencent's host must continue pumping Cocoa events for the lifetime of
    // the top-level Windows process.  Exiting the host after startup leaves
    // modern Steam's main loop stalled even though its PE process remains.
    bool seen = true;
    int missingTicks = 0;
    const std::filesystem::path steamWebHelper =
        target.parent_path() / "steamwebhelper.exe";
    // Wine PE processes all resolve to wineloader through libproc, and recent
    // Steam CEF children do not expose their PE basename via proc_name.  The
    // exact Tencent wineserver Mach-O path is stable for this owned prefix and
    // remains present through Steam's core/CEF hand-offs and while the game is
    // running.  Keep pumping events while that server is alive.
    const std::filesystem::path ownedWineServer =
        executable.parent_path() / "wineserver";
    for (;;) {
        wine_engine_process_macos_events();
        const bool lifetimeRunning =
            processWithExecutableIsRunning(lifetimeTarget,
                                           &ignoredBootstrapLoaders) ||
            (isSteamTarget &&
             (processWithExecutableIsRunning(steamWebHelper,
                                              &ignoredBootstrapLoaders) ||
              processWithExecutableIsRunning(ownedWineServer)));
        if (lifetimeRunning) {
            seen = true;
            missingTicks = 0;
        } else if (seen) {
            // Steam's bootstrapper hands off to the client/UI processes and can
            // briefly leave no core steam.exe visible. Keep the event-pump host
            // through that transition, but still exit after a bounded absence.
            if (++missingTicks >= 600) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return 0;
}
