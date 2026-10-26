// Keep incompatible macOS compiler generations from consuming one admission
// budget. Preserve every old archive; never force a binary archive cache hit.
#pragma once
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int mvk_archive_owned_directory(const char *path) {
    if (mkdir(path, 0755) && errno != EEXIST) return 0;
    struct stat st;
    return !lstat(path, &st) && S_ISDIR(st.st_mode) &&
        st.st_uid == geteuid() && !(st.st_mode & 0022);
}

// Separate validation/path selection from sysctl for owned CPU regression.
static int mvk_configure_archive_build(const char *base, const char *build) {
    if (!base || base[0] != '/' || !build || !*build || strlen(build) >= 64) return 0;
    for (const unsigned char *c = (const unsigned char *)build; *c; ++c)
        if (!((*c >= '0' && *c <= '9') || (*c >= 'A' && *c <= 'Z') ||
              (*c >= 'a' && *c <= 'z') || *c == '-' || *c == '_')) return 0;
    char parent[PATH_MAX], version[PATH_MAX], render[PATH_MAX], compute[PATH_MAX];
    if (snprintf(parent, sizeof(parent), "%s/by-os", base) >= sizeof(parent) ||
        snprintf(version, sizeof(version), "%s/%s", parent, build) >= sizeof(version) ||
        snprintf(render, sizeof(render), "%s/render-shards-v1", version) >= sizeof(render) ||
        snprintf(compute, sizeof(compute), "%s/compute-shards-v3", version) >= sizeof(compute)) return 0;
    if (!mvk_archive_owned_directory(parent) || !mvk_archive_owned_directory(version) ||
        !mvk_archive_owned_directory(render) || !mvk_archive_owned_directory(compute)) return 0;
    if (setenv("MVK_AMD_RENDER_ARCHIVE_DIR", render, 1) ||
        setenv("MVK_AMD_COMPUTE_ARCHIVE_DIR", compute, 1)) return 0;
    return 1;
}

static int mvk_configure_os_archive_dirs(const char *base) {
    char build[64] = {0}; size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) ||
        !size || size > sizeof(build) || !memchr(build, 0, size)) return 0;
    return mvk_configure_archive_build(base, build);
}
