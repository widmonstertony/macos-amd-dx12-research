#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
static MTLCompileOptions* compileOptions(NSDictionary* p) {
    MTLCompileOptions* options = [[MTLCompileOptions new] autorelease];
    options.languageVersion = (MTLLanguageVersion)[p[@"languageVersion"] unsignedIntegerValue];
    options.mathMode = (MTLMathMode)[p[@"mathMode"] unsignedIntegerValue];
    options.mathFloatingPointFunctions = (MTLMathFloatingPointFunctions)[p[@"mathFloatingPointFunctions"] unsignedIntegerValue];
    if (p[@"optimizationLevel"]) options.optimizationLevel = (MTLLibraryOptimizationLevel)[p[@"optimizationLevel"] unsignedIntegerValue];
    options.preserveInvariance = [p[@"preserveInvariance"] boolValue];
    options.preprocessorMacros = p[@"preprocessorMacros"];
    return options;
}
static NSArray* targetFunctions(id<MTLDevice> device, NSDictionary* input,
        NSMutableArray* keepLibraries, NSError** error) {
    NSMutableArray* functions = [NSMutableArray array];
    for (NSString* stage in @[@"object",@"mesh",@"fragment"]) {
        NSDictionary* item = input[@"functions"][stage];
        NSString* source = [NSString stringWithContentsOfFile:item[@"source"] encoding:NSUTF8StringEncoding error:error];
        if (!source) return nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:compileOptions(item[@"compileProvenance"]) error:error];
        id<MTLFunction> function = [library newFunctionWithName:item[@"entry"]];
        if (!function) { [library release]; return nil; }
        function.label = item[@"label"];
        // Match the production function metadata query, retaining each object.
        (void)function.functionConstantsDictionary.allValues;
        [keepLibraries addObject:library]; [library release];
        [functions addObject:function]; [function release];
    }
    return functions;
}
