// Keep a current bounded diagnostic snapshot after a historical journal fills.
// The caller serializes writes and supplies its own process-specific paths.
#pragma once
#include <cstdio>

inline bool mvkWriteTraceSnapshot(const char* path, const char* json) {
    char temporary[4096];
    int n = snprintf(temporary, sizeof(temporary), "%s.tmp", path);
    if (n < 0 || static_cast<size_t>(n) >= sizeof(temporary)) return false;
    FILE* file = fopen(temporary, "w");
    if (!file) return false;
    bool written = fputs(json, file) >= 0;
    if (fclose(file)) written = false;
    if (written && !rename(temporary, path)) return true;
    remove(temporary);
    return false;
}
