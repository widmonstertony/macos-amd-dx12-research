// Headless, authored-fixture control. No Metal, cache, game or raw upload APIs.
#define ELIGIBLE_2D_ACCESS_CPU_FAULT_CONTROL
#include "eligible_2d_access.h"
#include <spirv-tools/libspirv.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>

static unsigned checks = 0, validations = 0;
static void need(bool ok, const char* why) { ++checks; if (!ok) throw std::runtime_error(why); }
static bool validate(const uint32_t* words, size_t count) {
    ++validations;
    auto context = spvContextCreate(SPV_ENV_VULKAN_1_2);
    spv_const_binary_t binary{words, count}; spv_diagnostic diagnostic = nullptr;
    const bool ok = context && spvValidate(context, &binary, &diagnostic) == SPV_SUCCESS;
    spvDiagnosticDestroy(diagnostic); spvContextDestroy(context); return ok;
}
static std::vector<uint32_t> load(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
    if (!file || bytes.size() % 4) throw std::runtime_error("fixture unavailable");
    std::vector<uint32_t> words(bytes.size() / 4);
    memcpy(words.data(), bytes.data(), bytes.size()); return words;
}
static auto options(bool nativeBuffer, bool emulateCube = false) {
    SPIRV_CROSS_NAMESPACE::CompilerMSL::Options o;
    o.msl_version = 30100; o.texture_buffer_native = nativeBuffer; o.emulate_cube_array = emulateCube;
    o.texture_1D_as_2D = true; o.robust_image_access2 = true;
    return o;
}
int main(int argc, char** argv) { try {
    if (argc == 3 && std::string(argv[1]) == "--scan-msl") {
        std::ifstream file(argv[2]);
        std::string source((std::istreambuf_iterator<char>(file)), {});
        need(bool(file), "MSL unavailable");
        std::cout << "{\"backstopOnly\":true,\"bytes\":" << source.size() << ",\"backstopPassed\":"
            << (eligible_2d_access::finalMSL(source) ? "true" : "false")
            << ",\"SPIRVContractQualified\":false,\"actualPipelineConfigReproduced\":false}\n";
        return 0;
    }
    if ((argc == 4 || argc == 5) && std::string(argv[1]) == "--diagnose-spv") {
        auto words = load(argv[2]);
        auto opts = options(true); opts.argument_buffers = true;
        opts.argument_buffers_tier = SPIRV_CROSS_NAMESPACE::CompilerMSL::Options::ArgumentBuffersTier::Tier2;
        auto compiler = eligible_2d_access::Compiler::create(words, validate);
        need(bool(compiler), "actual module failed semantic validation");
        compiler->set_msl_options(opts);
        SPIRV_CROSS_NAMESPACE::CompilerMSL baseline(words); baseline.set_msl_options(opts);
        if (argc == 5) {
            need(std::string(argv[4]) == "--fixture-layout", "unknown CPU diagnostic layout");
            auto entries = baseline.get_entry_points_and_stages(); need(entries.size() == 1, "one fixture entry required");
            for (uint32_t binding = 0; binding < 4; ++binding) {
                SPIRV_CROSS_NAMESPACE::MSLResourceBinding resource{}; resource.stage = entries[0].execution_model;
                resource.desc_set = 0; resource.binding = binding; resource.count = binding == 3 ? 0 : 1;
                resource.msl_buffer = resource.msl_texture = resource.msl_sampler = binding;
                baseline.add_msl_resource_binding(resource); compiler->add_msl_resource_binding(resource);
            }
        }
        const auto plain = baseline.compile(), observed = compiler->compile();
        std::ofstream output(argv[3]); output << observed;
        need(bool(output), "private MSL output unavailable");
        std::cout << "{\"CPUOnly\":true,\"semanticValidated\":true,\"structurePassed\":"
            << (eligible_2d_access::structure(words) ? "true" : "false")
            << ",\"MSLBytes\":" << observed.size() << ",\"baselineEqualsObserver\":" << (plain == observed ? "true" : "false")
            << ",\"backstopPassed\":" << (eligible_2d_access::finalMSL(observed) ? "true" : "false")
            << ",\"contractPassed\":" << (compiler->qualifies(observed) ? "true" : "false")
            << ",\"reason\":\"" << compiler->reason(observed)
            << "\",\"actualPipelineConfigReproduced\":false,\"GPUCalls\":0}\n";
        return 0;
    }
    need(argc == 2, "fixture directory required");
    using eligible_2d_access::finalMSL;
    const std::string sample = "texture2d<float> t; t.sample(s, uv);";
    need(finalMSL(sample), "2D sample rejected");
    need(finalMSL("texture2d_array<float> t; t.gather(s, uv);"), "2D gather rejected");
    need(finalMSL(sample + "texture_buffer<float> b; b.get_width(); b.read(0);"), "native Buffer read rejected");
    need(finalMSL(sample + "texture3d<uint> b; b.get_width(); b.get_depth(); b.read(0);"), "3D read rejected");
    need(finalMSL("texture_buffer<float> b; b.read(0);"), "vacuously safe no-2D stage rejected");
    need(finalMSL("struct S {spvDescriptor<texture2d<float>> field;}; void main(S& set) {spvDescriptorArray<texture2d<float>> t {set.field}; t[3].sample(s, uv);}"), "descriptor wrapper rejected");
    need(finalMSL("struct S {spvDescriptor<texture3d<uint>> field;}; void main(S& set) {spvDescriptorArray<texture2d<float>> t {reinterpret_cast<const device spvDescriptor<texture2d<float>>*>(&set.field)}; t[3].sample(s, uv);}"), "generated descriptor cast rejected");
    need(finalMSL("struct S { array<texture3d<uint>,1> volume; array<texture_buffer<float>,1> texels; }; void main(const device S& base) { base.volume[0].read(x); base.texels[0].get_width(); base.texels[0].read(i); }"), "known qualified non2D fields rejected");
    need(finalMSL("struct S { spvDescriptor<texture2d<float>> images; }; void main(S& base) { spvDescriptorArray<texture2d<float>> images {base.images}; images[0].sample(s,uv); }"), "struct field/local alias sharing a spelling rejected");
    need(finalMSL("struct S { texture2d<float> image; }; void main(S& base) { base.image.sample(s,uv); }"), "known qualified 2D sample rejected");
    need(finalMSL(sample + "/* t.read(0); */ const char* text = \"t.read(0)\";"), "comment/string was treated as code");
    for (const auto& source : {
        sample + "t.read(0);", sample + "t.get_width();", sample + "t.write(v,0);",
        sample + "t.unknown();", sample + "unknown.read(0);", sample + "t->sample(s,uv);",
        sample + "auto alias = t;", sample + "mystery(t);", sample + "texture2d<float> t;",
        sample + "#define READ(x) x.read(0)\n", sample + "/*", sample + "return t;",
        std::string("texture2d<float,access::read> t; t.sample(s,uv);"),
        std::string("texture2d_ms<float> t; t.sample(s,uv);"),
        std::string("template<class T> float4 helper(T t) { return t.sample(s,uv); }"),
        std::string("texture2d<float> t; spvDescriptorArray<texture_buffer<float>> b {t.read(0)}; b[0].read(0);"),
        std::string("texture2d<float> t; spvDescriptorArray<texture_buffer<float>> b {mystery(t)}; b[0].read(0);"),
        std::string("texture2d<mystery> t; t.sample(s,uv);"),
        std::string("texture2d<box<float>> t; t.sample(s,uv);"),
        std::string("struct S { texture2d<float> image; }; void main(S& base) { base.image.read(x); }"),
        std::string("struct A { texture3d<float> image; }; struct B { texture2d<float> image; }; void main(A& a,B& b) { a.image.read(x); b.image.read(x); }"),
        std::string("struct S { texture3d<float> image; }; void main(S& base) { unknown.image.read(x); }"),
        std::string("struct S { texture3d<float> image; }; void main(S& base) { mystery(unknown.image); }"),
        std::string("struct S { texture3d<float> image; }; void main(S& base) { mystery(base.image); }"),
        std::string("struct S { texture3d<float> image; }; void main(S& base) { mystery(base); }"),
        std::string("struct S { texture3d<float> image; }; void main(S& base) { int base=0; base.image.read(x); }"),
        std::string("struct S { texture3d<float> image; }; void first(S& base) {} void second(S& base) {base.image.read(x);}"),
        std::string("struct S { texture3d<float> image; }; void main(S* base) {base->image.read(x);}"),
        std::string("spvDescriptorArray<texture2d<float>> images {unknown.field}; images[0].sample(s,uv);"),
        std::string("struct S {spvDescriptor<texture3d<float>> field;}; void main(S& base) {spvDescriptorArray<texture2d<float>> images {base.field}; images[0].sample(s,uv);}")
    }) need(!finalMSL(source), "unsafe/unknown exact MSL accepted");
    struct Case { const char* file; bool native, cube, expected; };
    unsigned positives = 0, negatives = 0;
    for (const auto item : {
        Case{"sample", true, false, true}, Case{"buffer", true, false, true},
        Case{"three_d", true, false, true}, Case{"buffer_only", true, false, true},
        Case{"fetch_2d", true, false, false}, Case{"query_2d", true, false, false},
        Case{"buffer", false, false, false}, Case{"one_d", true, false, false},
        Case{"cube_array", true, false, true}, Case{"cube_array", true, true, false},
        Case{"storage_read", true, false, false}, Case{"storage_write", true, false, false},
        Case{"unused_fetch_2d", true, false, false}
    }) {
        auto words = load(std::string(argv[1]) + '/' + item.file + ".spv"); const auto original = words;
        need(validate(words.data(), words.size()), "authored fixture not semantically valid");
        const auto opts = options(item.native, item.cube);
        SPIRV_CROSS_NAMESPACE::CompilerMSL baseline(words); baseline.set_msl_options(opts);
        const std::string plain = baseline.compile();
        auto compiler = eligible_2d_access::Compiler::create(words, validate);
        need(bool(compiler), "validated compiler unavailable"); compiler->set_msl_options(opts);
        const std::string generated = compiler->compile();
        need(generated == plain, "observer changed emitted MSL bytes");
        need(compiler->qualifies(generated) == item.expected, "unexpected structured/exact-MSL result");
        need(!compiler->qualifies(generated + "\n"), "cache MSL byte mismatch accepted");
        need(words == original, "input words changed");
        if (item.expected) ++positives; else ++negatives;
    }
    auto sampleWords = load(std::string(argv[1]) + "/sample.spv");
    need(!eligible_2d_access::Compiler::create(sampleWords), "missing semantic validator accepted");
    auto failedProof = eligible_2d_access::Compiler::create(sampleWords, validate);
    need(bool(failedProof), "fault control compiler unavailable"); failedProof->set_msl_options(options(true));
    failedProof->failNextProofForCPUControl(); const auto fallbackMSL = failedProof->compile();
    SPIRV_CROSS_NAMESPACE::CompilerMSL fallbackBaseline(sampleWords); fallbackBaseline.set_msl_options(options(true));
    need(fallbackMSL == fallbackBaseline.compile(), "optional proof allocation failure broke base conversion");
    need(!failedProof->qualifies(fallbackMSL), "failed optional proof qualified");
    auto unknown = sampleWords; unknown.push_back((1u << 16) | 65000u);
    need(!eligible_2d_access::structure(unknown), "unknown opcode admitted");
    need(!eligible_2d_access::structure({}), "empty SPIR-V admitted");
    std::cout << "{\"passed\":true,\"CPUOnly\":true,\"checks\":" << checks
        << ",\"semanticValidations\":" << validations << ",\"compilerCases\":13,\"positiveCases\":" << positives
        << ",\"negativeCases\":" << negatives << ",\"exactMSLUnchanged\":true,\"cacheMismatchRejected\":true,"
        << "\"optionalProofFailurePreservesBaseMSL\":true,\"qualifiedFieldReceiverCases\":true,"
        << "\"productionIntegrated\":false,\"GPUCalls\":0,\"gameOperated\":false}\n";
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 2; } }
