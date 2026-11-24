#import "shared.h"
#include <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include <pthread.h>
#include <sys/attr.h>
#include <sys/mount.h>

typedef struct {
  unsigned char *data;
  size_t length;
} LibraryBytes;
extern int rm_library_request_v1(const unsigned char *, size_t,
                                 const unsigned char *, size_t, LibraryBytes *);
extern void rm_library_release_v1(LibraryBytes *);
extern int (*rm_library_sqlite_identity_v1(void))(void);
extern int sqlite3_libversion_number(void);
extern const char *sqlite3_sourceid(void);
extern char *rm_aa_drain_log(void);
extern void rm_aa_release_log(char *);
static pthread_mutex_t exclusive = PTHREAD_MUTEX_INITIALIZER;

static NSString *trustedHostHash(void) {
  NSData *signedData = [NSData dataWithContentsOfFile:@AA_POLICY];
  NSDictionary *pin = decodeJSON(signedData.bytes, signedData.length);
  NSString *hash = stringValue(pin[@"hash"]);
  if (hash.length != 40 ||
      [hash rangeOfCharacterFromSet:[[NSCharacterSet
                                        characterSetWithCharactersInString:
                                            @"0123456789abcdef"] invertedSet]]
              .location != NSNotFound)
    return nil;
  NSData *message =
      [[NSString stringWithFormat:@"RawMaster-AA peer\n%s\n%@\n", AA_HOST_ID,
                                  hash] dataUsingEncoding:NSUTF8StringEncoding];
  NSData *sig = [[[NSData alloc]
      initWithBase64EncodedString:stringValue(pin[@"signature"]) ?: @""
                          options:0] autorelease];
  const unsigned char pub[] = AA_PUBLIC_BYTES;
  NSDictionary *attrs = @{
    (id)kSecAttrKeyType : (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
    (id)kSecAttrKeySizeInBits : @256
  };
  NSData *pubData = [NSData dataWithBytes:pub length:sizeof(pub)];
  SecKeyRef key =
      SecKeyCreateWithData((CFDataRef)pubData, (CFDictionaryRef)attrs, NULL);
  if (!key || !sig) {
    if (key)
      CFRelease(key);
    return nil;
  }
  BOOL ok = SecKeyVerifySignature(
      key, kSecKeyAlgorithmECDSASignatureMessageX962SHA256, (CFDataRef)message,
      (CFDataRef)sig, NULL);
  CFRelease(key);
  return ok ? hash : nil;
}
static BOOL sandboxEntitled(void) {
  SecTaskRef task = SecTaskCreateFromSelf(NULL);
  CFTypeRef v = task ? SecTaskCopyValueForEntitlement(
                           task, CFSTR("com.apple.security.app-sandbox"), NULL)
                     : NULL;
  BOOL result = v && CFEqual(kCFBooleanTrue, v);
  if (v)
    CFRelease(v);
  if (task)
    CFRelease(task);
  return result;
}
static BOOL sameVnode(const struct stat *a, const struct stat *b) {
  return a->st_dev == b->st_dev && a->st_ino == b->st_ino &&
         a->st_birthtimespec.tv_sec == b->st_birthtimespec.tv_sec &&
         a->st_birthtimespec.tv_nsec == b->st_birthtimespec.tv_nsec &&
         (a->st_mode & S_IFMT) == (b->st_mode & S_IFMT);
}
static int volumeUUID(int fd, unsigned char dst[16]) {
  struct attrlist req = {.bitmapcount = ATTR_BIT_MAP_COUNT,
                         .commonattr = ATTR_CMN_RETURNED_ATTRS,
                         .volattr = ATTR_VOL_INFO | ATTR_VOL_UUID};
  struct {
    uint32_t length;
    attribute_set_t returned;
    unsigned char uuid[16];
  } got = {0};
  if (fgetattrlist(fd, &req, &got, sizeof(got), 0))
    return errno;
  unsigned char zero[16] = {0}, sentinel[16];
  memset(sentinel, 255, 16);
  if (got.length != sizeof(got) || !(got.returned.volattr & ATTR_VOL_UUID) ||
      !memcmp(got.uuid, zero, 16) || !memcmp(got.uuid, sentinel, 16))
    return EINVAL;
  memcpy(dst, got.uuid, 16);
  return 0;
}
static BOOL roleMatches(int fd, int parent, NSString *expected, NSURL *url,
                        NSMutableDictionary *fact) {
  if (fd < 0 || parent < 0 || ![expected isEqual:url.path])
    return NO;
  struct stat a, b;
  struct statfs fs;
  NSString *base = expected.lastPathComponent;
  if (fstat(fd, &a) ||
      !sameFile(parent, expected.stringByDeletingLastPathComponent) ||
      fstatat(parent, base.fileSystemRepresentation, &b, AT_SYMLINK_NOFOLLOW) ||
      !sameVnode(&a, &b) || !sameFile(fd, expected) || fstatfs(fd, &fs) ||
      strcmp(fs.f_fstypename, "apfs") || !(fs.f_flags & MNT_LOCAL))
    return NO;
  int named = openat(parent, base.fileSystemRepresentation,
                     O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                         (S_ISDIR(a.st_mode) ? O_DIRECTORY : 0));
  if (named < 0) {
    fact[@"namedErrno"] = @(errno);
    return NO;
  }
  unsigned char held[16] = {0}, current[16] = {0};
  int e = volumeUUID(fd, held), f = volumeUUID(named, current);
  BOOL inode = fstat(named, &b) == 0 && sameVnode(&a, &b);
  close(named);
  fact[@"matchedVnode"] = @(inode);
  fact[@"heldVolumeErrno"] = @(e);
  fact[@"visibleVolumeErrno"] = @(f);
  BOOL same = inode && !e && !f && !memcmp(held, current, 16);
  fact[@"matchedAPFSVolume"] = @(same);
  return same;
}
static int sampleWriteAccess(int held) {
  struct stat st;
  if (fstat(held, &st))
    return errno;
  int raw;
  if (S_ISDIR(st.st_mode))
    raw = openat(held, ".scope-witness", O_RDWR | O_NOFOLLOW | O_CLOEXEC);
  else {
    char p[PATH_MAX];
    if (fcntl(held, F_GETPATH, p))
      return errno;
    raw = open(p, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
  }
  if (raw < 0)
    return errno;
  close(raw);
  return 0;
}
static NSURL *startScope(xpc_object_t m, const char *key, NSString *kind,
                         int fd, int parent, NSString *expected,
                         NSMutableDictionary *fact) {
  NSData *bytes = getData(m, key);
  if (!bytes) {
    fact[@"received"] = @NO;
    return nil;
  }
  fact[@"received"] = @YES;
  NSURLBookmarkResolutionOptions flags =
      NSURLBookmarkResolutionWithoutUI |
      NSURLBookmarkResolutionWithoutMounting |
      NSURLBookmarkResolutionWithoutImplicitStartAccessing;
  BOOL explicitStore = [kind isEqual:@"persistent"];
  if (explicitStore)
    flags = NSURLBookmarkResolutionWithoutUI |
            NSURLBookmarkResolutionWithoutMounting |
            NSURLBookmarkResolutionWithSecurityScope;
  BOOL stale = NO;
  NSError *err = nil;
  NSURL *u = [NSURL URLByResolvingBookmarkData:bytes
                                       options:flags
                                 relativeToURL:nil
                           bookmarkDataIsStale:&stale
                                         error:&err];
  fact[@"resolved"] = @(u != nil);
  fact[@"stale"] = @(stale);
  fact[@"resolutionError"] = @(err.code);
  // Only a contemporaneous implicit grant from this authenticated requester can
  // be reissued.
  // Observe the name-only control even when Foundation calls it stale. Its
  // result never admits a request.
  if (u && [kind isEqual:@"noScope"]) {
    BOOL started = [u startAccessingSecurityScopedResource];
    fact[@"nameOnlyStart"] = @(started);
    fact[@"nameOnlyReadErrno"] = @(readPath(expected));
    if (started)
      [u stopAccessingSecurityScopedResource];
    return nil;
  }
  if (!u || (stale && ![kind isEqual:@"fresh"]))
    return nil;
  BOOL first = [u startAccessingSecurityScopedResource];
  fact[@"firstStart"] = @(first);
  if (!first)
    return nil;
  if (!roleMatches(fd, parent, expected, u, fact)) {
    [u stopAccessingSecurityScopedResource];
    return nil;
  }
  if (!stale)
    return u;
  int firstWrite = sampleWriteAccess(fd);
  fact[@"firstWriteOpenErrno"] = @(firstWrite);
  NSData *replacement = [u bookmarkDataWithOptions:0
                    includingResourceValuesForKeys:nil
                                     relativeToURL:nil
                                             error:&err];
  BOOL secondStale = YES;
  NSURL *next = replacement ? [NSURL URLByResolvingBookmarkData:replacement
                                                        options:flags
                                                  relativeToURL:nil
                                            bookmarkDataIsStale:&secondStale
                                                          error:&err]
                            : nil;
  fact[@"reissued"] = @(replacement != nil);
  fact[@"secondStale"] = @(secondStale);
  BOOL second =
      next && !secondStale && [next startAccessingSecurityScopedResource];
  fact[@"secondStart"] = @(second);
  BOOL matched = second && roleMatches(fd, parent, expected, next, fact);
  [u stopAccessingSecurityScopedResource];
  // Both checks are needed across the handoff and after balancing the first
  // grant.
  if (!matched || !roleMatches(fd, parent, expected, next, fact)) {
    if (second)
      [next stopAccessingSecurityScopedResource];
    return nil;
  }
  int refreshedWrite = sampleWriteAccess(fd);
  fact[@"refreshedWriteOpenErrno"] = @(refreshedWrite);
  if (firstWrite != 0 && refreshedWrite == 0) {
    [next stopAccessingSecurityScopedResource];
    return nil;
  }
  return next;
}
static int writeOpen(NSString *p) {
  if (!p)
    return EINVAL;
  int fd = open(p.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0)
    return errno;
  close(fd);
  return 0;
}
static NSString *fileHash(int fd) {
  struct stat s;
  if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size < 1 ||
      s.st_size > 128 * 1024)
    return nil;
  NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)s.st_size];
  if (pread(fd, d.mutableBytes, d.length, 0) != (ssize_t)d.length)
    return nil;
  unsigned char sum[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(d.bytes, (CC_LONG)d.length, sum);
  NSMutableString *value = [NSMutableString string];
  for (size_t i = 0; i < sizeof(sum); i++)
    [value appendFormat:@"%02x", sum[i]];
  return value;
}
static NSDictionary *photo(xpc_object_t m, NSDictionary *body) {
  NSString *path = stringValue(body[@"asset"]),
           *other = stringValue(body[@"withheld"]);
  if (![path.lastPathComponent isEqual:@"asset.jpg"] ||
      ![other.lastPathComponent isEqual:@"withheld.jpg"] ||
      ![[path stringByDeletingLastPathComponent]
          isEqual:[other stringByDeletingLastPathComponent]])
    return @{@"reason" : @"invalid fixture role"};
  int fd = xpc_dictionary_dup_fd(m, "asset");
  if (fd < 0)
    return @{@"reason" : @"missing asset descriptor"};
  struct stat st;
  BOOL valid = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
               (fcntl(fd, F_GETFL) & O_ACCMODE) == O_RDONLY;
  NSString *hash = valid ? fileHash(fd) : nil;
  NSMutableDictionary *fact = [NSMutableDictionary dictionary];
  fact[@"freshReadBefore"] = @(readPath(path));
  fact[@"freshWriteBefore"] = @(writeOpen(path));
  if (valid) {
    char one = 0;
    ssize_t r = pread(fd, &one, 1, 0);
    ssize_t n = r == 1 ? pwrite(fd, &one, 1, 0) : 0;
    fact[@"heldWriteErrno"] = @(n < 0 ? errno : 0);
  }
  fact[@"readOnlyFD"] = @(valid);
  fact[@"fdSHA256"] = hash ?: @"";
  fact[@"bytes"] = @(valid ? st.st_size : 0);
  if (valid)
    fact[@"fdInode"] = @(st.st_ino);
  int parent = xpc_dictionary_dup_fd(m, "parent");
  NSURL *u = startScope(m, "book-asset", body[@"kind"], fd, parent, path, fact);
  fact[@"freshReadDuring"] = @(readPath(path));
  fact[@"freshWriteDuring"] = @(writeOpen(path));
  fact[@"freshSiblingRead"] = @(readPath(other));
  fact[@"freshSiblingWrite"] = @(writeOpen(other));
  fact[@"matchedFD"] = @(u && sameFile(fd, u.path) && [u.path isEqual:path]);
  if (u)
    [u stopAccessingSecurityScopedResource];
  fact[@"freshReadAfter"] = @(readPath(path));
  fact[@"freshWriteAfter"] = @(writeOpen(path));
  if (parent >= 0)
    close(parent);
  if (close(fd) != 0)
    fact[@"closeErrno"] = @(errno);
  return fact;
}

static NSDictionary *queueCommand(xpc_object_t m, NSDictionary *body) {
  NSDictionary *cmd = body[@"command"];
  NSString *action = stringValue(cmd[@"action"]);
  NSArray *allowed = @[
    @"register", @"claimItem", @"prepareItem", @"publishItem",
    @"acknowledgeItem", @"items"
  ];
  NSString *declared = stringValue(body[@"catalog"]),
           *dest = stringValue(body[@"destination"]);
  if (![allowed containsObject:action] || !declared || !dest ||
      ![declared.lastPathComponent isEqual:@"catalog"] ||
      ![dest.lastPathComponent isEqual:@"delivery"])
    return @{@"reason" : @"unsupported role or method"};
  const char *roles[] = {"directory", "main", "wal", "shm", "destination"};
  int fds[5] = {-1, -1, -1, -1, -1};
  NSMutableDictionary *facts = [NSMutableDictionary dictionary];
  NSMutableDictionary *cScope = [NSMutableDictionary dictionary],
                      *dScope = [NSMutableDictionary dictionary];
  for (int i = 0; i < 5; i++)
    fds[i] = xpc_dictionary_dup_fd(m, roles[i]);
  int parent = xpc_dictionary_dup_fd(m, "parent");
  NSURL *c = startScope(m, "book-catalog", body[@"catalogKind"], fds[0], parent,
                        declared, cScope);
  NSURL *d = startScope(m, "book-destination", body[@"destinationKind"], fds[4],
                        parent, dest, dScope);
  facts[@"catalogScope"] = cScope;
  facts[@"destinationScope"] = dScope;
  BOOL fdOK = YES;
  for (int i = 0; i < 5; i++) {
    struct stat st;
    if (fds[i] < 0 || (fcntl(fds[i], F_GETFL) & O_ACCMODE) != O_RDONLY ||
        fstat(fds[i], &st) ||
        ((i == 0 || i == 4) ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode)))
      fdOK = NO;
  }
  facts[@"originalReadOnlyRoles"] = @(fdOK);
  BOOL cOK = fdOK && c && [declared isEqual:c.path] && sameFile(fds[0], c.path);
  BOOL dOK = fdOK && d && [dest isEqual:d.path] && sameFile(fds[4], d.path);
  facts[@"catalogMatchesHeld"] = @(cOK);
  facts[@"destinationMatchesHeld"] = @(dOK);
  BOOL needsDest = ![action isEqual:@"claimItem"] && ![action isEqual:@"items"];
  BOOL boundBody = !needsDest || [cmd[@"directory"] isEqual:dest];
  if (!cOK || (needsDest && !dOK) || !boundBody) {
    facts[@"reason"] = @"unavailable directory grant";
  } else {
    NSString *db = [c.path stringByAppendingPathComponent:@"library.sqlite"];
    NSArray *rolesOnDisk =
        @[ @"library.sqlite", @"library.sqlite-wal", @"library.sqlite-shm" ];
    BOOL namesMatch = YES;
    for (int i = 1; i <= 3; i++)
      if (!sameFile(fds[i],
                    [c.path stringByAppendingPathComponent:rolesOnDisk[i - 1]]))
        namesMatch = NO;
    facts[@"currentThreeObjects"] = @(namesMatch);
    if (!namesMatch)
      facts[@"reason"] = @"mismatched attachment";
    else {
      NSString *list = [NSString
          stringWithFormat:@"%d,%d,%d,%d", fds[0], fds[1], fds[2], fds[3]];
      NSData *request = JSONBytes(@{
        @"operation" : @"scheduler",
        @"request" : @{@"op" : @"workbenchBatch", @"command" : cmd}
      });
      LibraryBytes out = {0};
      char *old = rm_aa_drain_log();
      rm_aa_release_log(old);
      if (setenv("RM_MAC_GRANTS", list.UTF8String, 1) ||
          setenv("RM_MAC_DIRECTORY", c.path.fileSystemRepresentation, 1))
        abort();
      int rc = rm_library_request_v1(
          (const unsigned char *)db.fileSystemRepresentation,
          strlen(db.fileSystemRepresentation), request.bytes, request.length,
          &out);
      unsetenv("RM_MAC_GRANTS");
      unsetenv("RM_MAC_DIRECTORY");
      facts[@"status"] = @(rc);
      facts[@"answer"] = decodeJSON(out.data, out.length) ?: @{};
      rm_library_release_v1(&out);
      char *events = rm_aa_drain_log();
      if (events) {
        NSData *log = [NSData dataWithBytes:events length:strlen(events)];
        facts[@"txnChecks"] = [NSJSONSerialization JSONObjectWithData:log
                                                              options:0
                                                                error:NULL]
                                  ?: @[];
        rm_aa_release_log(events);
      }
      facts[@"sameSQLiteFunction"] =
          @(rm_library_sqlite_identity_v1() == sqlite3_libversion_number);
      facts[@"sqliteSourceID"] = @(sqlite3_sourceid());
    }
  }
  for (int i = 0; i < 5; i++)
    if (fds[i] >= 0)
      close(fds[i]);
  if (parent >= 0)
    close(parent);
  if (d)
    [d stopAccessingSecurityScopedResource];
  if (c)
    [c stopAccessingSecurityScopedResource];
  facts[@"freshMainReadAfterStop"] =
      @(readPath([declared stringByAppendingPathComponent:@"library.sqlite"]));
  return facts;
}
static void onPeer(xpc_connection_t peer) {
  @autoreleasepool {
    NSString *hash = trustedHostHash();
    NSString *need =
        [NSString stringWithFormat:@"identifier \"%s\" and cdhash H\"%@\"",
                                   AA_HOST_ID, hash ?: @""];
    if (!hash || xpc_connection_set_peer_code_signing_requirement(
                     peer, need.UTF8String)) {
      xpc_connection_cancel(peer);
      return;
    }
    xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
      @autoreleasepool {
        if (xpc_get_type(m) != XPC_TYPE_DICTIONARY)
          return;
        xpc_object_t r = xpc_dictionary_create_reply(m);
        if (!r)
          return;
        const char *op = xpc_dictionary_get_string(m, "op");
        if (!op)
          op = "";
        if (!strcmp(op, "hello")) {
          xpc_dictionary_set_int64(r, "service", getpid());
          xpc_dictionary_set_int64(r, "parent", getppid());
          xpc_dictionary_set_int64(r, "caller", xpc_connection_get_pid(peer));
          xpc_dictionary_set_bool(r, "sandbox", sandboxEntitled());
        } else {
          NSData *bs = getData(m, "body");
          NSDictionary *body = decodeJSON(bs.bytes, bs.length);
          pthread_mutex_lock(&exclusive);
          NSDictionary *result = nil;
          if (body && !strcmp(op, "photo"))
            result = photo(m, body);
          else if (body && !strcmp(op, "queue"))
            result = queueCommand(m, body);
          else
            result = @{@"reason" : @"unsupported typed command"};
          putData(r, "result", JSONBytes(result));
          pthread_mutex_unlock(&exclusive);
        }
        xpc_connection_send_message(peer, r);
        xpc_release(r);
      }
    });
    xpc_connection_activate(peer);
  }
}
int main(void) { xpc_main(onPeer); }
