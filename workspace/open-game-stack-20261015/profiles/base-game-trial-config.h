// Game-only qualified submission profile. Original asset guard remains unchanged.
static void append_record(const char *message);
static void mvk_apply_game_trial_config(void) {
    unsetenv("MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL");
    setenv("MVK_AMD_SERIALIZE_PIPELINE_LINK", "1", 1);
    setenv("MVK_AMD_FRESH_MESH_LIBRARIES", "1", 1);
    setenv("MVK_AMD_SAFE_MESH_LIBRARIES", "1", 1);
    setenv("MVK_AMD_SYNC_MESH_LIBRARIES", "1", 1);
    setenv("MVK_AMD_SYNC_MESH_PIPELINES", "1", 1);
    setenv("MVK_AMD_LINK_DIFFERENTIAL_CAPTURE", "1", 1);
    unsetenv("MVK_AMD_REPLAY_FAILED_MESH");
    setenv("MVK_AMD_RENDER_ARCHIVE_DIR", "@MVK_STACK_ROOT@/build/game-metal-binary-cache/render-shards-v1", 1);
    setenv("MVK_AMD_RENDER_ARCHIVE_TRACE", "1", 1);
    setenv("MVK_AMD_RENDER_ARCHIVE_REHYDRATE", "1", 1);
    unsetenv("MVK_AMD_RENDER_ARCHIVE_REQUIRE_HIT");

    setenv("MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES", "1", 1);
    setenv("MVK_CONFIG_USE_MTLHEAP", "2", 1);
    setenv("MVK_AMD_BATCH_LIVE_USE_RESOURCE", "1", 1);
    setenv("MVK_AMD_BATCH_ARGUMENT_HEAPS", "1", 1);
    setenv("MVK_AMD_GPU_TIMEOUT_TRACE", "0", 1);
    setenv("MVK_AMD_QUEUE_TIMING", "1", 1);
    setenv("MVK_AMD_EFFECTIVE_CONFIG_PATH", "@MVK_PROFILE_EVIDENCE_DIR@/effective-config.json", 1);
    setenv("MVK_AMD_ENCODER_LIVE_CACHE", "1", 1);
    setenv("MVK_AMD_CROSS_ENCODER_LIVE_CACHE", "1", 1);
    setenv("MVK_AMD_LIVE_LOOKUP_FAST_CACHE", "1", 1);
    setenv("MVK_AMD_DESCRIPTOR_USE_CACHE", "1", 1);
    setenv("MVK_AMD_ARGUMENT_HEAP_THRESHOLD", "2", 1);
    setenv("MVK_AMD_RUNTIME_TRACE", "1", 1);
    setenv("MVK_AMD_RUNTIME_REPLAY_ONLY", "1", 1);
    setenv("MVK_CONFIG_SHADER_DUMP_DIR", "@MVK_PROFILE_EVIDENCE_DIR@/msl", 1);
    setenv("MVK_AMD_COMPUTE_ARCHIVE_DIR", "@MVK_STACK_ROOT@/build/game-metal-binary-cache/compute-shards-v3", 1);
    setenv("MVK_AMD_COMPUTE_ARCHIVE_TRACE", "1", 1);
    setenv("MVK_AMD_COMPUTE_ARCHIVE_REHYDRATE", "1", 1);
    setenv("VKD3D_DEBUG", "info", 1);
    setenv("VKD3D_LOG_FILE", "Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\open-game-stack-20261015\\evidence\\effective-submission-profile-20261020\\vkd3d-game.log", 1);
    setenv("YYB_OPEN_GUARD_RECORD", "@MVK_PROFILE_EVIDENCE_DIR@/guard-proxy.trace", 1);
    append_record("step=effective-submission-profile-ready encoderLive=1 crossEncoderLive=1 heapThreshold=2 argumentHeaps=1 queueTiming=1 fullWorkTrace=0");
}
