from pathlib import Path
import subprocess,json
out=Path(__file__).resolve().parent/'fixtures';out.mkdir(exist_ok=True)
base='''OpCapability Shader
{caps}
{imports}
OpMemoryModel {memory} GLSL450
OpEntryPoint Fragment %main "main" %out
OpExecutionMode %main OriginUpperLeft
OpDecorate %out Location 0
OpDecorate %tex DescriptorSet 0
OpDecorate %tex Binding 0
OpDecorate %samp DescriptorSet 0
OpDecorate %samp Binding 1
{annotations}
%void = OpTypeVoid
%fn = OpTypeFunction %void
%float = OpTypeFloat 32
%int = OpTypeInt 32 1
%uint = OpTypeInt 32 0
%v2 = OpTypeVector %float 2
%iv2 = OpTypeVector %int 2
%v4 = OpTypeVector %float 4
%image = OpTypeImage %float {dim} 0 0 0 {sampled} {format}
%sampler = OpTypeSampler
%combined = OpTypeSampledImage %image
%ptrImage = OpTypePointer UniformConstant %image
%ptrSampler = OpTypePointer UniformConstant %sampler
%ptrOutput = OpTypePointer Output %v4
%tex = OpVariable %ptrImage UniformConstant
%samp = OpVariable %ptrSampler UniformConstant
%out = OpVariable %ptrOutput Output
%zero = OpConstant %float 0
%one = OpConstant %float 1
%i0 = OpConstant %int 0
%u0 = OpConstant %uint 0
%u1 = OpConstant %uint 1
%uv = OpConstantComposite %v2 %zero %zero
%coord = OpConstantComposite %iv2 %i0 %i0
%fixed = OpConstantComposite %v4 %one %one %one %one
{decls}
%main = OpFunction %void None %fn
%entry = OpLabel
%im = OpLoad %image %tex
%sm = OpLoad %sampler %samp
%ss = OpSampledImage %combined %im %sm
{before}
{access}
OpStore %out %color
OpReturn
OpFunctionEnd
{after}
'''
rows=[]
def add(name,access,eligible,**args):
 p=dict(memory='Logical',caps='',imports='',annotations='',dim='2D',sampled='1',format='Unknown',decls='',before='',after='');p.update(args)
 # Storage images cannot form an OpSampledImage, so remove that instruction
 # (and the unused combined image type) in those authored cases.
 asm=base.format(access=access,**p)
 if p['sampled']=='2':asm=asm.replace('%ss = OpSampledImage %combined %im %sm\n','').replace('%combined = OpTypeSampledImage %image\n','')
 f=out/(name+'.spvasm');f.write_text(asm)
 a=subprocess.run(['spirv-as','--target-env','spv1.3',str(f),'-o',str(out/(name+'.spv'))],capture_output=True,text=True)
 if a.returncode:raise RuntimeError(name+': '+a.stderr)
 v=subprocess.run(['spirv-val','--target-env','vulkan1.3',str(out/(name+'.spv'))],capture_output=True,text=True)
 rows.append({'name':name,'eligible':eligible,'assemblerExit':a.returncode,'validatorExit':v.returncode,'validationMessage':v.stderr})
 if v.returncode:raise RuntimeError(name+': '+v.stderr)
add('safe_sample','%color = OpImageSampleImplicitLod %v4 %ss %uv',True)
add('safe_explicit','%color = OpImageSampleExplicitLod %v4 %ss %uv Lod %zero',True)
add('safe_gather','%color = OpImageGather %v4 %ss %uv %i0',True)
add('safe_glsl_math','%color = OpImageSampleImplicitLod %v4 %ss %uv',True,imports='%glsl = OpExtInstImport "GLSL.std.450"',before='%abs = OpExtInst %float %glsl FAbs %zero')
add('unsafe_fetch','%color = OpImageFetch %v4 %im %coord Lod %i0',False)
add('unsafe_read','%color = OpImageRead %v4 %im %coord',False,sampled='2',format='Rgba32f')
add('unsafe_write','OpImageWrite %im %coord %fixed\n%color = OpCopyObject %v4 %fixed',False,sampled='2',format='Rgba32f')
add('unsafe_unused_function','%color = OpImageSampleImplicitLod %v4 %ss %uv',False,after='''%unused = OpFunction %void None %fn
%other = OpLabel
%otherImage = OpLoad %image %tex
%otherColor = OpImageFetch %v4 %otherImage %coord Lod %i0
OpReturn
OpFunctionEnd''')
add('unsafe_buffer_atomic','%color = OpImageSampleImplicitLod %v4 %ss %uv',False,annotations='OpDecorate %counterStruct Block\nOpMemberDecorate %counterStruct 0 Offset 0\nOpDecorate %counter DescriptorSet 0\nOpDecorate %counter Binding 2',decls='''%counterStruct = OpTypeStruct %uint
%ptrCounter = OpTypePointer StorageBuffer %counterStruct
%ptrCounterWord = OpTypePointer StorageBuffer %uint
%counter = OpVariable %ptrCounter StorageBuffer''',before='''%atomicPtr = OpAccessChain %ptrCounterWord %counter %u0
%old = OpAtomicIAdd %uint %atomicPtr %u1 %u0 %u1''')
add('unsafe_unknown_extension','%color = OpImageSampleImplicitLod %v4 %ss %uv',False,imports='OpExtension "SPV_KHR_non_semantic_info"')
add('unsafe_texel_buffer_type','%color = OpImageSampleImplicitLod %v4 %ss %uv',False,caps='OpCapability SampledBuffer',decls='%unusedBufferImage = OpTypeImage %float Buffer 0 0 0 1 Unknown')
add('unsafe_input_attachment_type','%color = OpImageSampleImplicitLod %v4 %ss %uv',False,caps='OpCapability InputAttachment',decls='%unusedAttachment = OpTypeImage %float SubpassData 0 0 0 2 Unknown')
add('safe_physical_address','%color = OpImageSampleImplicitLod %v4 %ss %uv',True,caps='OpCapability PhysicalStorageBufferAddresses\nOpCapability Int64',imports='OpExtension "SPV_KHR_physical_storage_buffer"',memory='PhysicalStorageBuffer64',decls='%ulong = OpTypeInt 64 0\n%addr0 = OpConstant %ulong 0\n%physPtr = OpTypePointer PhysicalStorageBuffer %uint',before='%pointer = OpConvertUToPtr %physPtr %addr0')
add('safe_demote','%color = OpImageSampleImplicitLod %v4 %ss %uv',True,caps='OpCapability DemoteToHelperInvocation',imports='OpExtension "SPV_EXT_demote_to_helper_invocation"',before='OpDemoteToHelperInvocation')
add('unsafe_image_query','%color = OpImageSampleImplicitLod %v4 %ss %uv',False,caps='OpCapability ImageQuery',before='%size = OpImageQuerySizeLod %iv2 %im %i0')
(out.parent/'fixtures.json').write_text(json.dumps(rows,indent=2)+'\n');print('Assembled and semantic-validated',len(rows),'authored fixtures')
