#include "identity.h"
#include <stdio.h>
int inspect_fd(int pid, int fd, VnodeID *out) {
    return seen_fd(pid, fd, out);
}
int inspect_region(int pid, uint64_t address, uint64_t length, VnodeID *out) {
    return seen_region(pid, address, length, out);
}
int inspect_pin(int fd, VnodeID *out) {
    *out = fd_id(fd);
    return usable(*out);
}
int exchange_files(const char *a, const char *b) {
    return renamex_np(a, b, RENAME_SWAP);
}
