// Optional semantic backstop for runtime-only access qualification.
// This does not change the legacy converter route or enable a new contract.
// Opt in before the first call with an explicitly selected, absolute path in
// MVK_AMD_SPIRV_VALIDATOR_LIBRARY. The file must be owned by this effective UID
// and must not be group/world writable. There is no library search fallback.
#pragma once
#include <cerrno>
#include <cstddef>
#include <cstdint>

#if defined(__has_include)
#if __has_include(<spirv-tools/libspirv.h>) && __has_include(<dlfcn.h>)
#define MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API 1
#endif
#endif
#ifndef MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API
#define MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API 0
#endif

#if MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API
#include <spirv-tools/libspirv.h>
#include <dlfcn.h>
#include <cstdlib>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace mvk { namespace optional_spirv_validator {
constexpr size_t MaxWords = 4u * 1024u * 1024u;
namespace detail {
struct ErrnoGuard {
    int saved = errno;
    ~ErrnoGuard() noexcept { errno = saved; }
};
#if MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API
struct API {
    std::once_flag once;
    void* handle = nullptr;
    decltype(&spvContextCreate) contextCreate = nullptr;
    decltype(&spvValidateBinary) validateBinary = nullptr;
    decltype(&spvDiagnosticDestroy) diagnosticDestroy = nullptr;
    decltype(&spvContextDestroy) contextDestroy = nullptr;
    std::string path;
    bool ready = false;
};

inline API& api() {
    static API value;
    std::call_once(value.once, [&]() noexcept {
        try {
            const char* selected = std::getenv("MVK_AMD_SPIRV_VALIDATOR_LIBRARY");
            if (!selected || selected[0] != '/') return;
            // Resolve once; the process keeps this handle for its lifetime.
            // A failed selection also stays unavailable for this process.
            char* resolved = ::realpath(selected, nullptr);
            if (!resolved) return;
            try { value.path.assign(resolved); }
            catch (...) { std::free(resolved); throw; }
            std::free(resolved);
            struct stat info{};
            if (::stat(value.path.c_str(), &info) != 0 || !S_ISREG(info.st_mode) ||
                info.st_uid != ::geteuid() || (info.st_mode & (S_IWGRP | S_IWOTH))) return;
            value.handle = ::dlopen(value.path.c_str(), RTLD_NOW | RTLD_LOCAL);
            if (!value.handle) return;
            value.contextCreate = reinterpret_cast<decltype(value.contextCreate)>(
                ::dlsym(value.handle, "spvContextCreate"));
            value.validateBinary = reinterpret_cast<decltype(value.validateBinary)>(
                ::dlsym(value.handle, "spvValidateBinary"));
            value.diagnosticDestroy = reinterpret_cast<decltype(value.diagnosticDestroy)>(
                ::dlsym(value.handle, "spvDiagnosticDestroy"));
            value.contextDestroy = reinterpret_cast<decltype(value.contextDestroy)>(
                ::dlsym(value.handle, "spvContextDestroy"));
            value.ready = value.contextCreate && value.validateBinary &&
                value.diagnosticDestroy && value.contextDestroy;
        } catch (...) { value.ready = false; }
    });
    return value;
}
#endif
} // namespace detail

// Unavailable means the additional access contract cannot be established.
// Its caller may continue the existing legacy route; it must not substitute a
// validator that unconditionally succeeds.
inline bool available() noexcept {
    detail::ErrnoGuard guard;
#if MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API
    try { return detail::api().ready; } catch (...) { return false; }
#else
    return false;
#endif
}

// This function has the bool(const uint32_t*, size_t) callback signature.
// No validator options, relaxed capabilities or feature overrides are used.
inline bool validate(const uint32_t* words, size_t count) noexcept {
    detail::ErrnoGuard guard;
    if (!words || count < 5 || count > MaxWords || words[0] != 0x07230203u) return false;
    const uint32_t version = words[1];
    if (version < 0x00010000u || version > 0x00010600u || (version & 0xff0000ffu)) return false;
#if MVK_OPTIONAL_SPIRV_VALIDATOR_HAS_C_API
    try {
        auto& api = detail::api();
        if (!api.ready) return false;
        const spv_target_env target = version <= 0x00010500u ? SPV_ENV_VULKAN_1_2 : SPV_ENV_VULKAN_1_3;
        spv_context context = nullptr;
        spv_diagnostic diagnostic = nullptr;
        bool valid = false;
        try {
            context = api.contextCreate(target);
            if (context) valid = api.validateBinary(context, words, count, &diagnostic) == SPV_SUCCESS;
        } catch (...) { valid = false; }
        // Independent cleanup attempts also cover a C++ exception from a C API
        // implementation, without letting it escape a qualification callback.
        try { if (diagnostic) api.diagnosticDestroy(diagnostic); } catch (...) { valid = false; }
        try { if (context) api.contextDestroy(context); } catch (...) { valid = false; }
        return valid;
    } catch (...) { return false; }
#else
    return false;
#endif
}
}} // namespace mvk::optional_spirv_validator
