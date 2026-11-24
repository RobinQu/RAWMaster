/* Reads identity for the kernel's connected socket peer before any rights are
 * sent. */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define CODE_ID "org.rawmaster.fixture.catalog035-restricted"

int main(int argc, char **argv) {
  if (argc != 4 || strlen(argv[3]) != 40 ||
      strspn(argv[3], "0123456789abcdef") != 40)
    return 2;
  int fd = atoi(argv[1]);
  pid_t expected = (pid_t)atoi(argv[2]), peer = 0;
  audit_token_t token = {0};
  socklen_t size = sizeof(token), psize = sizeof(peer);
  uid_t uid = (uid_t)-1;
  gid_t gid = (gid_t)-1;
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) != 0 ||
      size != sizeof(token) ||
      getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &psize) != 0 ||
      psize != sizeof(peer) || getpeereid(fd, &uid, &gid) != 0)
    return 3;
  CFDataRef token_data = CFDataCreate(NULL, (UInt8 *)&token, sizeof(token));
  const void *keys[] = {kSecGuestAttributeAudit}, *values[] = {token_data};
  CFDictionaryRef attrs =
      CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                         &kCFTypeDictionaryValueCallBacks);
  SecCodeRef guest = NULL;
  SecStaticCodeRef backing = NULL;
  SecRequirementRef req = NULL;
  CFDictionaryRef info = NULL;
  OSStatus locate =
      SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &guest);
  char text[128];
  snprintf(text, sizeof(text), "identifier \"%s\" and cdhash H\"%s\"", CODE_ID,
           argv[3]);
  CFStringRef expression =
      CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
  OSStatus reqrc =
      SecRequirementCreateWithString(expression, kSecCSDefaultFlags, &req);
  OSStatus dynamic = guest && req
                         ? SecCodeCheckValidity(guest, kSecCSDefaultFlags, req)
                         : errSecParam;
  OSStatus plain = guest ? SecCodeCheckValidity(guest, kSecCSDefaultFlags, NULL)
                         : errSecParam;
  OSStatus sr = guest
                    ? SecCodeCopyStaticCode(guest, kSecCSDefaultFlags, &backing)
                    : errSecParam;
  OSStatus sign = sr == errSecSuccess
                      ? SecCodeCopySigningInformation(
                            backing, kSecCSSigningInformation, &info)
                      : errSecParam;
  char digest[65] = {0};
  int identifier = 0;
  if (sign == errSecSuccess && info) {
    CFDataRef h = CFDictionaryGetValue(info, kSecCodeInfoUnique);
    CFStringRef id = CFDictionaryGetValue(info, kSecCodeInfoIdentifier);
    if (h && CFGetTypeID(h) == CFDataGetTypeID() && CFDataGetLength(h) > 0 &&
        CFDataGetLength(h) <= 32) {
      const uint8_t *p = CFDataGetBytePtr(h);
      for (CFIndex i = 0; i < CFDataGetLength(h); i++)
        snprintf(digest + i * 2, 3, "%02x", p[i]);
    }
    identifier = id && CFGetTypeID(id) == CFStringGetTypeID() &&
                 CFEqual(id, CFSTR(CODE_ID));
  }
  int pidok =
      (expected > 0 && peer == expected && audit_token_to_pid(token) == peer);
  int uidok = (uid == geteuid() && audit_token_to_euid(token) == uid);
  int allowed = pidok && uidok && locate == 0 && reqrc == 0 && dynamic == 0 &&
                plain == 0 && sign == 0 && identifier &&
                !strcmp(digest, argv[3]);
  printf(
      "{\"auditPeerPID\":%d,\"expectedPIDMatched\":%d,\"effectiveUIDMatched\":%"
      "d,\"copyGuestStatus\":%d,\"requirementParseStatus\":%d,"
      "\"exactDynamicRequirementStatus\":%d,\"baseDynamicSignatureStatus\":%d,"
      "\"signingInformationStatus\":%d,\"expectedIdentifierMatched\":%d,"
      "\"observedCDHash\":\"%s\",\"signedPeerAllowed\":%d}\n",
      peer, pidok, uidok, (int)locate, (int)reqrc, (int)dynamic, (int)plain,
      (int)sign, identifier, digest, allowed);
  if (info)
    CFRelease(info);
  if (backing)
    CFRelease(backing);
  if (req)
    CFRelease(req);
  if (guest)
    CFRelease(guest);
  CFRelease(expression);
  CFRelease(attrs);
  CFRelease(token_data);
  return 0;
}
