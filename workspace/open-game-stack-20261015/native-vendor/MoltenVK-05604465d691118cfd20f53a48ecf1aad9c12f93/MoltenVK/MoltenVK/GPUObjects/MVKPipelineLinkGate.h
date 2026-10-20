// Opt-in AMD mesh-pipeline link serialization. Hold across asynchronous mesh
// completion, not just API submission. Ordinary render and compute pipelines
// remain parallel because the reproduced driver defect is mesh-link specific.
#pragma once
static inline dispatch_semaphore_t mvkGetPipelineLinkGate(bool isAMD) {
    const char* option = getenv("MVK_AMD_SERIALIZE_PIPELINE_LINK");
    if (!isAMD || !option || strcmp(option,"1")) return nullptr;
    static dispatch_semaphore_t gate = dispatch_semaphore_create(1);
    return gate;
}
