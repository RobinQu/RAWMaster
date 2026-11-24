/* Borrow live descriptors and the VFS's naturally mapped page. No
 * open/dup/close here. */
#include "sqlite3.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/vm_prot.h>
#include <stdint.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  uint64_t device, inode, birth_seconds, birth_nanos, size;
  uint32_t mode, access;
  unsigned char volume[16];
} MacFile;
static void local_id(const struct stat *s, MacFile *out) {
  memset(out, 0, sizeof(*out));
  out->device = (uint32_t)s->st_dev;
  out->inode = s->st_ino;
  out->birth_seconds = s->st_birthtimespec.tv_sec;
  out->birth_nanos = s->st_birthtimespec.tv_nsec;
  out->size = s->st_size;
  out->mode = s->st_mode;
}
int rm_mac_fd(int fd, MacFile *out) {
  struct stat s;
  struct statfs fs;
  if (fstat(fd, &s) || fstatfs(fd, &fs) || !(fs.f_flags & MNT_LOCAL) ||
      strcmp(fs.f_fstypename, "apfs"))
    return 0;
  struct attrlist req = {.bitmapcount = ATTR_BIT_MAP_COUNT,
                         .commonattr = ATTR_CMN_RETURNED_ATTRS,
                         .volattr = ATTR_VOL_INFO | ATTR_VOL_UUID};
  struct {
    uint32_t len;
    attribute_set_t returned;
    unsigned char uuid[16];
  } reply = {0};
  if (fgetattrlist(fd, &req, &reply, sizeof(reply), 0) ||
      reply.len != sizeof(reply) ||
      !(reply.returned.commonattr & ATTR_CMN_RETURNED_ATTRS) ||
      !(reply.returned.volattr & ATTR_VOL_UUID))
    return 0;
  local_id(&s, out);
  memcpy(out->volume, reply.uuid, 16);
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || !out->birth_seconds || !out->inode)
    return 0;
  out->access = flags & O_ACCMODE;
  return 1;
}
int rm_mac_named(int directory, const char *name, MacFile *out) {
  struct stat s;
  if (fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW))
    return 0;
  local_id(&s, out);
  return 1;
}
int rm_mac_mapping(sqlite3 *db, const MacFile *shm, uint64_t result[7]) {
  RmPage page = {0};
  struct proc_regionwithpathinfo region = {0};
  if (rm_page_for(db, &page) != SQLITE_OK || !page.opening || !page.mapping ||
      !page.addr || page.bytes != 32768)
    return 0;
  if (proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, page.addr, &region,
                   sizeof(region)) != (int)sizeof(region))
    return 0;
  const struct proc_regioninfo *r = &region.prp_prinfo;
  const struct vinfo_stat *v = &region.prp_vip.vip_vi.vi_stat;
  result[0] = page.opening;
  result[1] = page.mapping;
  result[2] = page.bytes;
  result[3] = r->pri_size;
  result[4] = r->pri_protection;
  result[5] = r->pri_share_mode;
  result[6] = r->pri_offset;
  return r->pri_address == page.addr && r->pri_offset == 0 &&
         r->pri_size >= page.bytes && (r->pri_protection & VM_PROT_READ) &&
         (r->pri_share_mode == SM_SHARED ||
          r->pri_share_mode == SM_TRUESHARED ||
          r->pri_share_mode == SM_SHARED_ALIASED) &&
         (uint32_t)v->vst_dev == shm->device && v->vst_ino == shm->inode &&
         v->vst_birthtime == shm->birth_seconds &&
         v->vst_birthtimensec == shm->birth_nanos;
}
const char *rm_mac_sqlite_image(void) {
  Dl_info origin = {0};
  return dladdr((void *)sqlite3_libversion_number, &origin) ? origin.dli_fname
                                                            : "";
}
