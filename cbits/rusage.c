/* getrusage(2) and sysconf(3) for run metrics (Metrics.Recorder, Metrics.Sampler). */
#include <stdint.h>
#include <sys/resource.h>

/* out[0] = user microseconds, out[1] = system microseconds,
 * out[2] = max resident set size in KiB. Returns 0 on success. */
int mndz_getrusage(int children, int64_t *out)
{
    struct rusage ru;
    if (getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &ru) != 0)
        return -1;
    out[0] = (int64_t)ru.ru_utime.tv_sec * 1000000 + (int64_t)ru.ru_utime.tv_usec;
    out[1] = (int64_t)ru.ru_stime.tv_sec * 1000000 + (int64_t)ru.ru_stime.tv_usec;
    out[2] = (int64_t)ru.ru_maxrss;
    return 0;
}

/* Page size for /proc/<pid>/stat rss (Metrics.Sampler). */
#include <unistd.h>

long mndz_page_size(void)
{
    return sysconf(_SC_PAGESIZE);
}
