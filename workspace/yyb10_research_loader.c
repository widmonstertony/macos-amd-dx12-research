#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

struct wine_preload_info {
    void *addr;
    size_t size;
};

/* Match Wine 10's native Intel macOS loader memory layout. */
__asm__(".zerofill WINE_RESERVE,WINE_RESERVE");
static char wine_reserve[0x1fffff000]
    __attribute__((section("WINE_RESERVE, WINE_RESERVE")));

__asm__(".zerofill WINE_TOP_DOWN,WINE_TOP_DOWN");
static char wine_top_down[0x001ff0000]
    __attribute__((section("WINE_TOP_DOWN, WINE_TOP_DOWN")));

static const struct wine_preload_info preload_info[] = {
    {wine_reserve, sizeof(wine_reserve)},
    {wine_top_down, sizeof(wine_top_down)},
    {0, 0},
};

const __attribute__((visibility("default"))) struct wine_preload_info
    *wine_main_preload_info = preload_info;

static void init_reserved_areas(void) {
    for (size_t i = 0; wine_main_preload_info[i].size; ++i) {
        mmap(wine_main_preload_info[i].addr,
             wine_main_preload_info[i].size, PROT_NONE,
             MAP_FIXED | MAP_NORESERVE | MAP_PRIVATE | MAP_ANON, -1, 0);
    }
}

typedef void (*wine_main_fn)(int, char **);

int main(int argc, char **argv) {
    init_reserved_areas();

    const char *ntdll_path = getenv("YYB_NTDLL_PATH");
    if (!ntdll_path || !*ntdll_path) {
        fprintf(stderr, "YYB_NTDLL_PATH is not set\n");
        return 2;
    }

    void *ntdll = dlopen(ntdll_path, RTLD_NOW);
    if (!ntdll) {
        fprintf(stderr, "Could not load ntdll.so: %s\n", dlerror());
        return 3;
    }

    wine_main_fn wine_main = (wine_main_fn)dlsym(ntdll, "__wine_main");
    if (!wine_main) {
        fprintf(stderr, "Could not find __wine_main: %s\n", dlerror());
        return 4;
    }

    wine_main(argc, argv);

    /* Tencent's wineserver monitors the first loader PID.  Keep that host
       process alive for the lifetime of a foreground launcher when asked. */
    if (getenv("YYB_KEEPALIVE")) {
        for (;;) pause();
    }
    return 0;
}
