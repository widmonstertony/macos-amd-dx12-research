// CPU-only: compiles SPIR-V to MSL and exercises native runtime qualification.
#include "SPIRVToMSLConverter.h"
#include "SPIRVSampleOnlyAccess.h"
#include <cassert>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>

using Clock = std::chrono::steady_clock;
static std::vector<uint32_t> readWords(const char* path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("missing SPIR-V file");
    std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
    if (bytes.size() % 4) throw std::runtime_error("bad SPIR-V file");
    std::vector<uint32_t> words(bytes.size() / 4);
    memcpy(words.data(), bytes.data(), bytes.size());
    return words;
}
static bool compileDirect(const std::vector<uint32_t>& words) {
    const bool structural = mvk::sample_only_image_access::classifyStructure(words.data(), words.size()).eligible;
    mvk::SampleOnlyCompilerMSL compiler(words, structural);
    auto options=compiler.get_msl_options();options.msl_version=30100;compiler.set_msl_options(options);
    const std::string msl=compiler.compile();
    return compiler.qualifiesSampleOnlyImageAccess(msl);
}
int main(int argc, char** argv) {
    using mvk::sample_only_image_access::qualifiesFinalMSL;
    assert(qualifiesFinalMSL("t.sample(s, uv);"));
    assert(qualifiesFinalMSL("t /* comment */ . sample /* comment */ (s, uv);"));
    assert(qualifiesFinalMSL("// t.read(x)\nt.gather(s, uv); /* q.foo() */"));
    assert(!qualifiesFinalMSL("t.sample(s, uv); t.read(x);"));
    assert(!qualifiesFinalMSL("t.sample(s, uv); t.write(v,x);"));
    assert(!qualifiesFinalMSL("t.sample(s, uv); t.get_width();"));
    assert(!qualifiesFinalMSL("t.sample(s, uv); t.unknown();"));
    assert(!qualifiesFinalMSL("t.sample(s, uv); t->unknown();"));
    assert(!qualifiesFinalMSL("texture2d<float, access::read> t; t.sample(s,uv);"));
    assert(!qualifiesFinalMSL("texture2d_ms<float> t; t.sample(s,uv);"));
    assert(!qualifiesFinalMSL("t.sample(s, uv); /*"));
    if (argc < 3) return 2;
    const std::string output=argv[1];
    for (int arg=2;arg<argc;++arg) {
        const auto begin=Clock::now();
        auto words=readWords(argv[arg]);
        auto structure=mvk::sample_only_image_access::classifyStructure(words.data(),words.size());
        const auto checked=Clock::now();
        bool converted=false,qualified=false;std::string msl,error;
        unsigned stage=~0u;
        try {
            SPIRV_CROSS_NAMESPACE::Compiler reflection(words);
            const auto entries=reflection.get_entry_points_and_stages();
            if (entries.size()!=1) throw std::runtime_error("expected one entry point");
            stage=entries[0].execution_model;
            mvk::SPIRVToMSLConversionConfiguration config;
            config.options.entryPointName=entries[0].name;
            config.options.entryPointStage=entries[0].execution_model;
            config.options.mslOptions.msl_version=30100;
            config.options.mslOptions.argument_buffers=true;
            config.options.mslOptions.argument_buffers_tier=SPIRV_CROSS_NAMESPACE::CompilerMSL::Options::ArgumentBuffersTier::Tier2;
            mvk::SPIRVToMSLConverter converter;converter.setSPIRV(words);
            mvk::SPIRVToMSLConversionResult result;
            converted=converter.convert(config,result) && !result.msl.empty();
            qualified=result.sampleOnlyImageAccess;
            msl=result.msl;
            if (!converted) error=result.resultLog;
        } catch (const std::exception& e) { error=e.what(); }
        const auto finished=Clock::now();
        std::string name=std::to_string(arg-2)+".metal";
        if (!msl.empty()) { std::ofstream file(output+"/"+name,std::ios::binary);file<<msl; }
        std::cout<<"{\"index\":"<<(arg-2)<<",\"path\":"<<std::quoted(argv[arg])
            <<",\"stage\":"<<stage<<",\"structural\":"<<(structure.eligible?"true":"false")
            <<",\"reason\":"<<std::quoted(mvk::sample_only_image_access::reason_name(structure.reason))
            <<",\"converted\":"<<(converted?"true":"false")<<",\"qualified\":"<<(qualified?"true":"false")
            <<",\"sourceBytes\":"<<msl.size()<<",\"structureNS\":"<<std::chrono::duration_cast<std::chrono::nanoseconds>(checked-begin).count()
            <<",\"convertNS\":"<<std::chrono::duration_cast<std::chrono::nanoseconds>(finished-checked).count()
            <<",\"error\":"<<std::quoted(error)<<"}\n";
        if (std::string(argv[arg]).find("safe_sample.spv")!=std::string::npos) {
            assert(compileDirect(words));
            auto imagePointer=words;
            for(size_t at=5;at<imagePointer.size();at+=imagePointer[at]>>16) {
                if((imagePointer[at]&65535)==25) {
                    auto badDepth=words;badDepth[at+4]=3;
                    assert(!mvk::sample_only_image_access::classifyStructure(badDepth.data(),badDepth.size()).eligible);
                }
                if((imagePointer[at]&65535)==32 && imagePointer[at+2]==0) {imagePointer[at+2]=5349;break;}
            }
            assert(!compileDirect(imagePointer));
            auto wrongSampledType=words;
            for(size_t at=5;at<wrongSampledType.size();at+=wrongSampledType[at]>>16) {
                if((wrongSampledType[at]&65535)==27) {wrongSampledType[at+1]=wrongSampledType[at+2];break;}
            }
            bool wrongQualified=false;
            try { wrongQualified=compileDirect(wrongSampledType); } catch (...) {}
            assert(!wrongQualified);
        }
    }
}
