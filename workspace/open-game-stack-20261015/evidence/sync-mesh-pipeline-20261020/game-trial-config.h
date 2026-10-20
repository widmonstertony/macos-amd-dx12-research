// Game-only trial settings. Original asset guard remains unchanged.
static void append_record(const char *message);
static void mvk_apply_game_trial_config(void) {
    unsetenv("MVK_AMD_QUEUE_DEPENDENCY_DUMP_ALL");
    setenv("MVK_AMD_SERIALIZE_PIPELINE_LINK", "1", 1);
    setenv("MVK_AMD_FRESH_MESH_LIBRARIES", "1", 1);
    setenv("MVK_AMD_SAFE_MESH_LIBRARIES", "1", 1);
    setenv("MVK_AMD_SYNC_MESH_LIBRARIES", "1", 1);
    setenv("MVK_AMD_SYNC_MESH_PIPELINES", "1", 1);
    unsetenv("MVK_AMD_REPLAY_FAILED_MESH");
    setenv("MVK_AMD_RENDER_ARCHIVE_DIR", "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/game-metal-binary-cache/render-shards-v1", 1);
    setenv("MVK_AMD_RENDER_ARCHIVE_TRACE", "1", 1);
    unsetenv("MVK_AMD_RENDER_ARCHIVE_REQUIRE_HIT");

    setenv("MVK_CONFIG_SPECIALIZED_QUEUE_FAMILIES", "1", 1);
    setenv("MVK_AMD_GPU_TIMEOUT_TRACE", "1", 1);
    setenv("MVK_AMD_RUNTIME_TRACE", "1", 1);
    setenv("MVK_AMD_RUNTIME_REPLAY_ONLY", "1", 1);
    setenv("MVK_CONFIG_SHADER_DUMP_DIR", "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/evidence/sync-mesh-pipeline-20261020/msl", 1);
    setenv("MVK_AMD_COMPUTE_ARCHIVE_DIR", "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/build/game-metal-binary-cache/compute-shards-v3", 1);
    setenv("MVK_AMD_COMPUTE_ARCHIVE_TRACE", "1", 1);
    setenv("VKD3D_DEBUG", "info", 1);
    setenv("VKD3D_LOG_FILE", "Z:\\Documents\\GitHub\\gptk-intel-research-20261011\\open-game-stack-20261015\\evidence\\sync-mesh-pipeline-20261020\\vkd3d-game.log", 1);
    setenv("YYB_OPEN_GUARD_RECORD", "/Users/tonytan/Documents/GitHub/gptk-intel-research-20261011/open-game-stack-20261015/evidence/sync-mesh-pipeline-20261020/guard-proxy.trace", 1);
    append_record("step=synchronous-mesh-libraries-and-pipelines-fresh-safe-serialized-no-retry-ready");
}
