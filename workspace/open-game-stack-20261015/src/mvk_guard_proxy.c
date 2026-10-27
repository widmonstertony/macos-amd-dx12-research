// Re-export the qualified MoltenVK while applying the existing asset guard
// only when Wine first opens its Vulkan backend.  This is deliberately later
// than Tencent's native-loader cache setup, whose hard-link operation macOS
// System Policy rejects if the launcher is sandboxed too early.
#include <sandbox.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <crt_externs.h>
#ifdef MVK_GUARD_TRACE_VULKAN_STARTUP
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan_core.h>
#endif

#ifdef MVK_GUARD_GAME_CONFIG_HEADER
#include MVK_GUARD_GAME_CONFIG_HEADER
#endif

typedef void *(*get_proc_addr_fn)(void *, const char *);
static void append_record(const char *message);

/* A probe build can select a private candidate at compile time. Keeping the
 * default fixed preserves the deployed launch path and avoids replacing a
 * library mapped by the live game. The asset guard is identical in both. */
#ifndef MVK_GUARD_CANDIDATE_PATH
#define MVK_GUARD_CANDIDATE_PATH "/private/tmp/mvk-guard-proxy/libQualifiedCandidateReexport.dylib"
#endif

static void *candidate_symbol(const char *name) {
    /* The candidate is a re-export dependency, so it is already mapped before
     * any exported Vulkan trampoline can run.  Resolving from RTLD_NEXT avoids
     * re-entering dlopen while Wine is still inside its Vulkan-driver pthread
     * once callback.  On macOS 26 that nested open can wait indefinitely in
     * dyld even though the exact candidate image is already present. */
    void *resolved = dlsym(RTLD_NEXT, name);
    if (resolved) return resolved;

    /* Keep the explicit handle as a fallback for standalone probe layouts
     * that do not load the candidate through the re-export dependency. */
    static void *candidate;
    if (!candidate) {
        candidate = dlopen(
            MVK_GUARD_CANDIDATE_PATH,
            RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    }
    // RTLD_FIRST keeps dlsym on the candidate image itself; without it dyld's
    // interposition resolves the lookup back to this trampoline recursively.
    return candidate ? dlsym(candidate, name) : NULL;
}

#ifdef MVK_GUARD_TRACE_VULKAN_STARTUP
// Owned diagnostic proxy only: forward every argument/result unchanged and
// record public API boundaries. No shader, capability, login or game changes.
VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo* info,
        const VkAllocationCallbacks* allocator, VkInstance* instance) {
    append_record("step=vkCreateInstance-enter");
    PFN_vkCreateInstance function = (PFN_vkCreateInstance)candidate_symbol("vkCreateInstance");
    VkResult result = function ? function(info, allocator, instance) : VK_ERROR_INITIALIZATION_FAILED;
    char record[160]; snprintf(record, sizeof(record), "step=vkCreateInstance-return result=%d", result);
    append_record(record); return result;
}
VKAPI_ATTR VkResult VKAPI_CALL vkEnumeratePhysicalDevices(VkInstance instance,
        uint32_t* count, VkPhysicalDevice* devices) {
    append_record("step=vkEnumeratePhysicalDevices-enter");
    PFN_vkEnumeratePhysicalDevices function = (PFN_vkEnumeratePhysicalDevices)candidate_symbol("vkEnumeratePhysicalDevices");
    VkResult result = function ? function(instance, count, devices) : VK_ERROR_INITIALIZATION_FAILED;
    char record[160]; snprintf(record, sizeof(record), "step=vkEnumeratePhysicalDevices-return result=%d", result);
    append_record(record); return result;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(VkPhysicalDevice physical,
        const VkDeviceCreateInfo* info, const VkAllocationCallbacks* allocator, VkDevice* device) {
    append_record("step=vkCreateDevice-enter");
    PFN_vkCreateDevice function = (PFN_vkCreateDevice)candidate_symbol("vkCreateDevice");
    VkResult result = function ? function(physical, info, allocator, device) : VK_ERROR_INITIALIZATION_FAILED;
    char record[160]; snprintf(record, sizeof(record), "step=vkCreateDevice-return result=%d", result);
    append_record(record); return result;
}
#endif

// Wine's macOS Vulkan thunk resolves these two dispatcher exports directly.
// Explicit trampolines keep that lookup reliable even when dyld treats the
// re-export dependency as local to this proxy's dlopen handle.
__attribute__((visibility("default")))
void *vkGetInstanceProcAddr(void *instance, const char *name) {
    static get_proc_addr_fn function;
    if (!function) function = (get_proc_addr_fn)candidate_symbol("vkGetInstanceProcAddr");
    void* resolved = function ? function(instance, name) : NULL;
#ifdef MVK_GUARD_TRACE_VULKAN_STARTUP
    if (resolved && name) {
        if (!strcmp(name, "vkCreateInstance")) return (void*)&vkCreateInstance;
        if (!strcmp(name, "vkEnumeratePhysicalDevices")) return (void*)&vkEnumeratePhysicalDevices;
        if (!strcmp(name, "vkCreateDevice")) return (void*)&vkCreateDevice;
    }
#endif
    return resolved;
}

__attribute__((visibility("default")))
void *vkGetDeviceProcAddr(void *device, const char *name) {
    static get_proc_addr_fn function;
    if (!function) function = (get_proc_addr_fn)candidate_symbol("vkGetDeviceProcAddr");
    return function ? function(device, name) : NULL;
}

static void append_record(const char *message) {
    const char *path = getenv("YYB_OPEN_GUARD_RECORD");
    if (!path || !*path) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    dprintf(fd, "pid=%d ppid=%d %s\n", getpid(), getppid(), message);
    fsync(fd);
    close(fd);
}

__attribute__((constructor))
static void apply_original_asset_guard(void) {
    static const char profile_path[] =
        "/private/tmp/mvk-guard-proxy/tencent-normal-original-guard.sb";
    append_record("step=proxy-loaded");
    /*
     * Steam asks win32u to enumerate Vulkan adapters before its updater/UI can
     * create the first window.  Sandboxing that client process here makes the
     * updater assert, even though the driver itself loaded correctly.  The
     * authenticated Steam child receives the same proxy environment, so apply
     * the original-asset guard only in registered game processes. Their
     * shader/compiler children inherit that policy.  Qualification probes can
     * request the exact same guard explicitly.
     */
    int game_process = 0;
    char **args = *_NSGetArgv();
    int count = *_NSGetArgc();
    for (int index = 0; index < count; ++index) {
        const char *arg = args[index];
        if (!arg) continue;
        if (strcasestr(arg, "SB-Win64") || strcasestr(arg, "StellarBlade") ||
            strcasestr(arg, "ForzaHorizon6")) {
            game_process = 1;
            break;
        }
    }
    if (!game_process && !getenv("YYB_OPEN_GUARD_FORCE")) {
        append_record("step=guard-deferred-nongame");
        return;
    }
    FILE *profile_file = fopen(profile_path, "rb");
    if (!profile_file) {
        append_record("step=guard-profile-open-failed");
        _exit(77);
    }
    if (fseek(profile_file, 0, SEEK_END)) _exit(77);
    long length = ftell(profile_file);
    if (length <= 0 || length > 65536) _exit(77);
    rewind(profile_file);
    char *profile = calloc((size_t)length + 1, 1);
    if (!profile) _exit(77);
    if (fread(profile, 1, (size_t)length, profile_file) != (size_t)length) _exit(77);
    fclose(profile_file);
    char *error = NULL;
    int result = sandbox_init(profile, 0, &error);
    free(profile);
    if (result) {
        append_record("step=guard-apply-failed");
        if (error) sandbox_free_error(error);
        _exit(77);
    }
    append_record("step=guard-ready");
#ifdef MVK_GUARD_GAME_CONFIG_HEADER
    if (game_process) mvk_apply_game_trial_config();
#endif
}
