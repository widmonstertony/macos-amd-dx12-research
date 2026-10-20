// Reuses the unchanged native host's ABI shims. Renaming its two entry points
// lets this independent compute probe own the execution and exit code.
#define mainCRTStartup compute_unused_original_entry
#define main compute_unused_original_host
#include "../direct_d3d12_probe.mm"
#undef main
#undef mainCRTStartup
#define D3D12_COMPUTE_BASE_INCLUDED
#include "d3d12_compute_probe.cpp"

extern "C" int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <original D3DMetal framework executable>\n", argv[0]);
        return 64;
    }
    native_module_path = argv[1];
    native_module = dlopen(native_module_path, RTLD_NOW | RTLD_LOCAL);
    if (!native_module) { fprintf(stderr, "D3DMetal dlopen: %s\n", dlerror()); return 65; }
    text("D3D12_COMPUTE_HOST=native macOS; Microsoft x64 ABI; no Wine\n");
    mainCRTStartup();
}
