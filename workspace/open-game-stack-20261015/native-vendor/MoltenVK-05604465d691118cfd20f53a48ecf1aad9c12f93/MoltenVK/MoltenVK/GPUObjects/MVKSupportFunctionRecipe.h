// Stable recipes for MoltenVK's own static/generated command support shaders.
// Called only with the fresh options returned by getMTLCompileOptions().
// No application/library pointer is used as persistent cache identity.
#pragma once
#include "MVKRenderArchive.h"

static const void* mvkSupportLibraryRecipeKey() {
    return sel_registerName("mvkSupportLibraryRecipeV1");
}

static bool mvkSupportRecipesEnabled() {
    const char* root = getenv("MVK_AMD_RENDER_ARCHIVE_DIR");
    return root && root[0] == '/';
}

static void mvkSetSupportLibraryRecipe(id<MTLLibrary> library, NSString* source,
                                      MTLCompileOptions* options) {
    if (!library || !source || !mvkSupportRecipesEnabled()) return;
    // This factory does not use macros. Refuse future macro-bearing inputs
    // until their full typed values are included in the recipe.
    if (options.preprocessorMacros.count) return;
    NSMutableData* bytes = [NSMutableData data];
    auto add = [&](uint64_t value) { [bytes appendBytes:&value length:sizeof(value)]; };
    NSData* utf8 = [source dataUsingEncoding:NSUTF8StringEncoding];
    add(1); add(utf8.length); [bytes appendData:utf8];
    add(options.languageVersion); add(options.fastMathEnabled);
    add(options.preserveInvariance);
    if ([options respondsToSelector:@selector(optimizationLevel)]) add(options.optimizationLevel);
    else add(UINT64_MAX);
#if MVK_XCODE_16
    if ([options respondsToSelector:@selector(mathMode)]) {
        add(options.mathMode); add(options.mathFloatingPointFunctions);
    } else { add(UINT64_MAX); add(UINT64_MAX); }
#endif
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i)
        snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    objc_setAssociatedObject(library, mvkSupportLibraryRecipeKey(), @(hex), OBJC_ASSOCIATION_COPY);
}

static void mvkSetSupportFunctionRecipe(id<MTLFunction> function, id<MTLLibrary> library,
                                       NSString* name) {
    if (!function || !mvkSupportRecipesEnabled()) return;
    NSString* base = objc_getAssociatedObject(library, mvkSupportLibraryRecipeKey());
    if (base && name) {
        // The base is fixed-length hex; name consumes the remaining string.
        mvkSetFunctionRecipe(function, [NSString stringWithFormat:@"support-v1|%@|%@", base, name]);
        function.label = name;
    }
}
