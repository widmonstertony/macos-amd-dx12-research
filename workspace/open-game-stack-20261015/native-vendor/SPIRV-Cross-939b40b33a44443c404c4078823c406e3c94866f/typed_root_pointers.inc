// Native, name-independent SPIR-V def/use analysis. No generated-text rewriting.
// Deliberately conservative: unknown uses, component accesses, arithmetic,
// stores, calls, and phi/select merges retain the original integer representation.
void CompilerMSL::analyze_typed_root_pointers()
{
    typed_root_members.clear();
    typed_root_values.clear();
    typed_root_loads.clear();
    if (!msl_options.typed_root_pointers || !msl_options.is_macos()) return;

    struct Inst { Op op; const uint32_t *a; uint32_t n; bool function; };
    vector<Inst> instructions;
    bool in_function = false;
    // Analyze original module words, including terminators and phi edges which
    // the structured IR otherwise removes from SPIRBlock::ops.
    for (size_t offset = 5; offset < ir.spirv.size();)
    {
        uint32_t count = ir.spirv[offset] >> 16;
        if (!count || count > ir.spirv.size() - offset)
            SPIRV_CROSS_THROW("Malformed module during typed root analysis");
        Op op = Op(ir.spirv[offset] & 0xffff);
        if (op == OpFunction) in_function = true;
        Inst inst { op, ir.spirv.data() + offset + 1, count - 1, in_function };
        instructions.push_back(inst);
        if (op == OpFunctionEnd) in_function = false;
        offset += count;
    }
    auto address_bits = [&](uint32_t id) {
        const auto &t = get<SPIRType>(id);
        return !t.pointer && t.array.empty() && t.columns == 1 &&
            ((t.basetype == SPIRType::UInt && t.width == 32 && t.vecsize == 2) ||
             (t.basetype == SPIRType::UInt64 && t.width == 64 && t.vecsize == 1));
    };
    unordered_map<uint32_t, uint32_t> roots;
    unordered_map<uint32_t, vector<uint64_t>> structure_members;
    unordered_set<uint64_t> candidates, rejected, has_physical_use;
    ir.for_each_typed_id<SPIRVariable>([&](uint32_t id, const SPIRVariable &v) {
        if (v.storage != StorageClassPushConstant) return;
        const auto &t = get_variable_data_type(v);
        if (t.basetype != SPIRType::Struct || !t.array.empty()) return;
        roots[id] = t.self;
        for (uint32_t m = 0; m < t.member_types.size(); ++m)
        {
            if (!address_bits(t.member_types[m]) || !has_member_decoration(t.self, m, DecorationOffset) ||
                (get_member_decoration(t.self, m, DecorationOffset) & 7)) continue;
            uint64_t key = (uint64_t(t.self) << 32) | m;
            candidates.insert(key);
            structure_members[t.self].push_back(key);
        }
    });
    if (candidates.empty()) return;
    auto literal_operand = [](const Inst &i, uint32_t k) {
        // ExtInst's instruction number is a literal, not an SSA ID. In
        // particular GLSL NMin/NMax/NClamp often coincide with root-load IDs.
        return i.op == OpExtInst && k == 3;
    };
    auto reject_struct = [&](uint32_t type) {
        auto i = structure_members.find(type);
        if (i != structure_members.end()) for (auto key : i->second) rejected.insert(key);
    };
    // Changing the printed struct member must be safe for every use of that
    // struct, not only the first push-constant instance we encountered.
    for (auto &i : instructions)
    {
        if (i.op == OpTypePointer && i.n == 3 && i.a[1] != StorageClassPushConstant)
            reject_struct(i.a[2]);
        if (i.op == OpTypeStruct)
            for (uint32_t k = 1; k < i.n; ++k) reject_struct(i.a[k]);
    }
    unordered_map<uint32_t, uint64_t> accesses, values, loads;
    for (auto &i : instructions)
    {
        if (!i.function) continue;
        bool chain = i.op == OpAccessChain || i.op == OpInBoundsAccessChain;
        for (uint32_t k = 0; k < i.n; ++k)
        {
            if (literal_operand(i, k)) continue;
            auto root = roots.find(i.a[k]);
            if (root == roots.end()) continue;
            if (!chain || k != 2 || i.n < 4)
            {
                reject_struct(root->second);
                continue;
            }
            const auto *index = maybe_get<SPIRConstant>(i.a[3]);
            if (!index || index->specialization)
            {
                reject_struct(root->second);
                continue;
            }
            uint64_t key = (uint64_t(root->second) << 32) | index->scalar();
            if (!candidates.count(key)) continue;
            if (i.n != 4) rejected.insert(key); // whole value only, no vector-component access
            else accesses[i.a[1]] = key;
        }
    }
    for (auto &i : instructions)
    {
        if (!i.function) continue;
        uint32_t rt = 0, result = 0;
        bool defines = instruction_to_result_type(rt, result, i.op, i.a, i.n);
        for (uint32_t k = 0; k < i.n; ++k)
        {
            if (literal_operand(i, k)) continue;
            auto a = accesses.find(i.a[k]);
            if (a == accesses.end() || (defines && k == 1)) continue;
            if (i.op == OpLoad && k == 2 && i.n == 3 && address_bits(i.a[0]))
            {
                values[i.a[1]] = a->second;
                loads[i.a[1]] = a->second;
            }
            else rejected.insert(a->second);
        }
    }
    // Propagate only lossless, whole-value aliases. All other operations are
    // rejected below, including mixed numeric/address uses of the same field.
    bool changed;
    do
    {
        changed = false;
        for (auto &i : instructions)
        {
            if (!i.function || i.n != 3 || (i.op != OpCopyObject && i.op != OpBitcast)) continue;
            auto v = values.find(i.a[2]);
            if (v == values.end() || !address_bits(i.a[0]) || values.count(i.a[1])) continue;
            values[i.a[1]] = v->second;
            changed = true;
        }
    } while (changed);
    for (auto &i : instructions)
    {
        if (!i.function) continue;
        uint32_t rt = 0, result = 0;
        bool defines = instruction_to_result_type(rt, result, i.op, i.a, i.n);
        for (uint32_t k = 0; k < i.n; ++k)
        {
            if (literal_operand(i, k)) continue;
            auto v = values.find(i.a[k]);
            if (v == values.end() || (defines && k == 1)) continue;
            bool alias = k == 2 && i.n == 3 && (i.op == OpCopyObject || i.op == OpBitcast) &&
                         values.count(i.a[1]) && values.at(i.a[1]) == v->second;
            if (alias) continue;
            bool cast = k == 2 && i.n == 3 && (i.op == OpBitcast || i.op == OpConvertUToPtr);
            if (cast)
            {
                const auto &target = get<SPIRType>(i.a[0]);
                if (target.pointer && target.storage == StorageClassPhysicalStorageBuffer)
                {
                    has_physical_use.insert(v->second);
                    continue;
                }
            }
            rejected.insert(v->second);
        }
    }
    for (auto key : candidates)
        if (!rejected.count(key) && has_physical_use.count(key)) typed_root_members.insert(key);
    for (auto &v : values)
        if (typed_root_members.count(v.second)) typed_root_values.insert(v.first);
    for (auto &v : loads)
        if (typed_root_members.count(v.second)) typed_root_loads.insert(v.first);
    if (!typed_root_values.empty() && !typed_root_pointer_type)
    {
        uint32_t byte = get_ubyte_type_id();
        uint32_t id = ir.increase_bound_by(1);
        SPIRType ptr = get<SPIRType>(byte);
        ptr.op = OpTypePointer;
        ptr.parent_type = byte;
        ptr.pointer = true;
        ptr.pointer_depth = 1;
        ptr.storage = StorageClassPhysicalStorageBuffer;
        auto &made = set<SPIRType>(id, ptr);
        made.self = id;
        typed_root_pointer_type = id;
    }
}
