/*
 * MVKShaderModule.mm
 *
 * Copyright (c) 2015-2025 The Brenwill Workshop Ltd. (http://www.brenwill.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "MVKShaderModule.h"
#include "MVKPipeline.h"
#include "MVKFoundation.h"
#include <sys/stat.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>
#include "MVKRenderArchive.h"

using namespace std;
using namespace mvk;
#include "MVKRuntimeTrace.h"

MVKMTLFunction::MVKMTLFunction(id<MTLFunction> mtlFunc, const SPIRVToMSLConversionResultInfo scRslts, MTLSize tgSize) {
	_mtlFunction = [mtlFunc retain];		// retained
	shaderConversionResults = scRslts;
	threadGroupSize = tgSize;
}

MVKMTLFunction::MVKMTLFunction(const MVKMTLFunction& other) {
	_mtlFunction = [other._mtlFunction retain];		// retained
	shaderConversionResults = other.shaderConversionResults;
	threadGroupSize = other.threadGroupSize;
}

MVKMTLFunction& MVKMTLFunction::operator=(const MVKMTLFunction& other) {
	// Retain new object first in case it's the same object
	[other._mtlFunction retain];
	[_mtlFunction release];
	_mtlFunction = other._mtlFunction;

	shaderConversionResults = other.shaderConversionResults;
	threadGroupSize = other.threadGroupSize;
	return *this;
}

MVKMTLFunction::~MVKMTLFunction() {
	[_mtlFunction release];
}


#pragma mark -
#pragma mark MVKShaderLibrary

// If the size of the workgroup dimension is specialized, extract it from the
// specialization info, otherwise use the value specified in the SPIR-V shader code.
static uint32_t getWorkgroupDimensionSize(const SPIRVWorkgroupSizeDimension& wgDim, const VkSpecializationInfo* pSpecInfo) {
	if (wgDim.isSpecialized && pSpecInfo) {
		for (uint32_t specIdx = 0; specIdx < pSpecInfo->mapEntryCount; specIdx++) {
			const VkSpecializationMapEntry* pMapEntry = &pSpecInfo->pMapEntries[specIdx];
			if (pMapEntry->constantID == wgDim.specializationID) {
				return *reinterpret_cast<uint32_t*>((uintptr_t)pSpecInfo->pData + pMapEntry->offset) ;
			}
		}
	}
	return wgDim.size;
}

MVKMTLFunction MVKShaderLibrary::getMTLFunction(const VkSpecializationInfo* pSpecializationInfo,
												VkPipelineCreationFeedback* pShaderFeedback,
												MVKShaderModule* shaderModule) {

	if ( !_mtlLibrary ) { return MVKMTLFunctionNull; }

	id<MTLLibrary> lib = _mtlLibrary;

	// If specialization happens on constants mapped to macro, find or compile a library variant
	// with proper macro definition instead of the "generic" library
	if (pSpecializationInfo && _maySpecializeWithMacro) {
		// Create the list of macro-value mapping
		vector<pair<uint32_t, MVKShaderMacroValue>> spec_list;
		for (uint32_t specIdx = 0; specIdx < pSpecializationInfo->mapEntryCount; specIdx++) {
			const VkSpecializationMapEntry* pMapEntry = &pSpecializationInfo->pMapEntries[specIdx];
			uint32_t const_id = pMapEntry->constantID;
			MVKShaderMacroValue macro_value = {};
			size_t size = min(pMapEntry->size, sizeof(macro_value.value));

			memcpy(&macro_value.value, (char *)pSpecializationInfo->pData + pMapEntry->offset, size);
			macro_value.size = size;
			if (_shaderConversionResultInfo.specializationMacros.find(const_id) != _shaderConversionResultInfo.specializationMacros.end()) {
				spec_list.push_back(make_pair(const_id, macro_value));
			}
		}

		if (!spec_list.empty()) {
			// Sort the specialization list before it is used as a key to index the variants
			std::sort(spec_list.begin(), spec_list.end());
			auto entry = _specializationVariants.find(spec_list);
			if (entry != _specializationVariants.end()) {
				lib = entry->second->_mtlLibrary;
			} else {
				MVKShaderLibrary *new_mvklib = new MVKShaderLibrary(_owner, _shaderConversionResultInfo, _compressedMSL, &spec_list, _conservativeMeshLibrary);
				_specializationVariants[spec_list] = new_mvklib;
				lib = new_mvklib->_mtlLibrary;
			}
		}
	}


	@synchronized (getMTLDevice()) {
		@autoreleasepool {
			NSString* mtlFuncName = @(_shaderConversionResultInfo.entryPoint.mtlFunctionName.c_str());

			uint64_t startTime = pShaderFeedback ? mvkGetTimestamp() : getPerformanceTimestamp();
			id<MTLFunction> mtlFunc = [[lib newFunctionWithName: mtlFuncName] autorelease];
			addPerformanceInterval(getPerformanceStats().shaderCompilation.functionRetrieval, startTime);
			if (pShaderFeedback) {
				if (mtlFunc) {
					mvkEnableFlags(pShaderFeedback->flags, VK_PIPELINE_CREATION_FEEDBACK_VALID_BIT);
				}
				pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
			}

			if (mtlFunc) {
				// If the Metal function expects to be specialized, populate Metal function constant values from
				// the Vulkan specialization info, and compile a specialized Metal function, otherwise simply use
				// the unspecialized Metal function.
				NSArray<MTLFunctionConstant*>* mtlFCs = mtlFunc.functionConstantsDictionary.allValues;
				if (mtlFCs.count > 0) {
					// The Metal shader contains function constants and expects to be specialized.
					// Populate the Metal function constant values from the Vulkan specialization info.
					MTLFunctionConstantValues* mtlFCVals = [[MTLFunctionConstantValues new] autorelease];
					if (pSpecializationInfo) {
						// Iterate through the provided Vulkan specialization entries, and populate the
						// Metal function constant value that matches the Vulkan specialization constantID.
						for (uint32_t specIdx = 0; specIdx < pSpecializationInfo->mapEntryCount; specIdx++) {
							const VkSpecializationMapEntry* pMapEntry = &pSpecializationInfo->pMapEntries[specIdx];
							for (MTLFunctionConstant* mfc in mtlFCs) {
								if (mfc.index == pMapEntry->constantID) {
									[mtlFCVals setConstantValue: ((char*)pSpecializationInfo->pData + pMapEntry->offset)
														   type: mfc.type
														atIndex: mfc.index];
									break;
								}
							}
						}
					}

					// Compile the specialized Metal function, and use it instead of the unspecialized Metal function.
					// Specialization can return a timeout before Metal invokes its completion.
					// Use the same deferred-destroy ownership as library/pipeline compilers;
					// a stack object would leave the late completion with a dangling this.
					MVKFunctionSpecializer* fs = new MVKFunctionSpecializer(_owner);
					if (pShaderFeedback) {
						startTime = mvkGetTimestamp();
					}
					mtlFunc = [fs->newMTLFunction(lib, mtlFuncName, mtlFCVals) autorelease];
					fs->destroy();
					if (pShaderFeedback) {
						pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
					}
				}
			}

			if (mtlFunc && mvkGPUTimeoutTraceEnabled()) objc_setAssociatedObject(mtlFunc, mvkCompileProvenanceKey(), objc_getAssociatedObject(lib, mvkCompileProvenanceKey()), OBJC_ASSOCIATION_RETAIN);

			// Set the debug name. First try name of shader module, otherwise try name of owner.
			NSString* dbName = shaderModule->getDebugName();
			if ( !dbName ) { dbName = _owner->getDebugName(); }
			_owner->setMetalObjectLabel(mtlFunc, dbName);

			auto& wgSize = _shaderConversionResultInfo.entryPoint.workgroupSize;
			return MVKMTLFunction(mtlFunc, _shaderConversionResultInfo, MTLSizeMake(getWorkgroupDimensionSize(wgSize.width, pSpecializationInfo),
																					getWorkgroupDimensionSize(wgSize.height, pSpecializationInfo),
																					getWorkgroupDimensionSize(wgSize.depth, pSpecializationInfo)));
		}
	}
}

void MVKShaderLibrary::setEntryPointName(string& funcName) {
	_shaderConversionResultInfo.entryPoint.mtlFunctionName = funcName;
}

void MVKShaderLibrary::setWorkgroupSize(uint32_t x, uint32_t y, uint32_t z) {
	auto& wgSize = _shaderConversionResultInfo.entryPoint.workgroupSize;
	wgSize.width.size = x;
	wgSize.height.size = y;
	wgSize.depth.size = z;
}

// Sets the cached MSL source code, after first compressing it.
void MVKShaderLibrary::compressMSL(const string& msl) {
	uint64_t startTime = getPerformanceTimestamp();
	_compressedMSL.compress(msl, getMVKConfig().shaderSourceCompressionAlgorithm);
	addPerformanceInterval(getPerformanceStats().shaderCompilation.mslCompress, startTime);
}

// Decompresses the cached MSL into the string.
void MVKShaderLibrary::decompressMSL(string& msl) {
	uint64_t startTime = getPerformanceTimestamp();
	_compressedMSL.decompress(msl);
	addPerformanceInterval(getPerformanceStats().shaderCompilation.mslDecompress, startTime);
}

MVKShaderLibrary::MVKShaderLibrary(MVKVulkanAPIDeviceObject* owner,
								   const SPIRVToMSLConversionResult& conversionResult) :
	MVKBaseDeviceObject(owner->getDevice()),
	_owner(owner),
	_maySpecializeWithMacro(true) {

	_shaderConversionResultInfo = conversionResult.resultInfo;
	compressMSL(conversionResult.msl);
	compileLibrary(conversionResult.msl);
}

MVKShaderLibrary::MVKShaderLibrary(MVKVulkanAPIDeviceObject* owner,
								   const SPIRVToMSLConversionResultInfo& resultInfo,
								   const MVKCompressor<std::string> compressedMSL,
								   const vector<pair<uint32_t, MVKShaderMacroValue> >* specializationMacroDef,
                                   bool conservativeMeshLibrary) :
	MVKBaseDeviceObject(owner->getDevice()),
	_owner(owner),
	_maySpecializeWithMacro(specializationMacroDef == nullptr),
    _conservativeMeshLibrary(conservativeMeshLibrary) {

	_shaderConversionResultInfo = resultInfo;
	_compressedMSL = compressedMSL;
	string msl;
	decompressMSL(msl);
	compileLibrary(msl, specializationMacroDef);
}

void MVKShaderLibrary::compileLibrary(const string& msl,
									  const vector<pair<uint32_t, MVKShaderMacroValue> >* specializationMacroDef) {
	MVKShaderLibraryCompiler* slc = new MVKShaderLibraryCompiler(_owner);
	NSString* nsSrc = [[NSString alloc] initWithUTF8String: msl.c_str()];	// temp retained

	// If specialization macro is used, translate the id to macro information and pass it to compiler
	vector<pair<MSLSpecializationMacroInfo, MVKShaderMacroValue>> macro_def;
	if (specializationMacroDef) {
		for (auto& def: *specializationMacroDef) {
			const auto& macro_name_iter = _shaderConversionResultInfo.specializationMacros.find(def.first);
			if (macro_name_iter != _shaderConversionResultInfo.specializationMacros.end()) {
				macro_def.push_back(make_pair(macro_name_iter->second, def.second));
			}
		}
	}

	_mtlLibrary = slc->newMTLLibrary(nsSrc, _shaderConversionResultInfo, macro_def, _conservativeMeshLibrary);	// retained
	[nsSrc release];														// release temp string
	slc->destroy();
}

MVKShaderLibrary::MVKShaderLibrary(MVKVulkanAPIDeviceObject* owner,
                                   const void* mslCompiledCodeData,
                                   size_t mslCompiledCodeLength) :
	MVKBaseDeviceObject(owner->getDevice()),
	_owner(owner),
	_maySpecializeWithMacro(false) {

    uint64_t startTime = getPerformanceTimestamp();
    @autoreleasepool {
        dispatch_data_t shdrData = dispatch_data_create(mslCompiledCodeData,
                                                        mslCompiledCodeLength,
                                                        NULL,
                                                        DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError* err = nil;
        _mtlLibrary = [getMTLDevice() newLibraryWithData: shdrData error: &err];    // retained
        handleCompilationError(err, "Compiled shader module creation");
        [shdrData release];
    }
	addPerformanceInterval(getPerformanceStats().shaderCompilation.mslLoad, startTime);
}

MVKShaderLibrary::MVKShaderLibrary(const MVKShaderLibrary& other) :
	MVKBaseDeviceObject(other._device),
	_owner(other._owner),
	_maySpecializeWithMacro(other._maySpecializeWithMacro),
    _conservativeMeshLibrary(other._conservativeMeshLibrary),
	_specializationVariants(other._specializationVariants) {

	_mtlLibrary = [other._mtlLibrary retain];
	_shaderConversionResultInfo = other._shaderConversionResultInfo;
	_compressedMSL = other._compressedMSL;
}

MVKShaderLibrary& MVKShaderLibrary::operator=(const MVKShaderLibrary& other) {
	if (_mtlLibrary != other._mtlLibrary) {
		[_mtlLibrary release];
		_mtlLibrary = [other._mtlLibrary retain];
	}
	_owner = other._owner;
    _conservativeMeshLibrary = other._conservativeMeshLibrary;
	_shaderConversionResultInfo = other._shaderConversionResultInfo;
	_compressedMSL = other._compressedMSL;
	return *this;
}

// If err object is nil, the compilation succeeded without any warnings.
// If err object exists, and the MTLLibrary was created, the compilation succeeded, but with warnings.
// If err object exists, and the MTLLibrary was not created, the compilation failed.
void MVKShaderLibrary::handleCompilationError(NSError* err, const char* opDesc) {
    if ( !err ) return;

    if (_mtlLibrary) {
        MVKLogInfo("%s succeeded with warnings (Error code %li):\n%s", opDesc, (long)err.code, err.localizedDescription.UTF8String);
    } else {
		_owner->setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED,
												   "%s failed (Error code %li):\n%s",
												   opDesc, (long)err.code,
												   err.localizedDescription.UTF8String));
    }
}

MVKShaderLibrary::~MVKShaderLibrary() {
	[_mtlLibrary release];

	for (auto& item: _specializationVariants) {
		delete item.second;
	}
}


#pragma mark -
#pragma mark MVKShaderLibraryCache

MVKShaderLibrary* MVKShaderLibraryCache::getShaderLibrary(SPIRVToMSLConversionConfiguration* pShaderConfig,
														  MVKShaderModule* shaderModule, MVKPipeline* pipeline,
														  bool* pWasAdded, VkPipelineCreationFeedback* pShaderFeedback,
														  uint64_t startTime) {
	bool wasAdded = false;
	MVKShaderLibrary* shLib = findShaderLibrary(pShaderConfig, pShaderFeedback, startTime);
	if ( !shLib && !pipeline->shouldFailOnPipelineCompileRequired() ) {
		SPIRVToMSLConversionResult conversionResult;
		if (shaderModule->convert(pShaderConfig, conversionResult)) {
			shLib = addShaderLibrary(pShaderConfig, conversionResult);
			if (pShaderFeedback) {
				pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
			}
			wasAdded = true;
		}
	}

	if (pWasAdded) { *pWasAdded = wasAdded; }

	return shLib;
}

// Finds and returns a shader library matching the shader config, or returns nullptr if it doesn't exist.
// If a match is found, the shader config is aligned with the shader config of the matching library.
MVKShaderLibrary* MVKShaderLibraryCache::findShaderLibrary(SPIRVToMSLConversionConfiguration* pShaderConfig,
														   VkPipelineCreationFeedback* pShaderFeedback,
														   uint64_t startTime) {
	for (auto& slPair : _shaderLibraries) {
		if (slPair.first.matches(*pShaderConfig)) {
			pShaderConfig->alignWith(slPair.first);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.shaderLibraryFromCache, startTime);
			if (pShaderFeedback) {
				pShaderFeedback->duration += mvkGetElapsedNanoseconds(startTime);
			}
			return slPair.second;
		}
	}
	return nullptr;
}

// Adds and returns a new shader library configured from the specified conversion configuration.
MVKShaderLibrary* MVKShaderLibraryCache::addShaderLibrary(const SPIRVToMSLConversionConfiguration* pShaderConfig,
														  const SPIRVToMSLConversionResult& conversionResult) {
	MVKShaderLibrary* shLib = new MVKShaderLibrary(_owner, conversionResult);
	_shaderLibraries.emplace_back(*pShaderConfig, shLib);
	return shLib;
}

// Adds and returns a new shader library configured from contents read from a pipeline cache.
MVKShaderLibrary* MVKShaderLibraryCache::addShaderLibrary(const SPIRVToMSLConversionConfiguration* pShaderConfig,
														  const SPIRVToMSLConversionResultInfo& resultInfo,
														  const MVKCompressor<std::string> compressedMSL) {
	MVKShaderLibrary* shLib = new MVKShaderLibrary(_owner, resultInfo, compressedMSL);
	// Cached MSL that no longer compiles is dropped: the shader is converted again when it is used.
	if ( !shLib->_mtlLibrary ) {
		shLib->destroy();
		return nullptr;
	}
	_shaderLibraries.emplace_back(*pShaderConfig, shLib);
	return shLib;
}

// Merge another shader library cache with this one. Handle null input.
void MVKShaderLibraryCache::merge(MVKShaderLibraryCache* other) {
	if ( !other ) { return; }
	for (auto& otherPair : other->_shaderLibraries) {
		if ( !findShaderLibrary(&otherPair.first) ) {
			_shaderLibraries.emplace_back(otherPair.first, new MVKShaderLibrary(*otherPair.second));
			_shaderLibraries.back().second->_owner = _owner;
		}
	}
}

MVKShaderLibraryCache::~MVKShaderLibraryCache() {
	for (auto& slPair : _shaderLibraries) { slPair.second->destroy(); }
}


#pragma mark -
#pragma mark MVKShaderModule

MVKMTLFunction MVKShaderModule::getMTLFunction(SPIRVToMSLConversionConfiguration* pShaderConfig,
											   const VkSpecializationInfo* pSpecializationInfo,
											   MVKPipeline* pipeline,
											   VkPipelineCreationFeedback* pShaderFeedback,
											   bool forceReplaySource) {
	bool trace = mvkRuntimeTraceEnabled(getMVKConfig()) && !mvkRuntimeReplayOnly();
	bool replaySource = mvkRuntimeReplayEnabled(getMVKConfig()) &&
		(pShaderConfig->options.mslOptions.for_mesh_pipeline || forceReplaySource);
	NSDictionary* requestedConfig = trace ? mvkTraceConfig(*pShaderConfig) : nil;
	MVKShaderLibrary* mvkLib = _directMSLLibrary;
	if ( !mvkLib ) {
		uint64_t startTime = pShaderFeedback ? mvkGetTimestamp() : getPerformanceTimestamp();
		MVKPipelineCache* pipelineCache = pipeline->getPipelineCache();
		if (pipelineCache) {
			mvkLib = pipelineCache->getShaderLibrary(pShaderConfig, this, pipeline, pShaderFeedback, startTime);
		} else {
			lock_guard<mutex> lock(_accessLock);
			mvkLib = _shaderLibraryCache.getShaderLibrary(pShaderConfig, this, pipeline, nullptr, pShaderFeedback, startTime);
		}
	} else {
		mvkLib->setEntryPointName(pShaderConfig->options.entryPointName);
		pShaderConfig->markAllInterfaceVarsAndResourcesUsed();
	}

    // Per-pipeline source-backed libraries isolate a narrow AMD geometry
    // compilation policy. Fresh ownership alone did not cure the game failure;
    // the separate safe option applies conservative math used by the successful
    // diagnostic rebuild. Macros and specialization values stay unchanged.
    // No file replay or successful-error substitution is involved.
    const char* freshOption = getenv("MVK_AMD_FRESH_MESH_LIBRARIES");
    bool freshMesh = freshOption && !strcmp(freshOption, "1") &&
        getPhysicalDevice()->isAMDHardware() && !_directMSLLibrary &&
        (pShaderConfig->options.mslOptions.for_mesh_pipeline || forceReplaySource);
    // A fresh source-backed library requires compilation. Respect Vulkan
    // pipeline-cache-control rather than compiling behind a no-compile request.
    if (freshMesh && pipeline->shouldFailOnPipelineCompileRequired()) return MVKMTLFunctionNull;
    const char* safeOption = getenv("MVK_AMD_SAFE_MESH_LIBRARIES");
    bool safeMesh = freshMesh && safeOption && !strcmp(safeOption, "1");
    MVKMTLFunction result = MVKMTLFunctionNull;
    if (mvkLib && freshMesh) {
        auto compileInfo = mvkLib->_shaderConversionResultInfo;
        if (safeMesh) {
            compileInfo.entryPoint.fpFastMathFlags = spv::FPFastMathModeMaskNone;
            compileInfo.isPositionInvariant = pShaderConfig->options.entryPointStage != spv::ExecutionModelFragment;
        }
        MVKShaderLibrary freshLibrary(pipeline, compileInfo,
                                      mvkLib->getCompressedMSL(), nullptr, safeMesh);
        result = freshLibrary.getMTLFunction(pSpecializationInfo, pShaderFeedback, this);
        mvkWriteRuntimeTrace(getMVKConfig(), @"fresh-mesh-function", @{
            @"stage":@((unsigned)pShaderConfig->options.entryPointStage),
            @"created":@(result.getMTLFunction() != nil),
            @"specializationPassedUnchanged":@YES, @"conservativeMeshMath":@(safeMesh),
            @"function":mvkTraceFunction(result.getMTLFunction())});
    } else if (mvkLib) result = mvkLib->getMTLFunction(pSpecializationInfo, pShaderFeedback, this);
    const char* shardRoot = getenv("MVK_AMD_COMPUTE_ARCHIVE_DIR");
    const char* renderShardRoot = getenv("MVK_AMD_RENDER_ARCHIVE_DIR");
    bool computeShard = shardRoot && shardRoot[0] == '/' &&
        pShaderConfig->options.entryPointStage == spv::ExecutionModelGLCompute;
    bool renderShard = renderShardRoot && renderShardRoot[0] == '/' &&
        (pShaderConfig->options.entryPointStage == spv::ExecutionModelVertex ||
         pShaderConfig->options.entryPointStage == spv::ExecutionModelFragment);
    if (mvkLib && result.getMTLFunction() && (computeShard || renderShard) &&
        getPhysicalDevice()->isAMDHardware()) {
        std::string source;
        mvkLib->decompressMSL(source);
        // Include generated code, entry point, compiler options, and complete
        // specialization values. Hash object bytes explicitly: mvkHash<T>'s
        // count is in elements, not bytes.
        std::string recipe;
        auto append = [&](const void* bytes, size_t count) {
            if (count) recipe.append(static_cast<const char*>(bytes), count);
        };
        // Preserve the existing compute namespace, including legacy keys.
        // Render recipes are new: frame variable-length source explicitly.
        if (renderShard) {
            uint64_t sourceBytes = source.size();
            append(&sourceBytes, sizeof(sourceBytes));
        }
        append(source.data(), source.size());
        NSString* functionName = [result.getMTLFunction() name];
        const char* name = functionName.UTF8String;
        uint64_t nameBytes = name ? strlen(name) : 0;
        append(&nameBytes, sizeof(nameBytes));
        append(name, nameBytes);
        auto flags = result.shaderConversionResults.entryPoint.fpFastMathFlags;
        uint8_t invariant = result.shaderConversionResults.isPositionInvariant;
        auto fastMath = getMVKConfig().fastMathEnabled;
        auto version = pShaderConfig->options.mslOptions.msl_version;
        append(&flags, sizeof(flags));
        append(&invariant, sizeof(invariant));
        append(&fastMath, sizeof(fastMath));
        append(&version, sizeof(version));
        uint64_t dataBytes = pSpecializationInfo ? pSpecializationInfo->dataSize : 0;
        uint32_t mapCount = pSpecializationInfo ? pSpecializationInfo->mapEntryCount : 0;
        if (computeShard) {
            append(&dataBytes, sizeof(dataBytes));
            if (pSpecializationInfo) append(pSpecializationInfo->pData, dataBytes);
            append(&mapCount, sizeof(mapCount));
            for (uint32_t index = 0; index < mapCount; ++index) {
                const auto& entry = pSpecializationInfo->pMapEntries[index];
                append(&entry.constantID, sizeof(entry.constantID));
                append(&entry.offset, sizeof(entry.offset));
                append(&entry.size, sizeof(entry.size));
            }
        } else {
            // Offsets, mapping order, unused data and padding are not shader
            // semantics. Equivalent API layouts must not force another compile.
            std::vector<const VkSpecializationMapEntry*> entries;
            for (uint32_t index = 0; index < mapCount; ++index)
                entries.push_back(&pSpecializationInfo->pMapEntries[index]);
            std::sort(entries.begin(), entries.end(), [](auto a, auto b) { return a->constantID < b->constantID; });
            append(&mapCount, sizeof(mapCount));
            for (auto entry : entries) {
                if (entry->offset > dataBytes || entry->size > dataBytes - entry->offset ||
                    (entry->size && !pSpecializationInfo->pData)) { renderShard = false; break; }
                append(&entry->constantID, sizeof(entry->constantID));
                append(&entry->size, sizeof(entry->size));
                if (entry->size) append(static_cast<const char*>(pSpecializationInfo->pData) + entry->offset, entry->size);
            }
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(recipe.data(), (CC_LONG)recipe.size(), digest);
        char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
        for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; ++index)
            snprintf(hex + index * 2, 3, "%02x", digest[index]);
        if (computeShard) {
            NSString* key = [NSString stringWithFormat:@"mvk-cs2-%s", hex];
            static_cast<MVKComputePipeline*>(pipeline)->setNativeComputeArchiveKey(key.UTF8String);
        }
        if (renderShard) mvkSetFunctionRecipe(result.getMTLFunction(), safeMesh ? [@"safe-mesh-v1|" stringByAppendingString:@(hex)] : @(hex));
    }
	if ((trace || replaySource || mvkGPUTimeoutTraceEnabled()) && mvkLib) {
		std::string source;
		mvkLib->decompressMSL(source);
		size_t sourceHash = mvkHash(source.data(), source.size());
		NSString* label = [NSString stringWithFormat:@"%016zx:%016zx:%u",_key.codeHash,sourceHash,(unsigned)pShaderConfig->options.entryPointStage];
		id<MTLFunction> function = result.getMTLFunction();
		function.label = label;
		NSString* path = [@(getMVKConfig().shaderDumpDir) stringByAppendingPathComponent:[NSString stringWithFormat:@"source-%016zx.metal",sourceHash]];
        if (!mvkGPUTimeoutTraceEnabled() || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		[[NSData dataWithBytes:source.data() length:source.size()] writeToFile:path options:NSDataWritingAtomic error:nil];
		if (trace) mvkWriteRuntimeTrace(getMVKConfig(), @"function", @{@"shader":[NSString stringWithFormat:@"%016zx",_key.codeHash],@"sourceHash":[NSString stringWithFormat:@"%016zx",sourceHash],@"requested":requestedConfig,@"selected":mvkTraceConfig(*pShaderConfig),@"function":mvkTraceFunction(function),@"pipelineCache":@(pipeline->getPipelineCache()!=nullptr),@"fpFastMathFlags":@(result.shaderConversionResults.entryPoint.fpFastMathFlags),@"positionInvariant":@(result.shaderConversionResults.isPositionInvariant)});
	}
	return result;
}

bool MVKShaderModule::convert(SPIRVToMSLConversionConfiguration* pShaderConfig,
							  SPIRVToMSLConversionResult& conversionResult) {
	const auto& mvkCfg = getMVKConfig();
	bool shouldLogCode = mvkCfg.debugMode;
	bool shouldLogEstimatedGLSL = shouldLogCode && mvkCfg.shaderLogEstimatedGLSL;

	uint64_t startTime = getPerformanceTimestamp();
	bool wasConverted = _spvConverter.convert(*pShaderConfig, conversionResult, shouldLogCode, shouldLogCode, shouldLogEstimatedGLSL);
	addPerformanceInterval(getPerformanceStats().shaderCompilation.spirvToMSL, startTime);

	const char* dumpDir = getMVKConfig().shaderDumpDir;
	if (dumpDir && *dumpDir && !mvkRuntimeReplayOnly()) {
		char path[PATH_MAX];
		const char* type;
		switch (pShaderConfig->options.entryPointStage) {
			case spv::ExecutionModelVertex:                 type = "-vs"; break;
			case spv::ExecutionModelTessellationControl:    type = "-tcs"; break;
			case spv::ExecutionModelTessellationEvaluation: type = "-tes"; break;
			case spv::ExecutionModelFragment:               type = "-fs"; break;
			case spv::ExecutionModelGeometry:               type = "-gs"; break;
			case spv::ExecutionModelTaskNV:                 type = "-ts"; break;
			case spv::ExecutionModelMeshNV:                 type = "-ms"; break;
			case spv::ExecutionModelGLCompute:              type = "-cs"; break;
			default:                                        type = "";    break;
		}
		mkdir(dumpDir, 0755);
		snprintf(path, sizeof(path), "%s/shader%s-%016zx.spv", dumpDir, type, _key.codeHash);
		FILE* file = fopen(path, "wb");
		if (file) {
			fwrite(_spvConverter.getSPIRV().data(), sizeof(uint32_t), _spvConverter.getSPIRV().size(), file);
			fclose(file);
		}
		snprintf(path, sizeof(path), "%s/shader%s-%016zx.metal", dumpDir, type, _key.codeHash);
		file = fopen(path, "wb");
		if (file) {
			if (wasConverted) {
				fwrite(conversionResult.msl.data(), 1, conversionResult.msl.size(), file);
				fclose(file);
			} else {
				fputs("Failed to convert:\n", file);
				fwrite(conversionResult.resultLog.data(), 1, conversionResult.resultLog.size(), file);
				fclose(file);
			}
		}
	}

	if (wasConverted) {
		if (shouldLogCode) { MVKLogInfo("%s", conversionResult.resultLog.c_str()); }
	} else {
		reportError(VK_ERROR_INITIALIZATION_FAILED, "Unable to convert SPIR-V to MSL:\n%s", conversionResult.resultLog.c_str());
	}
	return wasConverted;
}

void MVKShaderModule::setWorkgroupSize(uint32_t x, uint32_t y, uint32_t z) {
	if(_directMSLLibrary) { _directMSLLibrary->setWorkgroupSize(x, y, z); }
}


#pragma mark Construction

MVKShaderModule::MVKShaderModule(MVKDevice* device,
								 const VkShaderModuleCreateInfo* pCreateInfo) : MVKVulkanAPIDeviceObject(device), _shaderLibraryCache(this) {

	_directMSLLibrary = nullptr;

	size_t codeSize = pCreateInfo->codeSize;

    // Ensure something is there.
    if ( (pCreateInfo->pCode == VK_NULL_HANDLE) || (codeSize < 4) ) {
		setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkCreateShaderModule(): Shader module contains no shader code."));
		return;
	}

	size_t codeHash = 0;

	// Retrieve the magic number to determine what type of shader code has been loaded.
	// NOTE: Shader code should be submitted as SPIR-V. Although some simple direct MSL shaders may work,
	// direct loading of MSL source code or compiled MSL code is not officially supported at this time.
	// Future versions of MoltenVK may support direct MSL submission again.
	uint32_t magicNum = *pCreateInfo->pCode;
	switch (magicNum) {
		case kMVKMagicNumberSPIRVCode: {					// SPIR-V code
			size_t spvCount = (codeSize + 3) >> 2;			// Round up if byte length not exactly on uint32_t boundary

			uint64_t startTime = getPerformanceTimestamp();
			codeHash = mvkHash(pCreateInfo->pCode, spvCount);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.hashShaderCode, startTime);

			_spvConverter.setSPIRV(pCreateInfo->pCode, spvCount);

			break;
		}
		case kMVKMagicNumberMSLSourceCode: {				// MSL source code
			size_t hdrSize = sizeof(MVKMSLSPIRVHeader);
			char* pMSLCode = (char*)(uintptr_t(pCreateInfo->pCode) + hdrSize);
			size_t mslCodeLen = codeSize - hdrSize;

			uint64_t startTime = getPerformanceTimestamp();
			codeHash = mvkHash(&magicNum);
			codeHash = mvkHash(pMSLCode, mslCodeLen, codeHash);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.hashShaderCode, startTime);

			SPIRVToMSLConversionResult conversionResult;
			conversionResult.msl = pMSLCode;
			_directMSLLibrary = new MVKShaderLibrary(this, conversionResult);

			break;
		}
		case kMVKMagicNumberMSLCompiledCode: {				// MSL compiled binary code
			size_t hdrSize = sizeof(MVKMSLSPIRVHeader);
			char* pMSLCode = (char*)(uintptr_t(pCreateInfo->pCode) + hdrSize);
			size_t mslCodeLen = codeSize - hdrSize;

			uint64_t startTime = getPerformanceTimestamp();
			codeHash = mvkHash(&magicNum);
			codeHash = mvkHash(pMSLCode, mslCodeLen, codeHash);
			addPerformanceInterval(getPerformanceStats().shaderCompilation.hashShaderCode, startTime);

			_directMSLLibrary = new MVKShaderLibrary(this, (void*)(pMSLCode), mslCodeLen);

			break;
		}
		default:
			setConfigurationResult(reportError(VK_ERROR_INITIALIZATION_FAILED, "vkCreateShaderModule(): The SPIR-V contains an invalid magic number %x.", magicNum));
			break;
	}

	_key = MVKShaderModuleKey(codeSize, codeHash);
}

MVKShaderModule::~MVKShaderModule() {
	if (_directMSLLibrary) { _directMSLLibrary->destroy(); }
}


#pragma mark -
#pragma mark MVKShaderLibraryCompiler

id<MTLLibrary> MVKShaderLibraryCompiler::newMTLLibrary(NSString* mslSourceCode,
													   const SPIRVToMSLConversionResultInfo& shaderConversionResults,
													   const vector<pair<MSLSpecializationMacroInfo, MVKShaderMacroValue>>& specializationMacroDef,
                                                     bool conservativeMeshLibrary) {
	unique_lock<mutex> lock(_completionLock);
	_mslSourceCode = mslSourceCode;		// For logMSLSource(), from handleError() within compile().
	const char* syncOption = getenv("MVK_AMD_SYNC_MESH_LIBRARIES");
	bool synchronousMesh = conservativeMeshLibrary && syncOption && !strcmp(syncOption, "1");

	compile(lock, ^{
		auto mtlDev = getMTLDevice();
		MTLCompileOptions* synchronousOptions = nil;
		NSDictionary* synchronousProvenance = nil;
		@synchronized (mtlDev) {
			@autoreleasepool {
				auto mtlCompileOptions = getDevice()->getMTLCompileOptions(shaderConversionResults.entryPoint.fpFastMathFlags,
																		   shaderConversionResults.isPositionInvariant);
                if (conservativeMeshLibrary) {
                    // Scope conservative compilation to the opted-in geometry
                    // chain. Override the global fast-math preference here;
                    // all specialization macros/values below are preserved.
                    mtlCompileOptions.fastMathEnabled = NO;
#if MVK_XCODE_16
                    if ([mtlCompileOptions respondsToSelector:@selector(mathMode)]) {
                        mtlCompileOptions.mathMode = MTLMathModeSafe;
                        mtlCompileOptions.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
                    }
#endif
                }
				if (!specializationMacroDef.empty()) {
					size_t macro_count = specializationMacroDef.size();
					NSString *macro_names[macro_count];
					NSNumber *macro_values[macro_count];
					for (uint32_t i = 0; i < specializationMacroDef.size(); i++) {
						macro_names[i] = @(specializationMacroDef[i].first.name.c_str());
						macro_values[i] = getMacroValue(specializationMacroDef[i].first, specializationMacroDef[i].second);
					}
					mtlCompileOptions.preprocessorMacros = [NSDictionary dictionaryWithObjects: macro_values
																					   forKeys: macro_names
																						 count: macro_count];
				}
				logCompilation(mtlCompileOptions);
                NSDictionary* provenance = mvkCompileProvenance(mslSourceCode, mtlCompileOptions);
				if (provenance) {
					NSMutableDictionary* detail = [[provenance mutableCopy] autorelease];
					detail[@"libraryCreationAPI"] = synchronousMesh ? @"synchronous" : @"asynchronous";
					provenance = detail;
				}

				if (synchronousMesh) {
					// Match the public API used by successful diagnostic source
					// rebuilds, without disk replay or a hidden retry. Keep source,
					// macros, entry and specialization semantics unchanged. Compile
					// outside the device monitor so unrelated requests can proceed.
					synchronousOptions = [mtlCompileOptions retain];
					synchronousProvenance = [provenance retain];
				} else {
				[mtlDev newLibraryWithSource: mslSourceCode
									options: mtlCompileOptions
						completionHandler: ^(id<MTLLibrary> mtlLib, NSError* error) {
                            if (mtlLib && provenance) objc_setAssociatedObject(mtlLib, mvkCompileProvenanceKey(), provenance, OBJC_ASSOCIATION_COPY);
							bool isLate = compileComplete(mtlLib, error);
							if (isLate) { destroy(); }
						}];
				}
			}
		}
		if (synchronousOptions) {
			NSError* error = nil;
			id<MTLLibrary> library = [mtlDev newLibraryWithSource:mslSourceCode options:synchronousOptions error:&error];
			if (library && synchronousProvenance)
				objc_setAssociatedObject(library, mvkCompileProvenanceKey(), synchronousProvenance, OBJC_ASSOCIATION_COPY);
			bool isLate = compileComplete(library, error);
			[library release];
			[synchronousOptions release];
			[synchronousProvenance release];
			// The existing timeout/deferred-destroy contract also applies to
			// this blocking native call on the compiler's worker queue.
			if (isLate) { destroy(); }
		}
	});
	_mslSourceCode = nil;

	return [_mtlLibrary retain];
}

NSNumber *MVKShaderLibraryCompiler::getMacroValue(const MSLSpecializationMacroInfo& info,
												  const MVKShaderMacroValue& value) {
	NSNumber *result;

	if (info.isFloat) {
		if (value.size == sizeof(double)) {
			result = [NSNumber numberWithDouble: value.value.f64];
		} else {
			result = [NSNumber numberWithFloat: value.value.f32];
		}
	} else {
		if (info.isSigned) {
			switch (value.size) {
				case 1:
					result = [NSNumber numberWithChar: value.value.si8];
					break;
				case 2:
					result = [NSNumber numberWithShort: value.value.si16];
					break;
				case 4:
					result = [NSNumber numberWithInt: value.value.si32];
					break;
				case 8:
					result = [NSNumber numberWithLongLong: value.value.si64];
					break;
				default:
					result = [NSNumber numberWithInt: value.value.si32];
					break;
			}
		} else {
			switch (value.size) {
				case 1:
					result = [NSNumber numberWithUnsignedChar: value.value.ui8];
					break;
				case 2:
					result = [NSNumber numberWithUnsignedShort: value.value.ui16];
					break;
				case 4:
					result = [NSNumber numberWithUnsignedInt: value.value.ui32];
					break;
				case 8:
					result = [NSNumber numberWithUnsignedLongLong: value.value.ui64];
					break;
				default:
					result = [NSNumber numberWithUnsignedInt: value.value.ui32];
					break;
			}
		}
	}

	return result;
}

void MVKShaderLibraryCompiler::handleError() {
	if (_mtlLibrary) {
		MVKLogInfo("%s compilation succeeded with warnings (Error code %li):\n%s", _compilerType.c_str(),
				   (long)_compileError.code, _compileError.localizedDescription.UTF8String);
	} else {
		MVKMetalCompiler::handleError();
		logMSLSource();
	}
}

// Writes the MSL of a failed compile to stderr, right after the error, every line prefixed with "[mvk-msl] "
// (the launcher attaches these lines to its error report): the first lines (without the helper templates
// SPIRV-Cross puts first, such as spvUnsafeArray, which filled the head of many reports), then the lines
// around each line the compiler error names ("program_source:LINE:"), prefixed with their line number.
// One write(), so the lines are not interleaved with other output.
void MVKShaderLibraryCompiler::logMSLSource() {
	static constexpr size_t kHeadLineCount = 40;
	static constexpr size_t kContextLineCount = 5;
	static constexpr size_t kMaxErrorLocations = 4;
	static constexpr size_t kMaxLineLength = 512;

	const char* src = _mslSourceCode.UTF8String;
	if ( !src ) { return; }

	vector<string_view> lines;
	for (const char* p = src; *p; ) {
		const char* eol = strchr(p, '\n');
		size_t len = eol ? size_t(eol - p) : strlen(p);
		lines.emplace_back(p, len);
		p += len + (eol ? 1 : 0);
	}

	string out;
	auto append = [&](size_t lineNum, string_view text) {
		out += "[mvk-msl] ";
		if (lineNum) {
			out += to_string(lineNum);
			out += ": ";
		}
		if (text.size() > kMaxLineLength) {
			out.append(text.substr(0, kMaxLineLength));
			out += " [...]";
		} else {
			out.append(text);
		}
		out += '\n';
	};

	size_t headLines = 0, templateLines = 0;
	for (size_t i = 0; i < lines.size() && headLines < kHeadLineCount; i++) {
		// A top-level template definition is one line ending with "}" or "};", or runs to the next line that is
		// "}" or "};" (the end of a multi-line definition).
		if (lines[i].substr(0, 9) == "template<") {
			auto endsBlock = [](string_view s) {
				return (s.size() >= 1 && s.substr(s.size() - 1) == "}") || (s.size() >= 2 && s.substr(s.size() - 2) == "};");
			};
			size_t end = i;
			if ( !endsBlock(lines[i]) ) {
				while (end + 1 < lines.size() && lines[end] != "}" && lines[end] != "};") { end++; }
			}
			templateLines += end - i + 1;
			i = end;
			continue;
		}
		append(0, lines[i]);
		headLines++;
	}
	if (templateLines) {
		out += "[mvk-msl] ... (" + to_string(templateLines) + " lines of templates left out)\n";
	}
	if (lines.size() > headLines + templateLines) {
		out += "[mvk-msl] ... (" + to_string(lines.size()) + " lines total)\n";
	}

	static constexpr char kLocationPrefix[] = "program_source:";
	vector<size_t> errorLines;
	const char* errDesc = _compileError.localizedDescription.UTF8String;
	for (const char* p = errDesc; p && (p = strstr(p, kLocationPrefix)) && errorLines.size() < kMaxErrorLocations; ) {
		p += sizeof(kLocationPrefix) - 1;
		size_t lineNum = strtoul(p, nullptr, 10);
		if (lineNum && lineNum <= lines.size() && find(errorLines.begin(), errorLines.end(), lineNum) == errorLines.end()) {
			errorLines.push_back(lineNum);
		}
	}
	// Neighboring errors (one per variable of a declaration list, for example) share their context lines: each
	// line is logged once, in source order.
	sort(errorLines.begin(), errorLines.end());
	size_t lastLogged = 0;
	for (size_t lineNum : errorLines) {
		size_t first = max(lineNum > kContextLineCount ? lineNum - kContextLineCount : 1, lastLogged + 1);
		size_t last = min(lineNum + kContextLineCount, lines.size());
		for (size_t n = first; n <= last; n++) {
			append(n, lines[n - 1]);
		}
		lastLogged = max(lastLogged, last);
	}

	for (size_t done = 0; done < out.size(); ) {
		ssize_t written = write(STDERR_FILENO, out.data() + done, out.size() - done);
		if (written <= 0) { break; }
		done += size_t(written);
	}
}

bool MVKShaderLibraryCompiler::compileComplete(id<MTLLibrary> mtlLibrary, NSError* compileError) {
	lock_guard<mutex> lock(_completionLock);

	_mtlLibrary = [mtlLibrary retain];		// retained
	return endCompile(compileError);
}

void MVKShaderLibraryCompiler::logCompilation(MTLCompileOptions* mtlCompOpt) {
	if ( !getMVKConfig().debugMode ) { return; }

#if MVK_XCODE_16
	if ([mtlCompOpt respondsToSelector: @selector(mathMode)]) {
		const char* mathModeName = "Unknown";
		switch (mtlCompOpt.mathMode) {
			case MTLMathModeFast:
				mathModeName = "Fast";
				break;
			case MTLMathModeRelaxed:
				mathModeName = "Relaxed";
				break;
			case MTLMathModeSafe:
				mathModeName = "Safe";
				break;
			default:
				break;
		}
		const char* mathFPFName = "Unknown";
		switch (mtlCompOpt.mathFloatingPointFunctions) {
			case MTLMathFloatingPointFunctionsFast:
				mathFPFName = "Fast";
				break;
			case MTLMathFloatingPointFunctionsPrecise:
				mathFPFName = "Precise";
				break;
			default:
				break;
		}
		MVKLogInfo("Compiling Metal shader with MathMode %s, MathFloatingPointFunctions %s, and PreserveInvariance %sabled.",
				   mathModeName, mathFPFName, mtlCompOpt.preserveInvariance ? "en" : "dis");
	} else
#endif
	{
		MVKLogInfo("Compiling Metal shader with FastMath %sabled and PreserveInvariance %sabled.",
				   mtlCompOpt.fastMathEnabled ? "en" : "dis", mtlCompOpt.preserveInvariance ? "en" : "dis");
	}
}


#pragma mark Construction

MVKShaderLibraryCompiler::~MVKShaderLibraryCompiler() {
	[_mtlLibrary release];
}


#pragma mark -
#pragma mark MVKFunctionSpecializer

id<MTLFunction> MVKFunctionSpecializer::newMTLFunction(id<MTLLibrary> mtlLibrary,
													   NSString* funcName,
													   MTLFunctionConstantValues* constantValues) {
	unique_lock<mutex> lock(_completionLock);

	compile(lock, ^{
		[mtlLibrary newFunctionWithName: funcName
						 constantValues: constantValues
					  completionHandler: ^(id<MTLFunction> mtlFunc, NSError* error) {
						  bool isLate = compileComplete(mtlFunc, error);
						  if (isLate) { destroy(); }
					  }];
	});

	return [_mtlFunction retain];
}

bool MVKFunctionSpecializer::compileComplete(id<MTLFunction> mtlFunction, NSError* compileError) {
	lock_guard<mutex> lock(_completionLock);

	_mtlFunction = [mtlFunction retain];		// retained
	return endCompile(compileError);
}

#pragma mark Construction

MVKFunctionSpecializer::~MVKFunctionSpecializer() {
	[_mtlFunction release];
}

