#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T>
struct spvDescriptor
{
    T value;
};

template<typename T>
struct spvDescriptorArray
{
    spvDescriptorArray(const device spvDescriptor<T>* ptr_) : ptr(&ptr_->value) {}
    spvDescriptorArray(const device void *ptr_) : spvDescriptorArray(static_cast<const device spvDescriptor<T>*>(ptr_)) {}
    const device T& operator [] (size_t i) const { return ptr[i]; }
    const device T* ptr;
};

struct PhysicalPointerFloat4NonWriteCBVArray;
struct PhysicalPointerUint4NonWriteCBVArray;

struct RootConstants
{
    uint2 _m0;
    uint2 _m1;
    uint2 _m2;
    uint2 _m3;
    uint2 _m4;
    uint _m5;
    uint _m6;
    uint _m7;
    uint _m8;
    uint _m9;
};

struct PhysicalPointerFloat4NonWriteCBVArray
{
    float4 value[4096];
};

struct PhysicalPointerUint4NonWriteCBVArray
{
    uint4 value[4096];
};

struct spvDescriptorSetBuffer0
{
    spvDescriptor<sampler> m_23 [[id(0)]][1] /* unsized array hack */;
};

struct spvDescriptorSetBuffer3
{
    spvDescriptor<texture2d<float>> m_15 [[id(0)]][1] /* unsized array hack */;
    // Overlapping binding: spvDescriptor<texture3d<float>> m_19 [[id(0)]][1] /* unsized array hack */;
};

struct main0_out
{
    float4 SV_Target [[color(0)]];
};

fragment main0_out main0(const device spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], const device spvDescriptorSetBuffer3& spvDescriptorSet3 [[buffer(3)]], constant RootConstants& registers [[buffer(8)]], float4 gl_FragCoord [[position]])
{
    spvDescriptorArray<texture2d<float>> _15 {spvDescriptorSet3.m_15};
    spvDescriptorArray<texture3d<float>> _19 {reinterpret_cast<const device spvDescriptor<texture3d<float>>*>(&spvDescriptorSet3.m_15)};
    spvDescriptorArray<sampler> _23 {spvDescriptorSet0.m_23};

    main0_out out = {};
    out.SV_Target = is_null_texture(_15[registers._m5]) ? float4(0) : _15[registers._m5].sample(_23[registers._m6], float2(0.5), level(0.0));
    return out;
}
