#include <errno.h>
#include <fcntl.h>
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
static int (*underlying)(const char *, int, int);
static const char *target;
static int total, matching, valid;
static int relay(const char *name, int flags, int mode) {
    int fd = underlying(name, flags, mode), saved = errno;
    total++;
    if (fd >= 0 && !strcmp(name, target)) {
        struct stat held, named;
        matching++;
        valid = fstat(fd, &held) == 0 && lstat(target, &named) == 0 && S_ISREG(held.st_mode) &&
                held.st_ino == named.st_ino && held.st_dev == named.st_dev;
    }
    errno = saved;
    return fd;
}
int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    target = argv[1];
    sqlite3_vfs *v = sqlite3_vfs_find("unix");
    int usable = v && v->iVersion >= 3 && v->xGetSystemCall && v->xSetSystemCall;
    sqlite3_syscall_ptr old = usable ? v->xGetSystemCall(v, "open") : NULL;
    underlying = (int (*)(const char *, int, int))old;
    int install = old ? v->xSetSystemCall(v, "open", (sqlite3_syscall_ptr)relay) : SQLITE_NOTFOUND;
    int confirmed =
        install == SQLITE_OK && v->xGetSystemCall(v, "open") == (sqlite3_syscall_ptr)relay;
    sqlite3 *db = NULL;
    int opened = sqlite3_open_v2(
        target, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, "unix");
    int closed = sqlite3_close(db);
    int restore = install == SQLITE_OK ? v->xSetSystemCall(v, "open", old) : SQLITE_NOTFOUND;
    int restored = usable && v->xGetSystemCall(v, "open") == old;
    printf("{\"sourceID\":\"%s\",\"vfsVersion\":%d,\"originalNonNull\":%s,\"installRC\":%d,"
           "\"observedInstall\":%s,\"forwarded\":%d,\"observedOriginalFd\":%d,\"fstatMatches\":%s,"
           "\"openRC\":%d,\"closeRC\":%d,\"restoreRC\":%d,\"restored\":%s}\n",
           sqlite3_sourceid(), v ? v->iVersion : 0, old ? "true" : "false", install,
           confirmed ? "true" : "false", total, matching, valid ? "true" : "false", opened, closed,
           restore, restored ? "true" : "false");
    return !(opened == SQLITE_OK && closed == SQLITE_OK && restored);
}
