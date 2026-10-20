/* Read-only stream-cache integrity check. Layout and checksum follow the
 * vendored vkd3d-proton cache.c and vkd3d_shader_main.c. This checks persisted
 * bytes, not whether native Metal pipelines are cached or rendered correctly. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static uint64_t mix(uint64_t h, uint32_t v) {
    return h * UINT64_C(0x100000001b3) ^ v;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 2; }
    struct stat before, after;
    if (fstat(fd, &before) || before.st_size < 48) { close(fd); return 2; }
    FILE *f = fdopen(fd, "rb");
    if (!f) { close(fd); return 2; }
    uint8_t header[48];
    if (fread(header, 1, sizeof(header), f) != sizeof(header)) return 2;
    uint64_t offset = 48, records = 0, bad = 0, counts[3] = {0};
    while ((uint64_t)before.st_size - offset >= 24) {
        struct { uint64_t key, checksum; uint32_t size, type; } e;
        if (fread(&e, 1, 24, f) != 24) break;
        uint64_t padded = ((uint64_t)e.size + 7) & ~UINT64_C(7);
        if (padded > (uint64_t)before.st_size - offset - 24) break;
        uint64_t h = UINT64_C(0xcbf29ce484222325), remaining = e.size;
        uint8_t buffer[65536];
        while (remaining) {
            size_t n = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
            if (fread(buffer, 1, n, f) != n) { fclose(f); return 2; }
            for (size_t i = 0; i < n; ++i) h = mix(h, buffer[i]);
            remaining -= n;
        }
        h = mix(mix(h, (uint32_t)e.key), (uint32_t)(e.key >> 32));
        h = mix(mix(h, e.size), e.type);
        if (h != e.checksum) ++bad;
        if (e.type < 3) ++counts[e.type]; else ++bad;
        ++records;
        offset += 24 + padded;
        if (fseeko(f, (off_t)offset, SEEK_SET)) { fclose(f); return 2; }
    }
    if (fstat(fd, &after)) { fclose(f); return 2; }
    int stable = before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec;
    printf("{\"readOnly\":true,\"bytes\":%llu,\"records\":%llu,"
           "\"SPIRV\":%llu,\"driverCache\":%llu,\"pipeline\":%llu,"
           "\"checksumOrTypeFailures\":%llu,\"unparsedBytes\":%llu,"
           "\"stableDuringRead\":%s}\n",
           (unsigned long long)before.st_size, (unsigned long long)records,
           (unsigned long long)counts[0], (unsigned long long)counts[1],
           (unsigned long long)counts[2], (unsigned long long)bad,
           (unsigned long long)((uint64_t)before.st_size - offset),
           stable ? "true" : "false");
    fclose(f);
    return bad || !stable || offset != (uint64_t)before.st_size;
}
