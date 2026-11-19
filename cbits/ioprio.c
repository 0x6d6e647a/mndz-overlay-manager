/* Per-thread nice and I/O priority for process priority (Process.Priority.Apply). */
#define _GNU_SOURCE
#include <errno.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MNDZ_IOPRIO_WHO_PROCESS 1

/* ioprio_get(2) on one thread. Stores the raw value; returns 0 or errno. */
int mndz_ioprio_get(int tid, int *out)
{
    long r = syscall(SYS_ioprio_get, MNDZ_IOPRIO_WHO_PROCESS, tid);
    if (r < 0)
        return errno;
    *out = (int)r;
    return 0;
}

/* ioprio_set(2) on one thread. Returns 0 or errno. */
int mndz_ioprio_set(int tid, int value)
{
    if (syscall(SYS_ioprio_set, MNDZ_IOPRIO_WHO_PROCESS, tid, value) < 0)
        return errno;
    return 0;
}

/* getpriority(2) on one thread: -1 is a valid nice value, so the value and
 * errno are returned separately. Returns 0 or errno. */
int mndz_getpriority(int tid, int *out)
{
    errno = 0;
    int r = getpriority(PRIO_PROCESS, (id_t)tid);
    if (r == -1 && errno != 0)
        return errno;
    *out = r;
    return 0;
}

/* setpriority(2) on one thread. Returns 0 or errno. */
int mndz_setpriority(int tid, int nice)
{
    if (setpriority(PRIO_PROCESS, (id_t)tid, nice) != 0)
        return errno;
    return 0;
}

/* The calling OS thread's id. */
int mndz_gettid(void)
{
    return (int)syscall(SYS_gettid);
}
