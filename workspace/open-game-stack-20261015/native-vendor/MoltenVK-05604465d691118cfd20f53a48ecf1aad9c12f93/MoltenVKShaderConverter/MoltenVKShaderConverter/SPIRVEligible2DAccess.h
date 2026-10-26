// Optional eligible-2D access proof; emitted MSL and cache formats stay unchanged.
#pragma once
#include "SPIRVSampleOnlyAccess.h"
#include <cctype>
#include <map>
#include <memory>
#include <set>

namespace eligible_2d_access {
namespace legacy = mvk::sample_only_image_access;

// Preserve the legacy structural whitelist and its limits, adding only these
// read/query instructions. Their resolved operands are checked during emission.
inline bool structure(const std::vector<uint32_t>& w) {
    if (w.size() < 5 || w.size() > 4194304 || w[0] != 0x07230203u || w[4] ||
        (w[1] & 0xff0000ffu) || ((w[1] >> 16) & 255) != 1 || ((w[1] >> 8) & 255) > 6 ||
        !w[3] || w[3] > 1048576) return false;
    std::set<uint32_t> imports;
    bool memory = false, entry = false;
    for (size_t at = 5; at < w.size();) {
        const uint32_t wc = w[at] >> 16, op = w[at] & 65535;
        if (!wc || wc > w.size() - at) return false;
        unsigned minimum = legacy::min_words(op);
        if (op == 95 || op == 98 || op == 103) minimum = 5;
        if (op == 104 || op == 106) minimum = 4;
        if (!minimum || wc < minimum) return false;
        if (op == 17 && (wc != 2 || !legacy::safe_capability(w[at + 1]))) return false;
        if (op == 10) {
            std::string s;
            if (!legacy::literal_string(w.data() + at + 1, wc - 1, s) || !legacy::safe_extension(s)) return false;
        }
        if (op == 11) {
            std::string s;
            if (!legacy::literal_string(w.data() + at + 2, wc - 2, s) || s != "GLSL.std.450" || imports.size() >= 64) return false;
            imports.insert(w[at + 1]);
        }
        if (op == 12 && (!imports.count(w[at + 3]) || w[at + 4] < 1 || w[at + 4] > 81)) return false;
        if (op == 14) {
            if (wc != 3 || (w[at + 1] != 0 && w[at + 1] != 5348) || w[at + 2] != 1) return false;
            memory = true;
        }
        if (op == 15) { if (w[at + 1] > 5) return false; entry = true; }
        if (op == 25) {
            // No 1D, Rect, SubpassData, MSAA, storage/unknown or writable images.
            const auto dim = w[at + 3];
            if ((wc != 9 && wc != 10) || (dim != 1 && dim != 2 && dim != 3 && dim != 5) ||
                w[at + 4] > 2 || w[at + 5] > 1 || w[at + 6] || w[at + 7] != 1 || w[at + 8] ||
                (dim == 5 && w[at + 5]) || (wc == 10 && w[at + 9])) return false;
        }
        at += wc;
    }
    // Vacuously safe stages with no 2D accesses are useful when another stage
    // samples 2D. This is an access contract, not proof that a 2D resource exists.
    return memory && entry;
}

enum class Shape { TwoD, ThreeD, Buffer, Cube };
inline bool identifier(const std::string& s) {
    if (s.empty() || !(std::isalpha(static_cast<unsigned char>(s[0])) || s[0] == '_')) return false;
    for (unsigned char c : s) if (!(std::isalnum(c) || c == '_')) return false;
    return true;
}
inline bool shape(const std::string& s, Shape& out) {
    if (s == "texture2d" || s == "texture2d_array" || s == "depth2d" || s == "depth2d_array") out = Shape::TwoD;
    else if (s == "texture3d") out = Shape::ThreeD;
    else if (s == "texture_buffer") out = Shape::Buffer;
    else if (s == "texturecube" || s == "texturecube_array" || s == "depthcube" || s == "depthcube_array") out = Shape::Cube;
    else return false;
    return true;
}

// A bounded grammar for emitted MSL, not a C++ parser. Unsupported syntax,
// ambiguous names, texture escapes, generic image helpers and macros fail.
// The exact source is tokenized; .read text is never removed or rewritten.
inline bool finalMSL(const std::string& source) {
    if (source.empty() || source.size() > 64u * 1024u * 1024u) return false;
    std::vector<std::string> t;
    for (size_t p = 0; p < source.size();) {
        const unsigned char c = source[p];
        if (std::isspace(c)) { ++p; continue; }
        if (c == '#') {
            const auto end = source.find('\n', p);
            const std::string line = source.substr(p, end == std::string::npos ? end : end - p);
            if (line != "#include <metal_stdlib>" && line != "#include <simd/simd.h>" &&
                line.rfind("#pragma clang diagnostic ignored \"-W", 0) != 0) return false;
            p = end == std::string::npos ? source.size() : end + 1; continue;
        }
        if (c == '/' && p + 1 < source.size() && source[p + 1] == '/') {
            const auto end = source.find('\n', p + 2); p = end == std::string::npos ? source.size() : end + 1; continue;
        }
        if (c == '/' && p + 1 < source.size() && source[p + 1] == '*') {
            const auto end = source.find("*/", p + 2); if (end == std::string::npos) return false;
            p = end + 2; continue;
        }
        if (c == '"' || c == '\'') {
            const char quote = c; bool closed = false;
            for (++p; p < source.size(); ++p) {
                if (source[p] == '\\') { ++p; continue; }
                if (source[p] == quote) { ++p; closed = true; break; }
            }
            if (!closed) return false;
            t.emplace_back("<literal>"); continue;
        }
        if (std::isalnum(c) || c == '_') {
            const size_t begin = p++;
            while (p < source.size() && (std::isalnum(static_cast<unsigned char>(source[p])) || source[p] == '_')) ++p;
            t.push_back(source.substr(begin, p - begin)); continue;
        }
        if (c == '-' && p + 1 < source.size() && source[p + 1] == '>') { t.emplace_back("->"); p += 2; continue; }
        t.emplace_back(1, c); ++p;
    }
    if (t.size() > 8388608) return false;
    // Associate fields with their declaring struct. Field names are never
    // flattened: A.value being 3D cannot authorize B.value when B.value is 2D.
    std::vector<std::string> owner(t.size());
    std::set<std::string> structs;
    for (size_t i = 0; i + 2 < t.size(); ++i) {
        if (t[i] != "struct" || !identifier(t[i + 1]) || t[i + 2] != "{") continue;
        const auto name = t[i + 1]; int depth = 1; size_t end = i + 3;
        while (end < t.size() && depth) {
            if (t[end] == "{") ++depth;
            if (t[end] == "}") --depth;
            if (depth) owner[end] = name;
            ++end;
        }
        if (depth || !structs.insert(name).second) return false;
        i = end - 1;
    }
    std::map<std::string, Shape> names;
    std::map<std::string, std::map<std::string, Shape>> fields;
    std::set<std::string> imageFieldNames;
    struct AliasRoot { size_t base, field; Shape declared; bool cast; };
    std::vector<AliasRoot> aliases;
    std::vector<bool> ignored(t.size(), false), acceptedUse(t.size(), false);
    for (size_t i = 0; i < t.size(); ++i) {
        if (ignored[i]) continue;
        Shape kind;
        if (!shape(t[i], kind)) {
            if (t[i].rfind("texture", 0) == 0 || t[i].rfind("depth", 0) == 0) {
                if (i + 1 < t.size() && t[i + 1] == "<") return false;
            }
            continue;
        }
        size_t close = i + 1;
        if (close >= t.size() || t[close++] != "<") return false;
        if (close >= t.size() || (t[close] != "float" && t[close] != "half" && t[close] != "int" && t[close] != "uint")) return false;
        ++close;
        bool readAccess = false;
        if (close < t.size() && t[close] == ",") {
            if (close + 4 >= t.size() || t[close + 1] != "access" || t[close + 2] != ":" || t[close + 3] != ":" ||
                (t[close + 4] != "sample" && t[close + 4] != "read")) return false;
            readAccess = t[close + 4] == "read";
            close += 5;
        }
        if (close >= t.size() || t[close++] != ">" || (kind == Shape::TwoD && readAccess)) return false;
        const size_t textureEnd = close;
        size_t begin = i;
        if (i >= 2 && t[i - 1] == "<") {
            const auto& wrapper = t[i - 2];
            if (wrapper != "spvDescriptor" && wrapper != "spvDescriptorArray" && wrapper != "array" && wrapper != "spvUnsafeArray") return false;
            begin = i - 2;
            if (close < t.size() && t[close] == ",") {
                ++close;
                if (close >= t.size() || t[close].empty() || !std::isdigit(static_cast<unsigned char>(t[close][0]))) return false;
                ++close;
            }
            if (close >= t.size() || t[close++] != ">") return false;
        }
        if (close >= t.size() || !identifier(t[close])) return false;
        if (owner[close].empty()) {
            if (!names.emplace(t[close], kind).second) return false;
        } else {
            if (!fields[owner[close]].emplace(t[close], kind).second) return false;
            imageFieldNames.insert(t[close]);
        }
        for (size_t n = begin; n <= close; ++n) ignored[n] = true;
        // Recognized descriptor aliases own an explicitly typed wrapper. Their
        // initializer may contain the generated descriptor reinterpret_cast.
        size_t init = close + 1;
        if (init < t.size() && (t[init] == "{" || t[init] == "=")) {
            if (begin == i || t[begin] != "spvDescriptorArray" || t[init] != "{") return false;
            int depth = 0; size_t end = init;
            do {
                if (t[end] == "{") ++depth;
                if (t[end] == "}") --depth;
                ++end;
            } while (end < t.size() && depth);
            if (depth || end >= t.size() || t[end] != ";") return false;
            // Only the two actual generated descriptor-alias forms. In
            // particular, never hide a .read/helper call inside an initializer.
            bool alias = end == init + 5 && identifier(t[init + 1]) && t[init + 2] == "." && identifier(t[init + 3]);
            size_t aliasBase = init + 1, aliasField = init + 3; bool castAlias = false;
            if (!alias && init + 2 < end && t[init + 1] == "reinterpret_cast" && t[init + 2] == "<") {
                size_t target = init + 3; int nesting = 1;
                bool targetTexture = false, targetValid = true;
                while (target < end && nesting) {
                    if (t[target] == "<") ++nesting;
                    if (t[target] == ">") --nesting;
                    if (nesting && t[target] == t[i]) {
                        targetTexture = true;
                        for (size_t n = 0; n < textureEnd - i; ++n)
                            if (target + n >= end || t[target + n] != t[i + n]) targetValid = false;
                    }
                    if (nesting && t[target] != "<" && t[target] != ">" && t[target] != "*" && t[target] != "," &&
                        t[target] != ":" && t[target] != "const" && t[target] != "device" && t[target] != "spvDescriptor" &&
                        t[target] != t[i] && t[target] != "float" && t[target] != "half" && t[target] != "int" &&
                        t[target] != "uint" && t[target] != "access" && t[target] != "sample" && t[target] != "read") targetValid = false;
                    ++target;
                }
                alias = !nesting && targetTexture && targetValid && end == target + 7 && t[target] == "(" &&
                    t[target + 1] == "&" && identifier(t[target + 2]) && t[target + 3] == "." &&
                    identifier(t[target + 4]) && t[target + 5] == ")" && t[target + 6] == "}";
                aliasBase = target + 2; aliasField = target + 4; castAlias = true;
            }
            if (!alias) return false;
            aliases.push_back({aliasBase, aliasField, kind, castAlias});
            for (size_t n = init; n <= end; ++n) ignored[n] = true;
        }
    }
    // Only a directly declared typed base and one declared texture field are
    // supported. No auto/pointer aliases, nested fields, casts or shadowing.
    std::map<std::string, std::string> bases;
    std::vector<bool> baseDeclaration(t.size(), false);
    for (size_t i = 0; i < t.size(); ++i) {
        if (ignored[i] || !fields.count(t[i])) continue;
        size_t name = i + 1;
        if (name < t.size() && t[name] == "&") ++name;
        if (name >= t.size() || !identifier(t[name])) continue;
        if (!owner[name].empty() || !bases.emplace(t[name], t[i]).second) return false;
        baseDeclaration[name] = true;
    }
    auto fieldType = [&](size_t base, size_t field, Shape& result) {
        if (!bases.count(t[base])) return false;
        const auto& declared = fields.at(bases.at(t[base]));
        const auto found = declared.find(t[field]);
        if (found == declared.end()) return false;
        result = found->second; return true;
    };
    for (const auto& alias : aliases) {
        Shape root;
        if (!fieldType(alias.base, alias.field, root) || (!alias.cast && root != alias.declared)) return false;
    }
    auto receiver = [&](size_t end, size_t& name, size_t& base, Shape& kind) {
        while (end && t[end - 1] == "]") {
            int depth = 1; --end;
            while (end && depth) { --end; if (t[end] == "]") ++depth; if (t[end] == "[") --depth; }
            if (depth) return false;
        }
        if (!end || !identifier(t[end - 1])) return false;
        name = end - 1;
        base = name;
        if (name && t[name - 1] == "->") return false;
        if (name >= 2 && t[name - 1] == ".") {
            base = name - 2;
            if (!identifier(t[base]) || (base && (t[base - 1] == "." || t[base - 1] == "->"))) return false;
            return fieldType(base, name, kind);
        }
        const auto found = names.find(t[name]);
        if (found == names.end()) return false;
        kind = found->second; return true;
    };
    for (size_t i = 0; i < t.size(); ++i) {
        if (ignored[i]) continue;
        if ((t[i] == "." || t[i] == "->") && i + 2 < t.size() && identifier(t[i + 1]) && t[i + 2] == "(") {
            size_t name = 0, base = 0; Shape kind;
            if (t[i] == "->" || !receiver(i, name, base, kind)) return false;
            const auto& method = t[i + 1];
            const bool sample = method == "sample" || method == "sample_compare" || method == "gather" || method == "gather_compare";
            const bool read = method == "read" || method == "get_width" || method == "get_height" || method == "get_depth" ||
                method == "get_array_size" || method == "get_num_mip_levels";
            if (!sample && !(read && (kind == Shape::ThreeD || kind == Shape::Buffer))) return false;
            acceptedUse[name] = true;
            acceptedUse[base] = true;
        }
        if (t[i] == "is_null_texture" && i + 2 < t.size() && t[i + 1] == "(") {
            size_t end = i + 2; int depth = 1;
            while (end < t.size() && depth) { if (t[end] == "(") ++depth; if (t[end] == ")") --depth; if (depth) ++end; }
            size_t name = 0, base = 0; Shape kind;
            if (depth || !receiver(end, name, base, kind) || base != i + 2) return false;
            acceptedUse[name] = true;
            acceptedUse[base] = true;
        }
    }
    for (size_t i = 0; i < t.size(); ++i) {
        if (ignored[i] || acceptedUse[i] || baseDeclaration[i]) continue;
        if (bases.count(t[i])) {
            // Scalar/sampler/buffer fields are outside this image contract.
            // A whole descriptor struct escaping to an unknown helper is not.
            if (i + 2 >= t.size() || t[i + 1] != ".") return false;
            Shape kind;
            if (fieldType(i, i + 2, kind)) return false;
        }
        if (i >= 2 && t[i - 1] == ".") {
            Shape kind;
            if (fieldType(i - 2, i, kind)) return false;
            if (imageFieldNames.count(t[i]) || names.count(t[i])) return false;
        } else if (names.count(t[i])) return false;
    }
    return true;
}

class Compiler final : public SPIRV_CROSS_NAMESPACE::CompilerMSL {
public:
    using Validator = bool (*)(const uint32_t*, size_t);
    // Validate before the SPIRV-Cross base constructor parses any input.
    static std::unique_ptr<Compiler> create(const std::vector<uint32_t>& words, Validator validator = nullptr) {
        if (!validator || !validator(words.data(), words.size())) return {};
        return std::unique_ptr<Compiler>(new Compiler(words));
    }
    std::string compile() override {
        _valid = _structure; _compiled = false;
        try {
#ifdef ELIGIBLE_2D_ACCESS_CPU_FAULT_CONTROL
        if (_failNextProof) { _failNextProof = false; throw std::bad_alloc(); }
#endif
        using Type = SPIRV_CROSS_NAMESPACE::SPIRType;
        ir.for_each_typed_id<Type>([&](uint32_t, const Type& t) {
            if (t.basetype != Type::Image && t.basetype != Type::SampledImage) return;
            const auto& o = get_msl_options();
            if (!ordinary(t) || (t.pointer && t.storage != spv::StorageClassUniformConstant) ||
                (t.image.dim == spv::DimBuffer && !o.texture_buffer_native) ||
                (t.image.dim == spv::DimCube && t.image.arrayed && o.emulate_cube_array)) _valid = false;
        });
        // Result types come from SPIRV-Cross's grammar and resolved type IR.
        // Inspect all functions too, including ones omitted from final MSL.
        if (_structure) {
            std::map<uint32_t, uint32_t> types;
            for (size_t at = 5; at < _words.size(); at += _words[at] >> 16) {
                uint32_t type = 0, id = 0;
                if (instruction_to_result_type(type, id, static_cast<spv::Op>(_words[at] & 65535),
                    _words.data() + at + 1, (_words[at] >> 16) - 1)) types.emplace(id, type);
            }
            for (size_t at = 5; at < _words.size(); at += _words[at] >> 16) {
                const auto op = _words[at] & 65535;
                if (!legacy::sampling_op(op) && op != 95 && op != 98 && op != 103 && op != 104 && op != 106) continue;
                const auto found = types.find(_words[at + 3]);
                if (found == types.end()) _valid = false;
                else observe(op, get_type(found->second), false);
            }
        }
        } catch (...) { _valid = false; }
        // Optional proof failure must not prevent ordinary shader conversion.
        // A genuine base compiler error still propagates to the normal caller.
        auto source = CompilerMSL::compile();
        try { _source = source; _compiled = true; }
        catch (...) { _valid = false; _compiled = false; }
        return source;
    }
#ifdef ELIGIBLE_2D_ACCESS_CPU_FAULT_CONTROL
    void failNextProofForCPUControl() { _failNextProof = true; }
#endif
    // Regeneration must use the complete original configuration. A cache entry
    // receives no positive flag unless its exact bytes match that emission.
    bool qualifies(const std::string& exactMSL) const {
        try { return _compiled && _valid && exactMSL == _source && finalMSL(exactMSL); }
        catch (...) { return false; }
    }
    const char* reason(const std::string& exactMSL) const {
        if (!_compiled) return "NotCompiled";
        if (exactMSL != _source) return "ExactSourceMismatch";
        if (!_structure) return "StructuralVeto";
        if (!_valid) return "ResolvedOperandOrLoweringVeto";
        try { return finalMSL(exactMSL) ? "Eligible2DContract" : "FinalMSLAccessOrUnknownSyntaxVeto"; }
        catch (...) { return "AllocationFailure"; }
    }
protected:
    void emit_texture_op(const SPIRV_CROSS_NAMESPACE::Instruction& instruction, bool sparse) override {
        try {
            const auto& t = expression_type(stream(instruction)[2]);
            observe(instruction.op, t, sparse);
        } catch (...) { _valid = false; }
        CompilerMSL::emit_texture_op(instruction, sparse);
    }
    void emit_instruction(const SPIRV_CROSS_NAMESPACE::Instruction& instruction) override {
        if (instruction.op == 103 || instruction.op == 104 || instruction.op == 106) {
            try {
                const auto& t = expression_type(stream(instruction)[2]);
                observe(instruction.op, t, false);
            } catch (...) { _valid = false; }
        }
        CompilerMSL::emit_instruction(instruction);
    }
private:
    explicit Compiler(const std::vector<uint32_t>& words)
        : CompilerMSL(words), _structure(structure(words)), _words(words) {}
    void observe(uint32_t op, const SPIRV_CROSS_NAMESPACE::SPIRType& t, bool sparse) {
        const bool sampling = legacy::sampling_op(op) && !sparse;
        const bool non2DRead = (op == 95 || op == 98 || op == 103 || op == 104 || op == 106) && !sparse &&
            (t.image.dim == spv::DimBuffer || t.image.dim == spv::Dim3D);
        using Type = SPIRV_CROSS_NAMESPACE::SPIRType;
        if (!ordinary(t) || !(sampling || non2DRead) || (sampling && t.basetype != Type::SampledImage)) _valid = false;
    }
    static bool ordinary(const SPIRV_CROSS_NAMESPACE::SPIRType& t) {
        using Type = SPIRV_CROSS_NAMESPACE::SPIRType;
        const auto dim = t.image.dim;
        return (t.basetype == Type::Image || t.basetype == Type::SampledImage) && t.image.sampled == 1 && !t.image.ms &&
            (dim == spv::Dim2D || dim == spv::Dim3D || dim == spv::DimCube || dim == spv::DimBuffer) &&
            t.image.format == spv::ImageFormatUnknown &&
            (t.image.access == spv::AccessQualifierMax || t.image.access == spv::AccessQualifierReadOnly);
    }
    bool _structure = false, _valid = false, _compiled = false;
#ifdef ELIGIBLE_2D_ACCESS_CPU_FAULT_CONTROL
    bool _failNextProof = false;
#endif
    std::vector<uint32_t> _words;
    std::string _source;
};
} // namespace eligible_2d_access
