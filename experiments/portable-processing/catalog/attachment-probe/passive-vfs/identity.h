#ifndef RM_PROBE_IDENTITY
#define RM_PROBE_IDENTITY
#include <libproc.h>
#include <stdint.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>
typedef struct {
    uint64_t device, inode, birth, nanoseconds;
} VnodeID;
static inline int usable(VnodeID x) {
    return x.inode && x.birth && x.nanoseconds < 1000000000;
}
static inline int identical(VnodeID x, VnodeID y) {
    return usable(x) && usable(y) && x.device == y.device && x.inode == y.inode &&
           x.birth == y.birth && x.nanoseconds == y.nanoseconds;
}
static inline VnodeID fd_id(int fd) {
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode))
        return (VnodeID){0};
    return (VnodeID){(uint32_t)st.st_dev, st.st_ino, (uint64_t)st.st_birthtimespec.tv_sec,
                     (uint64_t)st.st_birthtimespec.tv_nsec};
}
static inline VnodeID vnode_id(struct vnode_info v) {
    struct vinfo_stat s = v.vi_stat;
    if (v.vi_type != VREG || !S_ISREG(s.vst_mode))
        return (VnodeID){0};
    return (VnodeID){s.vst_dev, s.vst_ino, (uint64_t)s.vst_birthtime,
                     (uint64_t)s.vst_birthtimensec};
}
static inline int seen_fd(pid_t pid, int fd, VnodeID *id) {
    struct vnode_fdinfo result = {0};
    int bytes = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEINFO, &result, sizeof(result));
    *id = (VnodeID){0};
    if (bytes != (int)sizeof(result))
        return 0;
    *id = vnode_id(result.pvi);
    return usable(*id);
}
static inline int seen_region(pid_t pid, uint64_t address, uint64_t len, VnodeID *id) {
    struct proc_regionwithpathinfo r = {0};
    *id = (VnodeID){0};
    if (!address || !len)
        return 0;
    int bytes = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &r, sizeof(r));
    if (bytes != (int)sizeof(r) || r.prp_prinfo.pri_address != address ||
        r.prp_prinfo.pri_offset != 0 || len > r.prp_prinfo.pri_size)
        return 0;
    *id = vnode_id(r.prp_vip.vip_vi);
    return usable(*id);
}
#endif
