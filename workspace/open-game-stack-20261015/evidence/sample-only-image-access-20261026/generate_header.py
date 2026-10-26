from pathlib import Path
import json,hashlib
root=Path(__file__).resolve().parents[2]
p=root/'vendor/SPIRV-Headers-f88a2d766840fc825af1fc065977953ba1fa4a91/include/spirv/unified1/spirv.core.grammar.json'
d=json.loads(p.read_text());ops={v['opname']:v for v in d['instructions']}
classes={'Miscellaneous','Debug','Annotation','Mode-Setting','Constant-Creation','Function','Memory','Composite','Conversion','Arithmetic','Bit','Relational_and_Logical','Control-Flow','Derivative','Barrier','Group','Non-Uniform','Primitive','Type-Declaration'}
reject={'OpTypeOpaque','OpTypeEvent','OpTypeDeviceEvent','OpTypeReserveId','OpTypeQueue','OpTypePipe','OpTypePipeStorage','OpTypeNamedBarrier','OpTypeForwardPointer','OpImageTexelPointer'}
image_allow=['OpSampledImage','OpImage','OpImageSampleImplicitLod','OpImageSampleExplicitLod','OpImageSampleDrefImplicitLod','OpImageSampleDrefExplicitLod','OpImageSampleProjImplicitLod','OpImageSampleProjExplicitLod','OpImageSampleProjDrefImplicitLod','OpImageSampleProjDrefExplicitLod','OpImageGather','OpImageDrefGather']
allowed={v['opcode']:v for v in d['instructions'] if v['opcode']<=366 and v.get('class')in classes and v['opname']not in reject and 'Image'not in v['opname']}
for name in ['OpDemoteToHelperInvocation','OpIsHelperInvocationEXT']+image_allow+['OpTypeImage','OpTypeSampledImage','OpExtension','OpExtInstImport','OpExtInst']:allowed[ops[name]['opcode']]=ops[name]
safe_caps=['PhysicalStorageBufferAddresses','SampledBuffer','ImageBuffer','StorageImageWriteWithoutFormat','ImageQuery','DemoteToHelperInvocation','Matrix','Shader','Geometry','Tessellation','Float16','Float64','Int64','Int16','Int8','ClipDistance','CullDistance','ImageCubeArray','SampleRateShading','ImageGatherExtended','Sampled1D','SampledCubeArray','MinLod','DerivativeControl','GeometryPointSize','TessellationPointSize','MultiViewport','UniformBufferArrayDynamicIndexing','SampledImageArrayDynamicIndexing','StorageBufferArrayDynamicIndexing','DrawParameters','GroupNonUniform','GroupNonUniformVote','GroupNonUniformArithmetic','GroupNonUniformBallot','GroupNonUniformShuffle','GroupNonUniformShuffleRelative','GroupNonUniformClustered','GroupNonUniformQuad','ShaderNonUniform','RuntimeDescriptorArray','UniformBufferArrayNonUniformIndexing','SampledImageArrayNonUniformIndexing','StorageBufferArrayNonUniformIndexing','StorageBuffer16BitAccess','UniformAndStorageBuffer16BitAccess','StoragePushConstant16','StorageInputOutput16','StorageBuffer8BitAccess','UniformAndStorageBuffer8BitAccess','StoragePushConstant8']
caps={v['enumerant']:v['value'] for k in d['operand_kinds']if k['kind']=='Capability'for v in k['enumerants']};safe_caps={caps[n]:n for n in safe_caps}
def table():
 return '\n'.join(f'        case {n}: return {1+sum(1 for a in v.get("operands",[]) if a.get("quantifier")not in ("*","?"))}; // {v["opname"]}'for n,v in sorted(allowed.items()))
header=r'''// CPU-only prototype. Not integrated with MoltenVK, the binder or cache formats.
// Whitelist derived from SPIRV-Headers grammar SHA256 @GRAMMAR@.
// A positive result proves only conservative whole-module image access,
// not heap/attachment/residency/lifetime eligibility or GPU correctness.
#pragma once
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cerrno>
#include <string>
#include <vector>
#include <utility>
namespace sample_only_image_access {
enum class Reason { Eligible, InvalidHeader, LimitExceeded, MalformedInstruction, UnknownOpcode,
    UnsupportedCapability, UnsupportedExtension, UnsupportedExtInstSet, UnsupportedExtInst,
    UnsupportedImageType, UnsafeImageOperation, NoSampling, MissingValidator, SemanticValidationFailed, AllocationFailure };
struct Result { bool eligible=false, semanticallyValidated=false;Reason reason=Reason::InvalidHeader;
    size_t instructionOffset=0;uint32_t opcode=0,imageTypes=0,samplingOperations=0,instructions=0; };
using Validator=bool (*)(const uint32_t*,size_t,void*) noexcept;
inline const char* reason_name(Reason r) noexcept {
    switch(r){
#define SAMPLE_REASON(x) case Reason::x:return #x
    SAMPLE_REASON(Eligible);SAMPLE_REASON(InvalidHeader);SAMPLE_REASON(LimitExceeded);SAMPLE_REASON(MalformedInstruction);
    SAMPLE_REASON(UnknownOpcode);SAMPLE_REASON(UnsupportedCapability);SAMPLE_REASON(UnsupportedExtension);
    SAMPLE_REASON(UnsupportedExtInstSet);SAMPLE_REASON(UnsupportedExtInst);SAMPLE_REASON(UnsupportedImageType);
    SAMPLE_REASON(UnsafeImageOperation);SAMPLE_REASON(NoSampling);SAMPLE_REASON(MissingValidator);
    SAMPLE_REASON(SemanticValidationFailed);SAMPLE_REASON(AllocationFailure);
#undef SAMPLE_REASON
    }return "UnknownReason";
}
inline unsigned min_words(uint32_t op) noexcept {
    switch(op){
@TABLE@
    default:return 0;}
}
inline bool safe_capability(uint32_t cap) noexcept {
    switch(cap){
@CAPS@
    return true;default:return false;}
}
inline bool literal_string(const uint32_t* words,size_t n,std::string& out) {
    if(!n||n>1024)return false;
    const char*p=reinterpret_cast<const char*>(words);const void*end=memchr(p,0,n*4);
    if(!end)return false;size_t size=static_cast<const char*>(end)-p;
    if(size>4095)return false;out.assign(p,size);return true;
}
inline bool safe_extension(const std::string&s) noexcept {
    const char*allowed[]={"SPV_EXT_descriptor_indexing","SPV_KHR_storage_buffer_storage_class",
        "SPV_KHR_physical_storage_buffer","SPV_EXT_demote_to_helper_invocation",
        "SPV_KHR_16bit_storage","SPV_KHR_8bit_storage","SPV_KHR_float_controls",
        "SPV_KHR_no_integer_wrap_decoration","SPV_KHR_shader_draw_parameters"};
    for(auto*p:allowed)if(s==p)return true;return false;
}
inline bool sampling_op(uint32_t op) noexcept {switch(op){@SAMPLE_CASES@ return true;default:return false;}}
// Missing/failed semantic validation never yields true. Production must supply
// a genuine validation contract; an always-true callback is not an integration.
inline Result classify(const uint32_t* words,size_t count,Validator validate=nullptr,void* context=nullptr) noexcept {
    const int savedErrno=errno;struct Restore{int n;~Restore(){errno=n;}}restore{savedErrno};Result r;
    try{
        if(!words||count<5||words[0]!=0x07230203u||words[4]||
           (words[1]&0xff0000ffu)||((words[1]>>16)&255)!=1||((words[1]>>8)&255)>6)return r;
        if(count>4194304||!words[3]||words[3]>1048576){r.reason=Reason::LimitExceeded;return r;}
        std::vector<uint32_t> imports;bool entry=false,memory=false;
        for(size_t at=5;at<count;){
            const uint32_t first=words[at],wc=first>>16,op=first&65535;r.instructionOffset=at;r.opcode=op;
            if(!wc||wc>count-at){r.reason=Reason::MalformedInstruction;return r;}
            unsigned minimum=min_words(op);
            if(!minimum){r.reason=(op>=87&&op<=120)?Reason::UnsafeImageOperation:Reason::UnknownOpcode;return r;}
            if(wc<minimum){r.reason=Reason::MalformedInstruction;return r;}
            ++r.instructions;
            if(op==17){if(wc!=2||!safe_capability(words[at+1])){r.reason=Reason::UnsupportedCapability;return r;}}
            else if(op==10){std::string s;if(!literal_string(words+at+1,wc-1,s)||!safe_extension(s)){r.reason=Reason::UnsupportedExtension;return r;}}
            else if(op==11){std::string s;if(!literal_string(words+at+2,wc-2,s)||s!="GLSL.std.450"||imports.size()>=64){r.reason=Reason::UnsupportedExtInstSet;return r;}imports.push_back(words[at+1]);}
            else if(op==12){bool found=false;for(auto id:imports)found|=id==words[at+3];
                if(!found||words[at+4]<1||words[at+4]>81){r.reason=Reason::UnsupportedExtInst;return r;}}
            else if(op==14){if(wc!=3||(words[at+1]!=0&&words[at+1]!=5348)||words[at+2]!=1){r.reason=Reason::UnsupportedCapability;return r;}memory=true;}
            else if(op==15){if(words[at+1]>5){r.reason=Reason::UnsupportedCapability;return r;}entry=true;}
            else if(op==25){++r.imageTypes;
                // Only ordinary sampled image types; no buffers, subpass,
                // storage/unknown images, MSAA or writable access qualifier.
                if((wc!=9&&wc!=10)||words[at+3]>3||words[at+5]>1||words[at+6]!=0||words[at+7]!=1||words[at+8]!=0||
                   (wc==10&&words[at+9]!=0)){r.reason=Reason::UnsupportedImageType;return r;}}
            else if(sampling_op(op))++r.samplingOperations;
            at+=wc;
        }
        if(!entry||!memory){r.reason=Reason::MalformedInstruction;return r;}
        if(!r.imageTypes||!r.samplingOperations){r.reason=Reason::NoSampling;return r;}
        if(!validate){r.reason=Reason::MissingValidator;return r;}
        if(!validate(words,count,context)){r.reason=Reason::SemanticValidationFailed;return r;}
        r.semanticallyValidated=true;r.eligible=true;r.reason=Reason::Eligible;return r;
    }catch(...){r.reason=Reason::AllocationFailure;return r;}
}
}
'''
header=header.replace('@GRAMMAR@',hashlib.sha256(p.read_bytes()).hexdigest()).replace('@TABLE@',table()).replace('@CAPS@','\n'.join(f'        case {k}: // {v}'for k,v in sorted(safe_caps.items()))).replace('@SAMPLE_CASES@',''.join(f'case {ops[n]["opcode"]}:'for n in image_allow if n not in ['OpSampledImage','OpImage']))
(root/'src/sample_only_image_access.h').write_text(header)
print('generated',len(allowed),'explicit core/image opcodes and',len(safe_caps),'capabilities')
