// Bounded opt-in in-process diagnostic: rebuild the complete selected source.
// This is not a release fallback: it requires the owned runtime source trace.
#pragma once
#include "MVKPipelineLinkGate.h"
static inline id<MTLRenderPipelineState> mvkReplayFailedMesh(id<MTLDevice> device,
        MTLMeshRenderPipelineDescriptor* original, const MVKConfiguration& config) {
    if (!mvkRuntimeReplayEnabled(config)) return nil;
    NSArray* functions = @[original.objectFunction ?: (id)[NSNull null], original.meshFunction ?: (id)[NSNull null], original.fragmentFunction ?: (id)[NSNull null]];
    NSMutableArray* sources = [NSMutableArray array];
    for (id value in functions) {
        if (value == [NSNull null]) return nil;
        id<MTLFunction> function = value;
        if (function.functionConstantsDictionary.count) return nil;
        NSArray* parts = [function.label componentsSeparatedByString:@":"];
        if (parts.count != 3 || [parts[1] length] != 16) return nil;
        NSCharacterSet* hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
        if ([parts[1] rangeOfCharacterFromSet:hex.invertedSet].location != NSNotFound) return nil;
        NSString* path = [@(config.shaderDumpDir) stringByAppendingPathComponent:[NSString stringWithFormat:@"source-%@.metal",parts[1]]];
        NSString* source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!source || [source containsString:@"SPIRV_CROSS_CONSTANT_ID"]) return nil;
        [sources addObject:source];
    }
    for (unsigned rename=0;rename<2;rename++) {
        MTLMeshRenderPipelineDescriptor* descriptor = [original copy];
        NSMutableArray* freshFunctions = [NSMutableArray array];
        NSError* error = nil;
        for (NSUInteger i=0;i<3;i++) {
            id<MTLFunction> old = functions[i];
            NSString* entry = old.name;
            NSString* source = sources[i];
            if (rename) {
                NSString* replacement = [NSString stringWithFormat:@"mvk_replay_%@_%lu",[[old.label componentsSeparatedByString:@":"]firstObject],(unsigned long)i];
                NSString* pattern = [NSString stringWithFormat:@"\\b%@\\b",[NSRegularExpression escapedPatternForString:entry]];
                source = [source stringByReplacingOccurrencesOfString:pattern withString:replacement options:NSRegularExpressionSearch range:NSMakeRange(0,source.length)];
                entry = replacement;
            }
            MTLCompileOptions* options = [[MTLCompileOptions new] autorelease];
            options.languageVersion = MTLLanguageVersion4_0;
            options.mathMode = MTLMathModeSafe;
            options.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
            options.preserveInvariance = i < 2;
            id<MTLLibrary> library = [device newLibraryWithSource:source options:options error:&error];
            id<MTLFunction> function = library ? [library newFunctionWithName:entry] : nil;
            [library release];
            if (!function) break;
            function.label = [old.label stringByAppendingString:rename ? @":renamed-replay" : @":source-replay"];
            [freshFunctions addObject:function];
            [function release];
        }
        id<MTLRenderPipelineState> pipeline = nil;
        if (freshFunctions.count == 3) {
            descriptor.objectFunction = freshFunctions[0];descriptor.meshFunction = freshFunctions[1];descriptor.fragmentFunction = freshFunctions[2];
            dispatch_semaphore_t linkGate = mvkGetPipelineLinkGate(true); // Caller restricts replay to AMD.
            if (linkGate) dispatch_semaphore_wait(linkGate,DISPATCH_TIME_FOREVER);
            pipeline = [device newRenderPipelineStateWithMeshDescriptor:descriptor options:MTLPipelineOptionNone reflection:nil error:&error];
            if (linkGate) dispatch_semaphore_signal(linkGate);
        }
        mvkWriteRuntimeTrace(config,@"mesh-replay",@{@"renamedEntryPoints":@(rename),@"mathMode":@"safe+precise",@"sourceFilesComplete":@YES,@"freshFunctionCount":@(freshFunctions.count),@"created":@(pipeline!=nil),@"error":error.localizedDescription?:@"",@"originalObject":mvkTraceFunction(original.objectFunction),@"originalMesh":mvkTraceFunction(original.meshFunction),@"originalFragment":mvkTraceFunction(original.fragmentFunction)});
        [descriptor release];
        if (pipeline) return pipeline; // Actual successfully compiled PSO, retained.
    }
    return nil;
}
