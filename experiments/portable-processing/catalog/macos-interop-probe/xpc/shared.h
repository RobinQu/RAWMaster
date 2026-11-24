#include "aa-config.h"
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

static inline NSData *JSONBytes(id value) {
  return [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
}
static inline NSDictionary *decodeJSON(const void *p, size_t n) {
  if (!p || !n || n > 2 * 1024 * 1024)
    return nil;
  id obj = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:p
                                                                  length:n]
                                           options:0
                                             error:NULL];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}
static inline NSString *stringValue(id obj) {
  return [obj isKindOfClass:[NSString class]] ? obj : nil;
}
static inline int readPath(NSString *p) {
  if (!p)
    return EINVAL;
  int fd = open(p.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0)
    return errno;
  close(fd);
  return 0;
}
static inline BOOL sameFile(int fd, NSString *p) {
  struct stat held, visible;
  return p && fstat(fd, &held) == 0 &&
         lstat(p.fileSystemRepresentation, &visible) == 0 &&
         held.st_dev == visible.st_dev && held.st_ino == visible.st_ino &&
         held.st_birthtimespec.tv_sec == visible.st_birthtimespec.tv_sec &&
         held.st_birthtimespec.tv_nsec == visible.st_birthtimespec.tv_nsec;
}
static inline xpc_object_t exchange(xpc_connection_t cn, xpc_object_t msg) {
  __block xpc_object_t received = NULL;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  xpc_connection_send_message_with_reply(cn, msg, NULL, ^(xpc_object_t r) {
    received = xpc_retain(r);
    dispatch_semaphore_signal(done);
  });
  if (dispatch_semaphore_wait(
          done, dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC)))
    return NULL;
  return received;
}
static inline void putData(xpc_object_t dest, const char *key, NSData *value) {
  if (value)
    xpc_dictionary_set_data(dest, key, value.bytes, value.length);
}
static inline NSData *getData(xpc_object_t msg, const char *key) {
  size_t size = 0;
  const void *p = xpc_dictionary_get_data(msg, key, &size);
  if (!p || !size || size > 2 * 1024 * 1024)
    return nil;
  return [NSData dataWithBytes:p length:size];
}
