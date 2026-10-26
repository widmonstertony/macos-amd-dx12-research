#include "../../profiles/os-scoped-archive-config.h"
#include <assert.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    const char *base = argv[1];
    assert(mvk_archive_owned_directory(base));
    assert(mvk_configure_archive_build(base, "25G241"));
    char old[PATH_MAX]; snprintf(old, sizeof(old), "%s", getenv("MVK_AMD_RENDER_ARCHIVE_DIR"));
    char sentinel[PATH_MAX]; snprintf(sentinel, sizeof(sentinel), "%s/old.metalar", old);
    FILE *f = fopen(sentinel, "wx"); assert(f); fputs("preserve", f); fclose(f);
    assert(mvk_configure_archive_build(base, "25G332"));
    const char *render = getenv("MVK_AMD_RENDER_ARCHIVE_DIR");
    assert(strcmp(old, render));
    char current[PATH_MAX]; snprintf(current, sizeof(current), "%s", render);
    assert(mvk_configure_archive_build(base, "25G332"));
    assert(!strcmp(current, getenv("MVK_AMD_RENDER_ARCHIVE_DIR")));
    f = fopen(sentinel, "r"); assert(f); char data[16] = {0}; assert(fread(data, 1, 8, f) == 8); fclose(f); assert(!strcmp(data, "preserve"));
    const char *invalid[] = {"", ".", "..", "../escape", "bad/name", "bad name", "bad\nname"};
    for (unsigned i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        assert(!mvk_configure_archive_build(base, invalid[i]));
        assert(!strcmp(current, getenv("MVK_AMD_RENDER_ARCHIVE_DIR")));
    }
    char link[PATH_MAX]; snprintf(link, sizeof(link), "%s/by-os/link", base);
    assert(!symlink(old, link));
    assert(!mvk_configure_archive_build(base, "link"));
    assert(!strcmp(current, getenv("MVK_AMD_RENDER_ARCHIVE_DIR")));
    assert(!mvk_configure_archive_build("relative", "25G332"));
    assert(mvk_configure_os_archive_dirs(base));
    printf("{\"passed\":true,\"oldCachePreserved\":true,\"versionRootsDistinct\":true,\"sameVersionStable\":true,\"invalidBuildsRejected\":7,\"symlinkRejected\":true,\"currentRender\":\"%s\",\"currentCompute\":\"%s\"}\n", getenv("MVK_AMD_RENDER_ARCHIVE_DIR"), getenv("MVK_AMD_COMPUTE_ARCHIVE_DIR"));
    return 0;
}
