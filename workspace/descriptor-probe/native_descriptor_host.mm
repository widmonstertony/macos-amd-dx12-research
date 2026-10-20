#define mainCRTStartup descriptor_unused_capability_entry
#define main descriptor_unused_capability_host
#include "../direct_d3d12_probe.mm"
#undef main
#undef mainCRTStartup
#define D3D12_GRAPHICS_BASE_INCLUDED
#include "d3d12_descriptor_probe.cpp"
extern "C" int main(int argc,char **argv) {
  if (argc != 2) { fprintf(stderr,"usage: native_descriptor_host <original D3DMetal framework>\n"); return 64; }
  native_module_path = argv[1]; native_module = dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
  if (!native_module) { fprintf(stderr,"D3DMetal: %s\n",dlerror()); return 1; }
  text("D3D12_DESCRIPTOR_HOST=native macOS; Microsoft x64 ABI; no Wine; original GPTK4b2\n");
  mainCRTStartup();
}
