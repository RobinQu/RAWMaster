#import "shared.h"

static int emit(NSDictionary *d) {
  NSData *bytes = JSONBytes(d);
  if (!bytes)
    return 2;
  fwrite(bytes.bytes, 1, bytes.length, stdout);
  fputc('\n', stdout);
  return 0;
}
static NSDictionary *failed(xpc_object_t r, NSString *stage, BOOL sent) {
  const char *s = r && xpc_get_type(r) == XPC_TYPE_ERROR
                      ? xpc_dictionary_get_string(r, XPC_ERROR_KEY_DESCRIPTION)
                      : NULL;
  return @{
    @"error" : s ? @(s) : @"no authenticated response",
    @"phase" : stage,
    @"sentCapabilities" : @(sent),
    @"callerPID" : @(getpid())
  };
}
static NSData *bookmark(NSString *path, NSString *kind, NSError **err) {
  if (!path || [kind isEqual:@"none"])
    return nil;
  NSURLBookmarkCreationOptions options = 0;
  if ([kind isEqual:@"noScope"])
    options = NSURLBookmarkCreationWithoutImplicitSecurityScope;
  else if ([kind isEqual:@"persistent"])
    options = NSURLBookmarkCreationWithSecurityScope |
              NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess;
  else if (![kind isEqual:@"implicit"] && ![kind isEqual:@"fresh"])
    return nil;
  return [[NSURL fileURLWithPath:path] bookmarkDataWithOptions:options
                                includingResourceValuesForKeys:nil
                                                 relativeToURL:nil
                                                         error:err];
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2 || strlen(argv[1]) != 40)
      return 2;
    NSData *in =
        [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSDictionary *task = decodeJSON(in.bytes, in.length);
    if (!task)
      return 3;
    xpc_connection_t cn = xpc_connection_create(AA_SERVICE_ID, NULL);
    NSString *req =
        [NSString stringWithFormat:@"identifier \"%s\" and cdhash H\"%s\"",
                                   AA_SERVICE_ID, argv[1]];
    int status =
        xpc_connection_set_peer_code_signing_requirement(cn, req.UTF8String);
    if (status)
      return emit(
          @{@"requirementStatus" : @(status),
            @"sentCapabilities" : @NO});
    xpc_connection_set_event_handler(cn, ^(xpc_object_t ignored){
                                     });
    xpc_connection_activate(cn);
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, "op", "hello");
    xpc_object_t ready = exchange(cn, hello);
    if (!ready || xpc_get_type(ready) != XPC_TYPE_DICTIONARY)
      return emit(failed(ready, @"hello", NO));
    pid_t pid = xpc_connection_get_pid(cn);
    if (pid <= 0 || pid == getpid() ||
        pid != xpc_dictionary_get_int64(ready, "service") ||
        getpid() != xpc_dictionary_get_int64(ready, "caller") ||
        getuid() != xpc_connection_get_euid(cn))
      return emit(failed(NULL, @"peer", NO));
    NSString *op = stringValue(task[@"op"]);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", op.UTF8String);
    putData(m, "body", JSONBytes(task[@"body"] ?: @{}));
    NSMutableDictionary *bookStats = [NSMutableDictionary dictionary];
    for (NSString *role in task[@"scopes"]) {
      NSDictionary *cfg = task[@"scopes"][role];
      NSError *err = nil;
      NSString *kind = stringValue(cfg[@"kind"]);
      NSString *path = stringValue(cfg[@"path"]);
      NSString *fdKey = [role isEqual:@"catalog"] ? @"directory" : role;
      NSNumber *roleFD = task[@"fds"][fdKey],
               *parentFD = task[@"fds"][@"parent"];
      BOOL matched =
          roleFD && parentFD && sameFile(roleFD.intValue, path) &&
          sameFile(parentFD.intValue, path.stringByDeletingLastPathComponent);
      if (!matched && ![task[@"fixtureMismatch"] boolValue])
        return emit(@{@"phase" : @"origin", @"sentCapabilities" : @NO});
      NSData *bytes = bookmark(path, kind, &err);
      bookStats[role] = @{
        @"kind" : kind,
        @"bytes" : @(bytes.length),
        @"error" : @(err.code),
        @"issuerMatchedFD" : @(matched)
      };
      NSString *key = [@"book-" stringByAppendingString:role];
      putData(m, key.UTF8String, bytes);
    }
    for (NSString *role in task[@"fds"]) {
      int fd = [task[@"fds"][role] intValue];
      if (fcntl(fd, F_GETFD) < 0 ||
          (fcntl(fd, F_GETFL) & O_ACCMODE) != O_RDONLY)
        return 5;
      xpc_dictionary_set_fd(m, role.UTF8String, fd);
    }
    xpc_object_t answer = exchange(cn, m);
    if (!answer || xpc_get_type(answer) != XPC_TYPE_DICTIONARY)
      return emit(failed(answer, @"operation", YES));
    NSData *reply = getData(answer, "result");
    NSDictionary *obj = decodeJSON(reply.bytes, reply.length);
    if (!obj)
      return 6;
    return emit(@{
      @"callerPID" : @(getpid()),
      @"workerPID" : @(pid),
      @"serviceSawCaller" : @(xpc_dictionary_get_int64(ready, "caller")),
      @"launchParent" : @(xpc_dictionary_get_int64(ready, "parent")),
      @"runtimeSandboxEntitlement" :
          @(xpc_dictionary_get_bool(ready, "sandbox")),
      @"variant" : @(AA_VARIANT),
      @"hostUID" : @(getuid()),
      @"workerUID" : @(xpc_connection_get_euid(cn)),
      @"bookmarks" : bookStats,
      @"sentCapabilities" : @YES,
      @"result" : obj
    });
  }
}
