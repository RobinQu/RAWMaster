/* Used by the signed worker and a separately compiled same-identifier control.
 */
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

int rm_z_grants(const char *name, int out[4]) {
  struct sockaddr_un to = {0};
  if (!name || !*name || strlen(name) >= sizeof(to.sun_path))
    return -1;
  to.sun_family = AF_UNIX;
  strcpy(to.sun_path, name);
  to.sun_len = (unsigned char)(offsetof(struct sockaddr_un, sun_path) +
                               strlen(name) + 1);
  int sock = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sock < 0)
    return -1;
  if (connect(sock, (struct sockaddr *)&to, to.sun_len) < 0) {
    perror("restricted worker connect");
    close(sock);
    return -1;
  }
  unsigned char allowed = 0;
  struct iovec iov = {&allowed, 1};
  union {
    struct cmsghdr align;
    char bytes[CMSG_SPACE(4 * sizeof(int))];
  } control = {0};
  struct msghdr message = {0};
  message.msg_iov = &iov;
  message.msg_iovlen = 1;
  message.msg_control = control.bytes;
  message.msg_controllen = sizeof(control.bytes);
  ssize_t n = recvmsg(sock, &message, 0);
  int count = 0;
  int valid = n == 1 && !(message.msg_flags & (MSG_CTRUNC | MSG_TRUNC));
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&message); c && n > 0;
       c = CMSG_NXTHDR(&message, c)) {
    if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS ||
        c->cmsg_len < CMSG_LEN(0)) {
      valid = 0;
      continue;
    }
    size_t len = c->cmsg_len - CMSG_LEN(0);
    if (len % sizeof(int))
      valid = 0;
    for (size_t i = 0; i < len / sizeof(int); i++) {
      int fd = -1;
      memcpy(&fd, (unsigned char *)CMSG_DATA(c) + i * sizeof(fd), sizeof(fd));
      if (count < 4) {
        out[count++] = fd;
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0)
          valid = 0;
      } else {
        close(fd);
        valid = 0;
      }
    }
  }
  close(sock);
  if (valid && allowed == 0 && count == 0)
    return 0;
  if (valid && allowed == 1 && count == 4) {
    for (int i = 0; i < 4; i++) {
      struct stat st;
      int f = fcntl(out[i], F_GETFL);
      if (f < 0 || (f & O_ACCMODE) != O_RDONLY || fstat(out[i], &st) < 0 ||
          (i == 0 ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode)))
        valid = 0;
    }
    if (valid)
      return 1;
  }
  for (int i = 0; i < count; i++)
    close(out[i]);
  return -1;
}
static int attempt(int df, const char *name, int flags) {
  int fd = openat(df, name, flags | O_NOFOLLOW, 0600);
  if (fd < 0)
    return errno;
  close(fd);
  return 0;
}
int rm_z_access_control(const int fds[4], const char *absoluteSibling) {
  char header[16] = {0};
  int headerok = pread(fds[1], header, sizeof(header), 0) == sizeof(header) &&
                 !memcmp(header, "SQLite format 3\0", 16);
  int rd = attempt(fds[0], "withheld.bin", O_RDONLY),
      wr = attempt(fds[0], "withheld.bin", O_RDWR);
  int make = attempt(fds[0], "probe-create.bin", O_WRONLY | O_CREAT | O_EXCL);
  int rename = renameat(fds[0], "rename-source.bin", fds[0],
                        "rename-destination.bin") < 0
                   ? errno
                   : 0;
  int sibling = attempt(AT_FDCWD, absoluteSibling, O_RDONLY);
  printf("{\"authorizedSQLiteHeaderRead\":%d,\"withheldReadErrno\":%d,"
         "\"withheldReadWriteErrno\":%d,\"unauthorizedCreateErrno\":%d,"
         "\"unauthorizedRenameErrno\":%d,\"siblingReadErrno\":%d}\n",
         headerok, rd, wr, make, rename, sibling);
  fflush(stdout);
  return headerok ? 0 : 1;
}
#ifdef OTHER_FIXTURE_SIGNER_BODY
int main(int argc, char **argv) {
  int fds[4] = {-1, -1, -1, -1};
  (void)argc;
  (void)argv;
  int r = rm_z_grants("broker.sock", fds);
  int direct = attempt(AT_FDCWD, "library.sqlite", O_RDONLY);
  printf("{\"alternateProgram\":true,\"receivedCapability\":%d,"
         "\"ungrantedMainReadErrno\":%d}\n",
         r, direct);
  return r == 0 ? 0 : 1;
}
#endif
