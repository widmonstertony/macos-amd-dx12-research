// CPU-only prototype. Not integrated with MoltenVK, the binder or cache formats.
// Whitelist derived from SPIRV-Headers grammar SHA256 3988d2ba1d9b447092185a8733aef1c25b6c2951e8ba1f25ac8330621d58d144.
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
        case 0: return 1; // OpNop
        case 1: return 3; // OpUndef
        case 2: return 2; // OpSourceContinued
        case 3: return 3; // OpSource
        case 4: return 2; // OpSourceExtension
        case 5: return 3; // OpName
        case 6: return 4; // OpMemberName
        case 7: return 3; // OpString
        case 8: return 4; // OpLine
        case 10: return 2; // OpExtension
        case 11: return 3; // OpExtInstImport
        case 12: return 5; // OpExtInst
        case 14: return 3; // OpMemoryModel
        case 15: return 4; // OpEntryPoint
        case 16: return 3; // OpExecutionMode
        case 17: return 2; // OpCapability
        case 19: return 2; // OpTypeVoid
        case 20: return 2; // OpTypeBool
        case 21: return 4; // OpTypeInt
        case 22: return 3; // OpTypeFloat
        case 23: return 4; // OpTypeVector
        case 24: return 4; // OpTypeMatrix
        case 25: return 9; // OpTypeImage
        case 26: return 2; // OpTypeSampler
        case 27: return 3; // OpTypeSampledImage
        case 28: return 4; // OpTypeArray
        case 29: return 3; // OpTypeRuntimeArray
        case 30: return 2; // OpTypeStruct
        case 32: return 4; // OpTypePointer
        case 33: return 3; // OpTypeFunction
        case 41: return 3; // OpConstantTrue
        case 42: return 3; // OpConstantFalse
        case 43: return 4; // OpConstant
        case 44: return 3; // OpConstantComposite
        case 45: return 6; // OpConstantSampler
        case 46: return 3; // OpConstantNull
        case 48: return 3; // OpSpecConstantTrue
        case 49: return 3; // OpSpecConstantFalse
        case 50: return 4; // OpSpecConstant
        case 51: return 3; // OpSpecConstantComposite
        case 52: return 4; // OpSpecConstantOp
        case 54: return 5; // OpFunction
        case 55: return 3; // OpFunctionParameter
        case 56: return 1; // OpFunctionEnd
        case 57: return 4; // OpFunctionCall
        case 59: return 4; // OpVariable
        case 61: return 4; // OpLoad
        case 62: return 3; // OpStore
        case 63: return 3; // OpCopyMemory
        case 64: return 4; // OpCopyMemorySized
        case 65: return 4; // OpAccessChain
        case 66: return 4; // OpInBoundsAccessChain
        case 67: return 5; // OpPtrAccessChain
        case 68: return 5; // OpArrayLength
        case 69: return 4; // OpGenericPtrMemSemantics
        case 70: return 5; // OpInBoundsPtrAccessChain
        case 71: return 3; // OpDecorate
        case 72: return 4; // OpMemberDecorate
        case 73: return 2; // OpDecorationGroup
        case 74: return 2; // OpGroupDecorate
        case 75: return 2; // OpGroupMemberDecorate
        case 77: return 5; // OpVectorExtractDynamic
        case 78: return 6; // OpVectorInsertDynamic
        case 79: return 5; // OpVectorShuffle
        case 80: return 3; // OpCompositeConstruct
        case 81: return 4; // OpCompositeExtract
        case 82: return 5; // OpCompositeInsert
        case 83: return 4; // OpCopyObject
        case 84: return 4; // OpTranspose
        case 86: return 5; // OpSampledImage
        case 87: return 5; // OpImageSampleImplicitLod
        case 88: return 6; // OpImageSampleExplicitLod
        case 89: return 6; // OpImageSampleDrefImplicitLod
        case 90: return 7; // OpImageSampleDrefExplicitLod
        case 91: return 5; // OpImageSampleProjImplicitLod
        case 92: return 6; // OpImageSampleProjExplicitLod
        case 93: return 6; // OpImageSampleProjDrefImplicitLod
        case 94: return 7; // OpImageSampleProjDrefExplicitLod
        case 96: return 6; // OpImageGather
        case 97: return 6; // OpImageDrefGather
        case 100: return 4; // OpImage
        case 109: return 4; // OpConvertFToU
        case 110: return 4; // OpConvertFToS
        case 111: return 4; // OpConvertSToF
        case 112: return 4; // OpConvertUToF
        case 113: return 4; // OpUConvert
        case 114: return 4; // OpSConvert
        case 115: return 4; // OpFConvert
        case 116: return 4; // OpQuantizeToF16
        case 117: return 4; // OpConvertPtrToU
        case 118: return 4; // OpSatConvertSToU
        case 119: return 4; // OpSatConvertUToS
        case 120: return 4; // OpConvertUToPtr
        case 121: return 4; // OpPtrCastToGeneric
        case 122: return 4; // OpGenericCastToPtr
        case 123: return 5; // OpGenericCastToPtrExplicit
        case 124: return 4; // OpBitcast
        case 126: return 4; // OpSNegate
        case 127: return 4; // OpFNegate
        case 128: return 5; // OpIAdd
        case 129: return 5; // OpFAdd
        case 130: return 5; // OpISub
        case 131: return 5; // OpFSub
        case 132: return 5; // OpIMul
        case 133: return 5; // OpFMul
        case 134: return 5; // OpUDiv
        case 135: return 5; // OpSDiv
        case 136: return 5; // OpFDiv
        case 137: return 5; // OpUMod
        case 138: return 5; // OpSRem
        case 139: return 5; // OpSMod
        case 140: return 5; // OpFRem
        case 141: return 5; // OpFMod
        case 142: return 5; // OpVectorTimesScalar
        case 143: return 5; // OpMatrixTimesScalar
        case 144: return 5; // OpVectorTimesMatrix
        case 145: return 5; // OpMatrixTimesVector
        case 146: return 5; // OpMatrixTimesMatrix
        case 147: return 5; // OpOuterProduct
        case 148: return 5; // OpDot
        case 149: return 5; // OpIAddCarry
        case 150: return 5; // OpISubBorrow
        case 151: return 5; // OpUMulExtended
        case 152: return 5; // OpSMulExtended
        case 154: return 4; // OpAny
        case 155: return 4; // OpAll
        case 156: return 4; // OpIsNan
        case 157: return 4; // OpIsInf
        case 158: return 4; // OpIsFinite
        case 159: return 4; // OpIsNormal
        case 160: return 4; // OpSignBitSet
        case 161: return 5; // OpLessOrGreater
        case 162: return 5; // OpOrdered
        case 163: return 5; // OpUnordered
        case 164: return 5; // OpLogicalEqual
        case 165: return 5; // OpLogicalNotEqual
        case 166: return 5; // OpLogicalOr
        case 167: return 5; // OpLogicalAnd
        case 168: return 4; // OpLogicalNot
        case 169: return 6; // OpSelect
        case 170: return 5; // OpIEqual
        case 171: return 5; // OpINotEqual
        case 172: return 5; // OpUGreaterThan
        case 173: return 5; // OpSGreaterThan
        case 174: return 5; // OpUGreaterThanEqual
        case 175: return 5; // OpSGreaterThanEqual
        case 176: return 5; // OpULessThan
        case 177: return 5; // OpSLessThan
        case 178: return 5; // OpULessThanEqual
        case 179: return 5; // OpSLessThanEqual
        case 180: return 5; // OpFOrdEqual
        case 181: return 5; // OpFUnordEqual
        case 182: return 5; // OpFOrdNotEqual
        case 183: return 5; // OpFUnordNotEqual
        case 184: return 5; // OpFOrdLessThan
        case 185: return 5; // OpFUnordLessThan
        case 186: return 5; // OpFOrdGreaterThan
        case 187: return 5; // OpFUnordGreaterThan
        case 188: return 5; // OpFOrdLessThanEqual
        case 189: return 5; // OpFUnordLessThanEqual
        case 190: return 5; // OpFOrdGreaterThanEqual
        case 191: return 5; // OpFUnordGreaterThanEqual
        case 194: return 5; // OpShiftRightLogical
        case 195: return 5; // OpShiftRightArithmetic
        case 196: return 5; // OpShiftLeftLogical
        case 197: return 5; // OpBitwiseOr
        case 198: return 5; // OpBitwiseXor
        case 199: return 5; // OpBitwiseAnd
        case 200: return 4; // OpNot
        case 201: return 7; // OpBitFieldInsert
        case 202: return 6; // OpBitFieldSExtract
        case 203: return 6; // OpBitFieldUExtract
        case 204: return 4; // OpBitReverse
        case 205: return 4; // OpBitCount
        case 207: return 4; // OpDPdx
        case 208: return 4; // OpDPdy
        case 209: return 4; // OpFwidth
        case 210: return 4; // OpDPdxFine
        case 211: return 4; // OpDPdyFine
        case 212: return 4; // OpFwidthFine
        case 213: return 4; // OpDPdxCoarse
        case 214: return 4; // OpDPdyCoarse
        case 215: return 4; // OpFwidthCoarse
        case 218: return 1; // OpEmitVertex
        case 219: return 1; // OpEndPrimitive
        case 220: return 2; // OpEmitStreamVertex
        case 221: return 2; // OpEndStreamPrimitive
        case 224: return 4; // OpControlBarrier
        case 225: return 3; // OpMemoryBarrier
        case 245: return 3; // OpPhi
        case 246: return 4; // OpLoopMerge
        case 247: return 3; // OpSelectionMerge
        case 248: return 2; // OpLabel
        case 249: return 2; // OpBranch
        case 250: return 4; // OpBranchConditional
        case 251: return 3; // OpSwitch
        case 252: return 1; // OpKill
        case 253: return 1; // OpReturn
        case 254: return 2; // OpReturnValue
        case 255: return 1; // OpUnreachable
        case 256: return 3; // OpLifetimeStart
        case 257: return 3; // OpLifetimeStop
        case 259: return 9; // OpGroupAsyncCopy
        case 260: return 4; // OpGroupWaitEvents
        case 261: return 5; // OpGroupAll
        case 262: return 5; // OpGroupAny
        case 263: return 6; // OpGroupBroadcast
        case 264: return 6; // OpGroupIAdd
        case 265: return 6; // OpGroupFAdd
        case 266: return 6; // OpGroupFMin
        case 267: return 6; // OpGroupUMin
        case 268: return 6; // OpGroupSMin
        case 269: return 6; // OpGroupFMax
        case 270: return 6; // OpGroupUMax
        case 271: return 6; // OpGroupSMax
        case 317: return 1; // OpNoLine
        case 321: return 4; // OpSizeOf
        case 328: return 4; // OpNamedBarrierInitialize
        case 329: return 4; // OpMemoryNamedBarrier
        case 330: return 2; // OpModuleProcessed
        case 331: return 3; // OpExecutionModeId
        case 332: return 3; // OpDecorateId
        case 333: return 4; // OpGroupNonUniformElect
        case 334: return 5; // OpGroupNonUniformAll
        case 335: return 5; // OpGroupNonUniformAny
        case 336: return 5; // OpGroupNonUniformAllEqual
        case 337: return 6; // OpGroupNonUniformBroadcast
        case 338: return 5; // OpGroupNonUniformBroadcastFirst
        case 339: return 5; // OpGroupNonUniformBallot
        case 340: return 5; // OpGroupNonUniformInverseBallot
        case 341: return 6; // OpGroupNonUniformBallotBitExtract
        case 342: return 6; // OpGroupNonUniformBallotBitCount
        case 343: return 5; // OpGroupNonUniformBallotFindLSB
        case 344: return 5; // OpGroupNonUniformBallotFindMSB
        case 345: return 6; // OpGroupNonUniformShuffle
        case 346: return 6; // OpGroupNonUniformShuffleXor
        case 347: return 6; // OpGroupNonUniformShuffleUp
        case 348: return 6; // OpGroupNonUniformShuffleDown
        case 349: return 6; // OpGroupNonUniformIAdd
        case 350: return 6; // OpGroupNonUniformFAdd
        case 351: return 6; // OpGroupNonUniformIMul
        case 352: return 6; // OpGroupNonUniformFMul
        case 353: return 6; // OpGroupNonUniformSMin
        case 354: return 6; // OpGroupNonUniformUMin
        case 355: return 6; // OpGroupNonUniformFMin
        case 356: return 6; // OpGroupNonUniformSMax
        case 357: return 6; // OpGroupNonUniformUMax
        case 358: return 6; // OpGroupNonUniformFMax
        case 359: return 6; // OpGroupNonUniformBitwiseAnd
        case 360: return 6; // OpGroupNonUniformBitwiseOr
        case 361: return 6; // OpGroupNonUniformBitwiseXor
        case 362: return 6; // OpGroupNonUniformLogicalAnd
        case 363: return 6; // OpGroupNonUniformLogicalOr
        case 364: return 6; // OpGroupNonUniformLogicalXor
        case 365: return 6; // OpGroupNonUniformQuadBroadcast
        case 366: return 6; // OpGroupNonUniformQuadSwap
        case 5380: return 1; // OpDemoteToHelperInvocation
        case 5381: return 3; // OpIsHelperInvocationEXT
    default:return 0;}
}
inline bool safe_capability(uint32_t cap) noexcept {
    switch(cap){
        case 0: // Matrix
        case 1: // Shader
        case 2: // Geometry
        case 3: // Tessellation
        case 9: // Float16
        case 10: // Float64
        case 11: // Int64
        case 22: // Int16
        case 23: // TessellationPointSize
        case 24: // GeometryPointSize
        case 25: // ImageGatherExtended
        case 28: // UniformBufferArrayDynamicIndexing
        case 29: // SampledImageArrayDynamicIndexing
        case 30: // StorageBufferArrayDynamicIndexing
        case 32: // ClipDistance
        case 33: // CullDistance
        case 34: // ImageCubeArray
        case 35: // SampleRateShading
        case 39: // Int8
        case 42: // MinLod
        case 43: // Sampled1D
        case 45: // SampledCubeArray
        case 46: // SampledBuffer
        case 47: // ImageBuffer
        case 50: // ImageQuery
        case 51: // DerivativeControl
        case 56: // StorageImageWriteWithoutFormat
        case 57: // MultiViewport
        case 61: // GroupNonUniform
        case 62: // GroupNonUniformVote
        case 63: // GroupNonUniformArithmetic
        case 64: // GroupNonUniformBallot
        case 65: // GroupNonUniformShuffle
        case 66: // GroupNonUniformShuffleRelative
        case 67: // GroupNonUniformClustered
        case 68: // GroupNonUniformQuad
        case 4427: // DrawParameters
        case 4433: // StorageBuffer16BitAccess
        case 4434: // UniformAndStorageBuffer16BitAccess
        case 4435: // StoragePushConstant16
        case 4436: // StorageInputOutput16
        case 4448: // StorageBuffer8BitAccess
        case 4449: // UniformAndStorageBuffer8BitAccess
        case 4450: // StoragePushConstant8
        case 5301: // ShaderNonUniform
        case 5302: // RuntimeDescriptorArray
        case 5306: // UniformBufferArrayNonUniformIndexing
        case 5307: // SampledImageArrayNonUniformIndexing
        case 5308: // StorageBufferArrayNonUniformIndexing
        case 5347: // PhysicalStorageBufferAddresses
        case 5379: // DemoteToHelperInvocation
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
inline bool sampling_op(uint32_t op) noexcept {switch(op){case 87:case 88:case 89:case 90:case 91:case 92:case 93:case 94:case 96:case 97: return true;default:return false;}}
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
