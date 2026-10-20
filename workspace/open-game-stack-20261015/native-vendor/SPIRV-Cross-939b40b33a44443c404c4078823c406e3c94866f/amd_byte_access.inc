// Included in spirv_msl.cpp inside SPIRV-Cross namespace. Private compiler
// implementation, never a hardware/capability override.
bool CompilerMSL::amd_byte_guards_enabled() const
{
    const char *enabled = getenv("MVK_AMD_BYTE_GUARDS");
    return msl_options.robust_buffer_access2 && enabled && string(enabled) == "1";
}

bool CompilerMSL::amd_get_byte_access(uint32_t pointer, AMDByteAccess &access)
{
    if (!amd_byte_guards_enabled()) return false;
    auto existing = amd_byte_accesses.find(pointer);
    if (existing != amd_byte_accesses.end()) { access = existing->second; return true; }
    auto *var = maybe_get<SPIRVariable>(pointer);
    if (!var || !buffers_requiring_robust_access.count(var->self))
    {
        auto &pointer_type = expression_type(pointer);
        if (pointer_type.pointer && (pointer_type.storage == StorageClassUniform || pointer_type.storage == StorageClassStorageBuffer))
            SPIRV_CROSS_THROW("Untraced logical buffer pointer in AMD protected compiler");
        return false;
    }
    auto &block = get_variable_element_type(*var);
    access = {};
    access.root = var->self;
    access.base = to_pointer_expression(var->self, false);
    access.size = to_buffer_size_expression(var->self);
    access.constant = var->storage == StorageClassUniform && !has_decoration(block.self, DecorationBufferBlock);
    return !access.size.empty();
}

void CompilerMSL::amd_record_byte_access(const uint32_t *ops, uint32_t length)
{
    AMDByteAccess access;
    if (!amd_get_byte_access(ops[2], access)) return;
    const SPIRType *type = &get_pointee_type(expression_type(ops[2]));
    for (uint32_t i = 3; i < length; ++i)
    {
        string index = to_unpacked_expression(ops[i]);
        bool descriptor = i == 3 && ops[2] == access.root && is_array(*type) && type->basetype == SPIRType::Struct &&
            (has_decoration(type->self, DecorationBlock) || has_decoration(type->self, DecorationBufferBlock));
        if (descriptor)
        {
            access.base += "[" + index + "]";
            access.size += "[" + index + "]";
            type = &get<SPIRType>(type->parent_type);
            continue;
        }
        uint32_t stride = 0;
        if (is_array(*type))
        {
            stride = get_robust_array_stride(*type);
            if (is_runtime_size_array(*type)) access.runtime = true;
            else access.condition = join("(", access.condition, " && ulong(", index, ") < ulong(", to_array_size(*type, uint32_t(type->array.size() - 1)), "))");
            type = &get<SPIRType>(type->parent_type);
        }
        else if (type->basetype == SPIRType::Struct)
        {
            auto *constant = maybe_get<SPIRConstant>(ops[i]);
            if (!constant || constant->specialization) SPIRV_CROSS_THROW("Nonconstant buffer struct index");
            uint32_t member = constant->scalar();
            if (member >= type->member_types.size()) SPIRV_CROSS_THROW("Buffer member index out of range");
            access.offset = join("(", access.offset, " + ", type_struct_member_offset(*type, member), "ul)");
            auto &member_type = get<SPIRType>(type->member_types[member]);
            access.row_major = has_member_decoration(type->self, member, DecorationRowMajor);
            access.matrix_stride = member_type.columns > 1 ? type_struct_member_matrix_stride(*type, member) : 0;
            type = &member_type;
            continue;
        }
        else if (type->columns > 1)
        {
            if (!access.matrix_stride) SPIRV_CROSS_THROW("Missing protected matrix stride");
            access.condition = join("(", access.condition, " && ulong(", index, ") < ", type->columns, "ul)");
            stride = access.row_major ? type->width / 8 : access.matrix_stride;
            type = &get<SPIRType>(type->parent_type);
        }
        else if (type->vecsize > 1)
        {
            access.condition = join("(", access.condition, " && ulong(", index, ") < ", type->vecsize, "ul)");
            stride = access.row_major && access.matrix_stride ? access.matrix_stride : type->width / 8;
            type = &get<SPIRType>(type->parent_type);
        }
        else SPIRV_CROSS_THROW("Unsupported protected buffer access-chain element");
        if (!stride) SPIRV_CROSS_THROW("Zero protected buffer stride");
        // Bound before multiplication; negative integer indices convert to large
        // unsigned values and fail. Guards short-circuit underflow/overflow.
        access.condition = join("(", access.condition, " && ", access.offset, " <= ulong(", access.size,
            ") && ulong(", index, ") <= (ulong(", access.size, ") - ", access.offset, ") / ", stride, "ul)");
        access.offset = join("(", access.offset, " + ulong(", index, ") * ", stride, "ul)");
    }
    amd_byte_accesses[ops[1]] = access;
    auto &result = get<SPIRType>(ops[0]);
    if (!access.runtime && result.vecsize == 1 && result.columns == 1 && result.array.empty() &&
        (result.width == 32 || result.width == 64))
    {
        RobustAccessInfo atomic;
        atomic.valid = true;
        atomic.bounds_check_condition = amd_component_condition(access, access.offset, result.width / 8);
        robust_access_chains[ops[1]] = atomic;
    }
}

string CompilerMSL::amd_component_condition(const AMDByteAccess &access, const string &offset, uint32_t bytes)
{
    return join("(", access.base, " != nullptr && ", access.condition, " && ", offset,
        " <= ulong(", access.size, ") && ", bytes, "ul <= ulong(", access.size, ") - ", offset, ")");
}

bool CompilerMSL::amd_emit_byte_load(uint32_t result_type, uint32_t id, uint32_t pointer)
{
    AMDByteAccess access;
    if (!amd_get_byte_access(pointer, access) || access.runtime) return false;
    auto &type = get<SPIRType>(result_type);
    // Protect the logical address-table read; the physical address it contains
    // retains caller-managed Vulkan BDA semantics after this load.
    if (is_pointer(type) && type.storage == StorageClassPhysicalStorageBuffer)
    {
        string qualifier = access.constant ? "constant " : "const device ";
        string read = join("*((", qualifier, "ulong*)((", qualifier, "uchar*)(", access.base, ") + ", access.offset, "))");
        string bits = join("(", amd_component_condition(access, access.offset, 8), " ? ", read, " : 0ul)");
        emit_op(result_type, id, join("reinterpret_cast<", type_to_glsl(type), ">(", bits, ")"), false);
        register_read(id, pointer, false);
        inherit_expression_dependencies(id, pointer);
        return true;
    }
    if (type.pointer || is_array(type) || type.basetype == SPIRType::Struct)
        SPIRV_CROSS_THROW("Static aggregate/pointer load not yet qualified in AMD protected compiler");
    if (type.width != 32 && type.width != 64) SPIRV_CROSS_THROW("Unqualified narrow protected CBV load");
    SPIRType scalar = type; scalar.vecsize = scalar.columns = 1;
    string scalar_name = type_to_glsl(scalar);
    string qualifier = access.constant ? "constant " : "const device ";
    auto component = [&](uint32_t column, uint32_t row) {
        uint32_t relative = type.columns > 1 ? (access.row_major ? row * access.matrix_stride + column * (type.width / 8) : column * access.matrix_stride + row * (type.width / 8)) : row * (type.width / 8);
        string offset = join("(", access.offset, " + ", relative, "ul)");
        string read = join("*((", qualifier, scalar_name, "*)((", qualifier, "uchar*)(", access.base, ") + ", offset, "))");
        return join("(", amd_component_condition(access, offset, type.width / 8), " ? ", read, " : ", scalar_name, "(0))");
    };
    string expression;
    if (type.columns == 1 && type.vecsize == 1) expression = component(0, 0);
    else {
        expression = type_to_glsl(type) + "(";
        for (uint32_t column = 0; column < type.columns; ++column) {
            if (column) expression += ", ";
            SPIRType vector = type; vector.columns = 1;
            if (type.columns > 1) expression += type_to_glsl(vector) + "(";
            for (uint32_t row = 0; row < type.vecsize; ++row) {
                if (row) expression += ", ";
                expression += component(column, row);
            }
            if (type.columns > 1) expression += ")";
        }
        expression += ")";
    }
    emit_op(result_type, id, expression, false);
    register_read(id, pointer, false);
    inherit_expression_dependencies(id, pointer);
    unset_extended_decoration(id, SPIRVCrossDecorationPhysicalTypePacked);
    unset_extended_decoration(id, SPIRVCrossDecorationPhysicalTypeID);
    return true;
}

bool CompilerMSL::amd_emit_byte_store(uint32_t pointer, uint32_t value)
{
    AMDByteAccess access;
    if (!amd_get_byte_access(pointer, access) || access.runtime) return false;
    auto &type = expression_type(value);
    if (type.pointer || is_array(type) || type.basetype == SPIRType::Struct)
        SPIRV_CROSS_THROW("Static aggregate/pointer store not yet qualified in AMD protected compiler");
    if (access.constant) SPIRV_CROSS_THROW("Store to protected constant buffer");
    if (type.width != 32 && type.width != 64) SPIRV_CROSS_THROW("Unqualified narrow protected buffer store");
    SPIRType scalar = type; scalar.vecsize = scalar.columns = 1;
    string rhs = to_unpacked_expression(value);
    for (uint32_t column = 0; column < type.columns; ++column) for (uint32_t row = 0; row < type.vecsize; ++row) {
        uint32_t relative = type.columns > 1 ? (access.row_major ? row * access.matrix_stride + column * (type.width / 8) : column * access.matrix_stride + row * (type.width / 8)) : row * (type.width / 8);
        string offset = join("(", access.offset, " + ", relative, "ul)");
        string condition = amd_component_condition(access, offset, type.width / 8);
        if (needs_frag_discard_checks()) condition = join("(!", builtin_to_glsl(BuiltInHelperInvocation, StorageClassInput), " && ", condition, ")");
        statement("if (", condition, ")"); begin_scope();
        string component = "(" + rhs + ")";
        if (type.columns > 1) component += "[" + to_string(column) + "]";
        if (type.vecsize > 1) component += "[" + to_string(row) + "]";
        statement("*((device ", type_to_glsl(scalar), "*)((device uchar*)(", access.base, ") + ", offset, ")) = ", component, ";");
        end_scope();
    }
    register_write(pointer);
    return true;
}
