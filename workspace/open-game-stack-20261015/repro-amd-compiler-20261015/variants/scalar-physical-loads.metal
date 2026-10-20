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


__attribute__((noinline)) float4 isolatedLoadFloat4(uint2 address, uint index)
{ return reinterpret_cast<const device float4*>(as_type<ulong>(address))[index]; }
__attribute__((noinline)) uint4 isolatedLoadUint4(uint2 address, uint index)
{ return reinterpret_cast<const device uint4*>(as_type<ulong>(address))[index]; }


__attribute__((noinline)) float scalarFloat(uint2 address, uint index)
{ return reinterpret_cast<const volatile device float*>(as_type<ulong>(address))[index]; }
__attribute__((noinline)) uint scalarUint(uint2 address, uint index)
{ return reinterpret_cast<const volatile device uint*>(as_type<ulong>(address))[index]; }

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
    uint _35;
    uint _42;
    uint _48;
    uint _60;
    uint _65;
    uint _70;
    uint2 _78;
    uint2 _80;
    uint2 _82;
    uint2 _85;
    float _88;
    float _90;
    float _118;
    float _119;
    float _120;
    float _131;
    float _133;
    float _134;
    float _217;
    float _218;
    float _219;
    float _237;
    bool _238;
    for (;;)
    {
        _35 = registers._m5 + 3u;
        _42 = registers._m5 + 2u;
        _48 = registers._m5 + 1u;
        _60 = registers._m6 + 3u;
        _65 = registers._m6 + 2u;
        _70 = registers._m6 + 1u;
        _78 = registers._m3;
        _80 = registers._m2;
        _82 = registers._m1;
        _85 = registers._m0;
        _88 = gl_FragCoord.x;
        _90 = gl_FragCoord.y;
        float _93 = 1.0 / gl_FragCoord.w;
        out.SV_Target.x = 0.0;
        out.SV_Target.y = 0.0;
        out.SV_Target.z = 0.0;
        out.SV_Target.w = 0.0;
        const device PhysicalPointerFloat4NonWriteCBVArray* _106 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        const device PhysicalPointerFloat4NonWriteCBVArray* _115 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        _118 = scalarFloat(_82, 688u);
        _119 = scalarFloat(_82, 689u);
        _120 = scalarFloat(_82, 690u);
        const device PhysicalPointerFloat4NonWriteCBVArray* _122 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        _131 = (_118 - scalarFloat(_82, 692u)) * 9.9999997473787516355514526367188e-06;
        _133 = (_119 - scalarFloat(_82, 693u)) * 9.9999997473787516355514526367188e-06;
        _134 = (_120 - scalarFloat(_82, 694u)) * 9.9999997473787516355514526367188e-06;
        const device PhysicalPointerFloat4NonWriteCBVArray* _136 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        const device PhysicalPointerFloat4NonWriteCBVArray* _144 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        const device PhysicalPointerFloat4NonWriteCBVArray* _155 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        const device PhysicalPointerFloat4NonWriteCBVArray* _162 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        const device PhysicalPointerFloat4NonWriteCBVArray* _169 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        const device PhysicalPointerFloat4NonWriteCBVArray* _176 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        float _184 = (_93 * 2000000.0) * (((_88 - scalarFloat(_82, 516u)) * scalarFloat(_82, 522u)) + (-0.5));
        float _187 = (_93 * (-2000000.0)) * (((_90 - scalarFloat(_82, 517u)) * scalarFloat(_82, 523u)) + (-0.5));
        const device PhysicalPointerFloat4NonWriteCBVArray* _203 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
        float _209 = (fma(1000000.0, scalarFloat(_82, 200u), fma(_187, scalarFloat(_82, 196u), _184 * scalarFloat(_82, 192u))) + scalarFloat(_82, 204u)) - scalarFloat(_82, 268u);
        float _210 = (fma(1000000.0, scalarFloat(_82, 201u), fma(_187, scalarFloat(_82, 197u), _184 * scalarFloat(_82, 193u))) + scalarFloat(_82, 205u)) - scalarFloat(_82, 269u);
        float _211 = (fma(1000000.0, scalarFloat(_82, 202u), fma(_187, scalarFloat(_82, 198u), _184 * scalarFloat(_82, 194u))) + scalarFloat(_82, 206u)) - scalarFloat(_82, 270u);
        float _216 = rsqrt(dot(float3(_209, _210, _211), float3(_209, _210, _211)));
        _217 = _209 * _216;
        _218 = _210 * _216;
        _219 = _211 * _216;
        float4 _233 = (is_null_texture(_15[registers._m5]) ? float4(0, 0, 0, 0) : _15[registers._m5].sample(_23[registers._m6], float2(scalarFloat(_82, 530u) * _88, scalarFloat(_82, 531u) * _90), level(0.0)));
        _237 = (scalarUint(_85, 5u) != 0u) ? 0.0 : _233.x;
        _238 = _237 == 0.0;
        float _257;
        float _259;
        float _261;
        float _263;
        float _264;
        float _265;
        if (_238)
        {
            const device PhysicalPointerFloat4NonWriteCBVArray* _240 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_78));
            float frontier_phi_3_1_ladder;
            float frontier_phi_3_1_ladder_1;
            float frontier_phi_3_1_ladder_2;
            float frontier_phi_3_1_ladder_3;
            float frontier_phi_3_1_ladder_4;
            float frontier_phi_3_1_ladder_5;
            if (scalarUint(_85, 3u) == 0u)
            {
                frontier_phi_3_1_ladder = 0.0;
                frontier_phi_3_1_ladder_1 = 0.0;
                frontier_phi_3_1_ladder_2 = 0.0;
                frontier_phi_3_1_ladder_3 = scalarFloat(_78, 36u);
                frontier_phi_3_1_ladder_4 = scalarFloat(_78, 37u);
                frontier_phi_3_1_ladder_5 = scalarFloat(_78, 38u);
            }
            else
            {
                const device PhysicalPointerFloat4NonWriteCBVArray* _280 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_80));
                float _287 = dot(float3(_217, _218, _219), float3(_217, _218, _219));
                float _293 = dot(float3(_217, _218, _219), float3(_131, _133, _134)) * 2.0;
                float _295 = scalarFloat(_80, 1u) * scalarFloat(_80, 1u);
                float _301 = (_293 * _293) - ((_287 * 4.0) * (dot(float3(_131, _133, _134), float3(_131, _133, _134)) - _295));
                bool _302 = (isunordered(_301, 0.0) || _301 < 0.0);
                float _511;
                float _514;
                if (_302)
                {
                    _511 = -1.0;
                    _514 = -1.0;
                }
                else
                {
                    float _519 = sqrt(_301);
                    float _524 = _287 * 2.0;
                    _511 = (((-0.0) - _293) - _519) / _524;
                    _514 = (_519 - _293) / _524;
                }
                bool _516 = _511 < 0.0;
                bool _517 = _514 < 0.0;
                float _576;
                if (_516 && _517)
                {
                    _576 = -1.0;
                }
                else
                {
                    float frontier_phi_15_16_ladder;
                    if (_516)
                    {
                        frontier_phi_15_16_ladder = precise::max(0.0, _514);
                    }
                    else
                    {
                        float frontier_phi_15_16_ladder_21_ladder;
                        if (_517)
                        {
                            frontier_phi_15_16_ladder_21_ladder = precise::max(0.0, _511);
                        }
                        else
                        {
                            frontier_phi_15_16_ladder_21_ladder = precise::max(0.0, precise::min(_511, _514));
                        }
                        frontier_phi_15_16_ladder = frontier_phi_15_16_ladder_21_ladder;
                    }
                    _576 = frontier_phi_15_16_ladder;
                }
                float frontier_phi_3_1_ladder_15_ladder;
                float frontier_phi_3_1_ladder_15_ladder_1;
                float frontier_phi_3_1_ladder_15_ladder_2;
                float frontier_phi_3_1_ladder_15_ladder_3;
                float frontier_phi_3_1_ladder_15_ladder_4;
                float frontier_phi_3_1_ladder_15_ladder_5;
                if ((_576 < 0.0) && (scalarFloat(_82, 735u) == 0.0))
                {
                    const device PhysicalPointerFloat4NonWriteCBVArray* _641 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
                    const device PhysicalPointerFloat4NonWriteCBVArray* _648 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
                    float _660 = dot(float3(_217, _218, _219), float3(float3(scalarFloat(_82, 644u), scalarFloat(_82, 645u), scalarFloat(_82, 646u))));
                    float _674;
                    float _676;
                    float _678;
                    if (_660 > scalarFloat(_82, 676u))
                    {
                        bool _782;
                        bool _785;
                        if (_302)
                        {
                            _782 = false;
                            _785 = false;
                        }
                        else
                        {
                            float _788 = sqrt(_301);
                            float _792 = _287 * 2.0;
                            _782 = ((((-0.0) - _293) - _788) / _792) > 0.0;
                            _785 = ((_788 - _293) / _792) > 0.0;
                        }
                        float _795;
                        float _797;
                        float _799;
                        if (_782 || _785)
                        {
                            _795 = 0.0;
                            _797 = 0.0;
                            _799 = 0.0;
                        }
                        else
                        {
                            float _806 = sqrt(((_131 * _131) + (_133 * _133)) + (_134 * _134));
                            float _810 = dot(float3(_217, _218, _219), float3(_131 / _806, _133 / _806, _134 / _806));
                            float _813 = scalarFloat(_80, 2u) * scalarFloat(_80, 2u);
                            float _816 = sqrt(precise::max(0.0, _813 - _295));
                            float _817 = _806 * _806;
                            float _820 = sqrt(precise::max(0.0, _817 - _295));
                            float _829 = scalarFloat(_80, 2u) - _806;
                            float4 _836 = (is_null_texture(_15[_48]) ? float4(0, 0, 0, 0) : _15[_48].sample(_23[_70], float2((precise::max(0.0, sqrt((_817 * ((_810 * _810) + (-1.0))) + _813) - (_810 * _806)) - _829) / ((_816 - _829) + _820), _820 / _816), level(0.0)));
                            _795 = _836.x;
                            _797 = _836.y;
                            _799 = _836.z;
                        }
                        _674 = _795 * scalarFloat(_82, 668u);
                        _676 = _797 * scalarFloat(_82, 669u);
                        _678 = _799 * scalarFloat(_82, 670u);
                    }
                    else
                    {
                        _674 = 0.0;
                        _676 = 0.0;
                        _678 = 0.0;
                    }
                    const device PhysicalPointerFloat4NonWriteCBVArray* _680 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
                    float _690 = (scalarFloat(_82, 736u) != 0.0) ? scalarFloat(_82, 737u) : scalarFloat(_82, 541u);
                    float _699 = (1.0 - scalarFloat(_82, 676u)) * 0.25;
                    float _705 = 1.0 - precise::clamp(((scalarFloat(_82, 676u) - _660) + _699) / _699, 0.0, 1.0);
                    frontier_phi_3_1_ladder_15_ladder = _705 * precise::min(_690 * _674, 64000.0);
                    frontier_phi_3_1_ladder_15_ladder_1 = _705 * precise::min(_690 * _676, 64000.0);
                    frontier_phi_3_1_ladder_15_ladder_2 = _705 * precise::min(_690 * _678, 64000.0);
                    frontier_phi_3_1_ladder_15_ladder_3 = scalarFloat(_78, 36u);
                    frontier_phi_3_1_ladder_15_ladder_4 = scalarFloat(_78, 37u);
                    frontier_phi_3_1_ladder_15_ladder_5 = scalarFloat(_78, 38u);
                }
                else
                {
                    frontier_phi_3_1_ladder_15_ladder = 0.0;
                    frontier_phi_3_1_ladder_15_ladder_1 = 0.0;
                    frontier_phi_3_1_ladder_15_ladder_2 = 0.0;
                    frontier_phi_3_1_ladder_15_ladder_3 = scalarFloat(_78, 36u);
                    frontier_phi_3_1_ladder_15_ladder_4 = scalarFloat(_78, 37u);
                    frontier_phi_3_1_ladder_15_ladder_5 = scalarFloat(_78, 38u);
                }
                frontier_phi_3_1_ladder = frontier_phi_3_1_ladder_15_ladder;
                frontier_phi_3_1_ladder_1 = frontier_phi_3_1_ladder_15_ladder_1;
                frontier_phi_3_1_ladder_2 = frontier_phi_3_1_ladder_15_ladder_2;
                frontier_phi_3_1_ladder_3 = frontier_phi_3_1_ladder_15_ladder_3;
                frontier_phi_3_1_ladder_4 = frontier_phi_3_1_ladder_15_ladder_4;
                frontier_phi_3_1_ladder_5 = frontier_phi_3_1_ladder_15_ladder_5;
            }
            _257 = frontier_phi_3_1_ladder;
            _259 = frontier_phi_3_1_ladder_1;
            _261 = frontier_phi_3_1_ladder_2;
            _263 = frontier_phi_3_1_ladder_3;
            _264 = frontier_phi_3_1_ladder_4;
            _265 = frontier_phi_3_1_ladder_5;
        }
        else
        {
            const device PhysicalPointerFloat4NonWriteCBVArray* _252 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_78));
            if (!(isunordered(scalarFloat(_78, 35u), 0.0) || scalarFloat(_78, 35u) > 0.0))
            {
                out.SV_Target.x = 0.0;
                out.SV_Target.y = 0.0;
                out.SV_Target.z = 0.0;
                out.SV_Target.w = 1.0;
                discard_fragment();
                break;
            }
            _257 = 0.0;
            _259 = 0.0;
            _261 = 0.0;
            _263 = 1.0;
            _264 = 1.0;
            _265 = 1.0;
        }
        float _271 = sqrt(((_131 * _131) + (_133 * _133)) + (_134 * _134));
        const device PhysicalPointerFloat4NonWriteCBVArray* _272 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_80));
        if (_238 && (_271 < (scalarFloat(_80, 2u) + 0.00999999977648258209228515625)))
        {
            const device PhysicalPointerFloat4NonWriteCBVArray* _308 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _315 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _322 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            float _330 = fma(scalarFloat(_82, 698u), _219, fma(scalarFloat(_82, 697u), _218, scalarFloat(_82, 696u) * _217));
            float _333 = fma(scalarFloat(_82, 702u), _219, fma(scalarFloat(_82, 701u), _218, scalarFloat(_82, 700u) * _217));
            float _336 = fma(scalarFloat(_82, 706u), _219, fma(scalarFloat(_82, 705u), _218, scalarFloat(_82, 704u) * _217));
            float _337 = dot(float3(_330, _333, _336), float3(0.0, 0.0, 1.0));
            float _344 = dot(float3(_330, _333, _336), float3(_330, _333, _336));
            float _350 = dot(float3(_330, _333, _336), float3(0.0, 0.0, _271)) * 2.0;
            float _351 = scalarFloat(_80, 1u) * scalarFloat(_80, 1u);
            float _356 = (_350 * _350) - ((_344 * 4.0) * (dot(float3(0.0, 0.0, _271), float3(0.0, 0.0, _271)) - _351));
            float _525;
            float _527;
            if ((isunordered(_356, 0.0) || _356 < 0.0))
            {
                _525 = -1.0;
                _527 = -1.0;
            }
            else
            {
                float _532 = sqrt(_356);
                float _536 = _344 * 2.0;
                _525 = (((-0.0) - _350) - _532) / _536;
                _527 = (_532 - _350) / _536;
            }
            bool _529 = _525 < 0.0;
            bool _530 = _527 < 0.0;
            float _588;
            if (_529 && _530)
            {
                _588 = -1.0;
            }
            else
            {
                float frontier_phi_17_18_ladder;
                if (_529)
                {
                    frontier_phi_17_18_ladder = precise::max(0.0, _527);
                }
                else
                {
                    float frontier_phi_17_18_ladder_25_ladder;
                    if (_530)
                    {
                        frontier_phi_17_18_ladder_25_ladder = precise::max(0.0, _525);
                    }
                    else
                    {
                        frontier_phi_17_18_ladder_25_ladder = precise::max(0.0, precise::min(_525, _527));
                    }
                    frontier_phi_17_18_ladder = frontier_phi_17_18_ladder_25_ladder;
                }
                _588 = frontier_phi_17_18_ladder;
            }
            const device PhysicalPointerFloat4NonWriteCBVArray* _593 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_78));
            float _603 = sqrt((_271 * _271) - _351) / _271;
            float _604 = abs(_603);
            float _605 = _604 * _604;
            float _619 = (((_605 * 0.074261002242565155029296875) + (1.570728778839111328125 - (_604 * 0.212114393711090087890625))) - ((_604 * 0.0187292993068695068359375) * _605)) * sqrt(1.0 - _604);
            float _623 = (_603 >= 0.0) ? _619 : (3.1415927410125732421875 - _619);
            float _624 = 3.1415927410125732421875 - _623;
            float _625 = abs(_337);
            float _626 = _625 * _625;
            float _636 = (((_626 * 0.074261002242565155029296875) + (1.570728778839111328125 - (_625 * 0.212114393711090087890625))) - ((_625 * 0.0187292993068695068359375) * _626)) * sqrt(1.0 - _625);
            float _639 = (_337 >= 0.0) ? _636 : (3.1415927410125732421875 - _636);
            float _707;
            if ((isunordered(_588, 0.0) || _588 < 0.0))
            {
                _707 = (1.0 - sqrt(1.0 - (_639 / _624))) * 0.5;
            }
            else
            {
                _707 = (sqrt((_639 - _624) / _623) * 0.5) + 0.5;
            }
            float _710 = abs((-0.0) - _333);
            float _711 = abs((-0.0) - _330);
            float _714 = precise::min(_711, _710) / precise::max(_711, _710);
            float _715 = _714 * _714;
            float _722 = ((((_715 * 0.087292902171611785888671875) + (-0.3018949925899505615234375)) * _715) + 1.0) * _714;
            float _726 = (_710 > _711) ? (1.57079637050628662109375 - _722) : _722;
            float _729 = (_330 > (-0.0)) ? (3.1415927410125732421875 - _726) : _726;
            float4 _747 = (is_null_texture(_15[_42]) ? float4(0, 0, 0, 0) : _15[_42].sample(_23[_65], float2((((((_333 > (-0.0)) ? ((-0.0) - _729) : _729) + 3.1415927410125732421875) * 0.15915493667125701904296875) + (scalarFloat(_78, 30u) * 0.5)) * (scalarFloat(_78, 28u) / (scalarFloat(_78, 28u) + 1.0)), (scalarFloat(_78, 29u) / (scalarFloat(_78, 29u) + 1.0)) * (_707 + (scalarFloat(_78, 31u) * 0.5))), level(0.0)));
            const device PhysicalPointerFloat4NonWriteCBVArray* _755 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _759 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            float _767 = ((scalarFloat(_82, 736u) != 0.0) ? scalarFloat(_82, 737u) : scalarFloat(_82, 541u)) * scalarFloat(_82, 542u);
            out.SV_Target.x = precise::min(((_747.x * _263) * _767) + _257, 32256.0);
            out.SV_Target.y = precise::min(((_747.y * _264) * _767) + _259, 32256.0);
            out.SV_Target.z = precise::min(((_747.z * _265) * _767) + _261, 32256.0);
            out.SV_Target.w = 1.0;
            break;
        }
        else
        {
            float _358 = precise::max(9.9999999600419720025001879548654e-13, _237);
            const device PhysicalPointerFloat4NonWriteCBVArray* _361 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _369 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _377 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _385 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            float _407 = fma(_358, scalarFloat(_82, 187u), fma(_90, scalarFloat(_82, 183u), scalarFloat(_82, 179u) * _88)) + scalarFloat(_82, 191u);
            const device PhysicalPointerFloat4NonWriteCBVArray* _412 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            float _418 = ((fma(_358, scalarFloat(_82, 184u), fma(_90, scalarFloat(_82, 180u), scalarFloat(_82, 176u) * _88)) + scalarFloat(_82, 188u)) / _407) - scalarFloat(_82, 280u);
            float _419 = ((fma(_358, scalarFloat(_82, 185u), fma(_90, scalarFloat(_82, 181u), scalarFloat(_82, 177u) * _88)) + scalarFloat(_82, 189u)) / _407) - scalarFloat(_82, 281u);
            float _420 = ((fma(_358, scalarFloat(_82, 186u), fma(_90, scalarFloat(_82, 182u), scalarFloat(_82, 178u) * _88)) + scalarFloat(_82, 190u)) / _407) - scalarFloat(_82, 282u);
            const device PhysicalPointerFloat4NonWriteCBVArray* _422 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _428 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _434 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _441 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            float _458 = fma(_420, scalarFloat(_82, 27u), fma(_419, scalarFloat(_82, 23u), _418 * scalarFloat(_82, 19u))) + scalarFloat(_82, 31u);
            const device PhysicalPointerFloat4NonWriteCBVArray* _460 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            const device PhysicalPointerFloat4NonWriteCBVArray* _465 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_82));
            float _473 = ((scalarFloat(_82, 736u) != 0.0) ? scalarFloat(_82, 737u) : scalarFloat(_82, 541u)) * scalarFloat(_82, 542u);
            const device PhysicalPointerFloat4NonWriteCBVArray* _474 = reinterpret_cast<const device PhysicalPointerFloat4NonWriteCBVArray*>(as_type<ulong>(_78));
            float _492 = (_418 - _118) * 9.9999997473787516355514526367188e-06;
            float _494 = (_419 - _119) * 9.9999997473787516355514526367188e-06;
            float _496 = (_420 - _120) * 9.9999997473787516355514526367188e-06;
            float _507 = sqrt((scalarFloat(_78, 13u) * scalarFloat(_78, 15u)) * precise::max(0.0, sqrt(((_492 * _492) + (_494 * _494)) + (_496 * _496)) - scalarFloat(_85, 0u)));
            float _508 = _507 * scalarFloat(_78, 12u);
            float _540;
            if (_508 < 0.707106769084930419921875)
            {
                _540 = precise::clamp((_508 * _508) * 2.0, 0.0, 1.0);
            }
            else
            {
                _540 = 1.0;
            }
            float4 _543 = (is_null_texture(_19[_35]) ? float4(0, 0, 0, 0) : _19[_35].sample(_23[_60], float3((((fma(_420, scalarFloat(_82, 24u), fma(_419, scalarFloat(_82, 20u), _418 * scalarFloat(_82, 16u))) + scalarFloat(_82, 28u)) / _458) * 0.5) + 0.5, 0.5 - (((fma(_420, scalarFloat(_82, 25u), fma(_419, scalarFloat(_82, 21u), _418 * scalarFloat(_82, 17u))) + scalarFloat(_82, 29u)) / _458) * 0.5), _507), level(0.0)));
            out.SV_Target.x = precise::min((((_473 * _263) * _540) * _543.x) + _257, 32256.0);
            out.SV_Target.y = precise::min((((_473 * _264) * _540) * _543.y) + _259, 32256.0);
            out.SV_Target.z = precise::min((((_473 * _265) * _540) * _543.z) + _261, 32256.0);
            out.SV_Target.w = dot(float3(1.0 - ((1.0 - _543.w) * _540)), float3(0.3333333432674407958984375));
            break;
        }
    }
    return out;
}

