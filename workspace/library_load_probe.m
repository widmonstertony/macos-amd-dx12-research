#import <Foundation/Foundation.h>
#include <dlfcn.h>

// Loads the original, unmodified framework and checks its public entry points.
// It does not create a GPU device, alter the library, or inspect instructions.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: library_load_probe /absolute/path/to/D3DMetal\n");
            return 2;
        }
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        const char *failure = library ? NULL : dlerror();
        NSMutableDictionary *report = [@{
            @"library": [NSString stringWithUTF8String:argv[1]],
            @"loaded": @(library != NULL),
            @"error": failure ? [NSString stringWithUTF8String:failure] : @""
        } mutableCopy];
        if (library) {
            report[@"D3D12CreateDeviceAvailable"] = @(dlsym(library, "D3D12CreateDevice") != NULL);
            report[@"CreateDXGIFactory1Available"] = @(dlsym(library, "CreateDXGIFactory1") != NULL);
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        if (library) dlclose(library);
        return library ? 0 : 1;
    }
}
