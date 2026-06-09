#include <stdint.h>
#include <stdio.h>

typedef unsigned long long u64;

const char *human_size(uint64_t bytes) {
    static char buf[64];
    const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    double size = (double)bytes;
    int unit = 0;

    while (size >= 1024.0 && unit < 4) {
        size /= 1024.0;
        unit++;
    }

    if (unit == 0) {
        snprintf(buf, sizeof(buf), "%llu %s", (u64)bytes, units[unit]);
    } else {
        snprintf(buf, sizeof(buf), "%.1f %s", size, units[unit]);
    }
    return buf;
}
