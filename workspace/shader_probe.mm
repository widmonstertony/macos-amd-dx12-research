#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <vector>
#define BOOL DXC_BOOL
#include "shader_probe_headers/dxcapi.h"
#undef BOOL
#include "shader_probe_headers/metal_irconverter.h"

// Original-library compatibility probe. Calls documented public APIs only.
// No Apple library is changed. Public API declarations are kept in the
// shader_probe_headers directory (Microsoft DXC and Apple's converter headers).
static NSMutableDictionary *report;
static void emit(NSString *outputPath) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report
        options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    if (outputPath.length) [data writeToFile:outputPath atomically:YES];
}

#define LOAD_API(name) \
    auto p##name = reinterpret_cast<decltype(&name)>(dlsym(converter, #name)); \
    if (!p##name) { report[@"error"] = @"Missing documented converter API: " #name; emit(outputPath); return 3; }

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: shader_probe <GPTK Resources directory> [JSON result path]\n");
      return 2;
    }
    NSString *resources = [NSString stringWithUTF8String:argv[1]];
    NSString *outputPath = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"";
    report = [@{@"schema": @1,
      @"scope": @"HLSL cs_6_0 -> DXIL -> Metal 3 metallib -> pipeline -> UAV write on native GPU; not game or D3D12 conformance",
      @"resources": resources} mutableCopy];
    void *dxc = dlopen([[resources stringByAppendingPathComponent:@"libdxcompiler.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
    if (!dxc) { report[@"dxcLoadError"] = @(dlerror()); emit(outputPath); return 3; }
    void *converter = dlopen([[resources stringByAppendingPathComponent:@"libmetalirconverter.dylib"] fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
    if (!converter) { report[@"converterLoadError"] = @(dlerror()); emit(outputPath); return 3; }
    auto create = reinterpret_cast<DxcCreateInstanceProc>(dlsym(dxc, "DxcCreateInstance"));
    if (!create) { report[@"error"] = @"Missing DxcCreateInstance"; emit(outputPath); return 3; }
    IDxcCompiler3 *compiler3 = nullptr;
    HRESULT hr = create(CLSID_DxcCompiler, __uuidof(IDxcCompiler3), reinterpret_cast<void **>(&compiler3));
    report[@"dxcCreateHRESULT"] = @((uint32_t)hr);
    if (FAILED(hr) || !compiler3) { emit(outputPath); return 4; }
    const char *source = "RWByteAddressBuffer output : register(u0);\n[numthreads(1,1,1)] void main(uint3 tid : SV_DispatchThreadID) { output.Store(0, 42); }\n";
    DxcBuffer sourceBuffer = {source, strlen(source), DXC_CP_UTF8};
    const wchar_t *args[] = {L"-E", L"main", L"-T", L"cs_6_0", L"-O3"};
    IDxcResult *compileResult = nullptr;
    hr = compiler3->Compile(&sourceBuffer, args, _countof(args), nullptr,
      __uuidof(IDxcResult), reinterpret_cast<void **>(&compileResult));
    report[@"dxcCompileHRESULT"] = @((uint32_t)hr);
    if (FAILED(hr) || !compileResult) { emit(outputPath); return 4; }
    IDxcBlobUtf8 *errors = nullptr;
    compileResult->GetOutput(DXC_OUT_ERRORS, __uuidof(IDxcBlobUtf8), reinterpret_cast<void **>(&errors), nullptr);
    if (errors) { report[@"dxcDiagnostics"] = @(errors->GetStringPointer()); errors->Release(); }
    HRESULT status = E_FAIL;
    compileResult->GetStatus(&status);
    report[@"dxcStatusHRESULT"] = @((uint32_t)status);
    if (FAILED(status)) { emit(outputPath); return 4; }
    IDxcBlob *dxil = nullptr;
    compileResult->GetOutput(DXC_OUT_OBJECT, __uuidof(IDxcBlob), reinterpret_cast<void **>(&dxil), nullptr);
    if (!dxil) { report[@"error"] = @"DXC produced no DXIL"; emit(outputPath); return 4; }
    report[@"dxilBytes"] = @(dxil->GetBufferSize());

    LOAD_API(IRCompilerCreate); LOAD_API(IRCompilerDestroy);
    LOAD_API(IRCompilerSetEntryPointName); LOAD_API(IRCompilerSetMinimumGPUFamily);
    LOAD_API(IRCompilerSetMinimumDeploymentTarget); LOAD_API(IRCompilerSetGlobalRootSignature);
    LOAD_API(IRCompilerAllocCompileAndLink); LOAD_API(IRObjectCreateFromDXIL);
    LOAD_API(IRObjectDestroy); LOAD_API(IRObjectGetMetalLibBinary);
    LOAD_API(IRMetalLibBinaryCreate); LOAD_API(IRMetalLibBinaryDestroy);
    LOAD_API(IRMetalLibGetBytecodeSize); LOAD_API(IRMetalLibGetBytecode);
    LOAD_API(IRErrorGetCode); LOAD_API(IRErrorDestroy);
    LOAD_API(IRRootSignatureCreateFromDescriptor); LOAD_API(IRRootSignatureDestroy);
    LOAD_API(IRRootSignatureGetResourceCount); LOAD_API(IRRootSignatureGetResourceLocations);
    LOAD_API(IRShaderReflectionCreate); LOAD_API(IRShaderReflectionDestroy);
    LOAD_API(IRObjectGetReflection); LOAD_API(IRShaderReflectionGetEntryPointFunctionName);
    LOAD_API(IRShaderReflectionCopyComputeInfo); LOAD_API(IRShaderReflectionReleaseComputeInfo);

    IRRootParameter1 rootParameter = {};
    rootParameter.ParameterType = IRRootParameterTypeUAV;
    rootParameter.Descriptor.ShaderRegister = 0;
    rootParameter.Descriptor.RegisterSpace = 0;
    rootParameter.ShaderVisibility = IRShaderVisibilityAll;
    IRVersionedRootSignatureDescriptor rootDesc = {};
    rootDesc.version = IRRootSignatureVersion_1_1;
    rootDesc.desc_1_1.NumParameters = 1;
    rootDesc.desc_1_1.pParameters = &rootParameter;
    IRError *irError = nullptr;
    IRRootSignature *root = pIRRootSignatureCreateFromDescriptor(&rootDesc, &irError);
    if (!root) { report[@"rootErrorCode"] = @(irError ? pIRErrorGetCode(irError) : 0); emit(outputPath); return 5; }
    std::vector<IRResourceLocation> locations(pIRRootSignatureGetResourceCount(root));
    pIRRootSignatureGetResourceLocations(root, locations.data());
    if (locations.size() != 1) { report[@"error"] = @"Unexpected root signature resource count"; emit(outputPath); return 5; }
    report[@"uavTopLevelOffset"] = @(locations[0].topLevelOffset);
    IRCompiler *irCompiler = pIRCompilerCreate();
    pIRCompilerSetEntryPointName(irCompiler, "main");
    pIRCompilerSetMinimumGPUFamily(irCompiler, IRGPUFamilyMetal3);
    pIRCompilerSetMinimumDeploymentTarget(irCompiler, IROperatingSystem_macOS, "14.0.0");
    pIRCompilerSetGlobalRootSignature(irCompiler, root);
    IRObject *input = pIRObjectCreateFromDXIL(static_cast<const uint8_t *>(dxil->GetBufferPointer()), dxil->GetBufferSize(), IRBytecodeOwnershipNone);
    IRObject *output = input ? pIRCompilerAllocCompileAndLink(irCompiler, nullptr, input, &irError) : nullptr;
    if (!output) { report[@"conversionErrorCode"] = @(irError ? pIRErrorGetCode(irError) : 0); emit(outputPath); return 5; }
    IRMetalLibBinary *binary = pIRMetalLibBinaryCreate();
    bool copied = pIRObjectGetMetalLibBinary(output, IRShaderStageCompute, binary);
    size_t size = pIRMetalLibGetBytecodeSize(binary);
    report[@"metallibBytes"] = @(size);
    if (!copied || !size) { report[@"error"] = @"Conversion produced no metallib"; emit(outputPath); return 5; }
    std::vector<uint8_t> bytecode(size);
    pIRMetalLibGetBytecode(binary, bytecode.data());
    IRShaderReflection *reflection = pIRShaderReflectionCreate();
    pIRObjectGetReflection(output, IRShaderStageCompute, reflection);
    NSString *entryName = @(pIRShaderReflectionGetEntryPointFunctionName(reflection));
    IRVersionedCSInfo computeInfo = {};
    computeInfo.version = IRReflectionVersion_1_0;
    pIRShaderReflectionCopyComputeInfo(reflection, IRReflectionVersion_1_0, &computeInfo);
    MTLSize group = MTLSizeMake(computeInfo.info_1_0.tg_size[0], computeInfo.info_1_0.tg_size[1], computeInfo.info_1_0.tg_size[2]);
    report[@"entryPoint"] = entryName;
    report[@"threadgroupSize"] = @[@(group.width), @(group.height), @(group.depth)];
    NSMutableArray *devices = [NSMutableArray array];
    for (id<MTLDevice> device in MTLCopyAllDevices()) {
      NSMutableDictionary *result = [@{@"name": device.name,
        @"metal3": @([device supportsFamily:MTLGPUFamilyMetal3]),
        @"argumentBufferTier": @(device.argumentBuffersSupport == MTLArgumentBuffersTier2 ? 2 : 1)} mutableCopy];
      NSError *error = nil;
      dispatch_data_t data = dispatch_data_create(bytecode.data(), bytecode.size(), nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      id<MTLLibrary> library = [device newLibraryWithData:data error:&error];
      result[@"libraryCreated"] = @(library != nil);
      if (!library) { result[@"error"] = error.localizedDescription ?: @"library creation failed"; [devices addObject:result]; continue; }
      result[@"functions"] = library.functionNames;
      id<MTLFunction> function = [library newFunctionWithName:entryName];
      id<MTLComputePipelineState> pipeline = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
      result[@"pipelineCreated"] = @(pipeline != nil);
      if (!pipeline) { result[@"error"] = error.localizedDescription ?: @"pipeline creation failed"; [devices addObject:result]; continue; }
      id<MTLBuffer> value = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
      id<MTLBuffer> tlab = [device newBufferWithLength:locations[0].topLevelOffset + sizeof(uint64_t) options:MTLResourceStorageModeShared];
      uint64_t address = value.gpuAddress;
      memcpy((uint8_t *)tlab.contents + locations[0].topLevelOffset, &address, sizeof(address));
      *(uint32_t *)value.contents = 0;
      id<MTLCommandQueue> queue = [device newCommandQueue];
      id<MTLCommandBuffer> commands = [queue commandBuffer];
      id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
      [encoder setComputePipelineState:pipeline];
      [encoder setBuffer:tlab offset:0 atIndex:2];
      [encoder useResource:value usage:MTLResourceUsageRead | MTLResourceUsageWrite];
      [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:group];
      [encoder endEncoding];
      [commands commit];
      [commands waitUntilCompleted];
      uint32_t actual = *(uint32_t *)value.contents;
      result[@"actual"] = @(actual);
      result[@"expected"] = @42;
      result[@"commandBufferStatus"] = @(commands.status);
      result[@"passed"] = @(commands.status == MTLCommandBufferStatusCompleted && actual == 42);
      result[@"error"] = commands.error.localizedDescription ?: @"";
      [devices addObject:result];
    }
    report[@"devices"] = devices;
    emit(outputPath);
    pIRShaderReflectionReleaseComputeInfo(&computeInfo);
    pIRShaderReflectionDestroy(reflection);
    pIRMetalLibBinaryDestroy(binary);
    pIRObjectDestroy(output); pIRObjectDestroy(input);
    pIRCompilerDestroy(irCompiler); pIRRootSignatureDestroy(root);
    if (irError) pIRErrorDestroy(irError);
    dxil->Release(); compileResult->Release(); compiler3->Release();
    return 0;
  }
}
