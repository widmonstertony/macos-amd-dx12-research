#define mainCRTStartup graphics_unused_original_entry
#define main graphics_unused_original_host
#include "../direct_d3d12_probe.mm"
#undef main
#undef mainCRTStartup
#define D3D12_GRAPHICS_BASE_INCLUDED
#include "d3d12_graphics_probe.cpp"

extern "C" int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: native_graphics_host <original D3DMetal framework binary>\n"); return 64; }
    native_module_path = argv[1];
    native_module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!native_module) { fprintf(stderr, "D3DMetal dlopen: %s\n", dlerror()); return 1; }
    text("D3D12_GRAPHICS_HOST=native macOS; Microsoft x64 ABI; no Wine\n");
    mainCRTStartup();
}
