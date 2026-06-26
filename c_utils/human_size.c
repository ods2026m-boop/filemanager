#include <stdint.h>
#include <stdio.h>

const char *human_size(uint64_t bytes) {
    static __thread char buf[64];
    const char *units[] = {"B", "KB", "MB", "GB", "TB"};
    double size = (double)bytes;
    int unit = 0;

    while (size >= 1024.0 && unit < 4) {
        size /= 1024.0;
        unit++;
    }

    if (unit == 0) {
        snprintf(buf, sizeof(buf), "%llu %s", (unsigned long long)bytes, units[unit]);
    } else {
        snprintf(buf, sizeof(buf), "%.1f %s", size, units[unit]);
    }
    return buf;
}
