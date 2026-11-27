#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vk_icdGetInstanceProcAddr)(void*, const char*);
typedef int32_t (*PFN_vk_icdNegotiateLoaderICDInterfaceVersion)(uint32_t*);

int main(void) {
  void* handle = dlopen("/usr/lib/x86_64-linux-gnu/libGLX_nvidia.so.0",
                        RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    printf("dlopen: %s\n", dlerror());
    return 1;
  }
  PFN_vk_icdNegotiateLoaderICDInterfaceVersion negotiate =
      (PFN_vk_icdNegotiateLoaderICDInterfaceVersion)dlsym(
          handle, "vk_icdNegotiateLoaderICDInterfaceVersion");
  PFN_vk_icdGetInstanceProcAddr get_instance =
      (PFN_vk_icdGetInstanceProcAddr)dlsym(handle, "vk_icdGetInstanceProcAddr");
  printf("negotiate=%p getInstanceProcAddr=%p\n", (void*)negotiate,
         (void*)get_instance);
  if (negotiate) {
    for (uint32_t requested = 1; requested <= 8; ++requested) {
      uint32_t version = requested;
      int32_t result = negotiate(&version);
      printf("request %u -> result %d version %u\n", requested, result, version);
    }
  }
  if (get_instance) {
    printf("vkCreateInstance=%p\n", get_instance(NULL, "vkCreateInstance"));
    printf("vkGetInstanceProcAddr=%p\n",
           get_instance(NULL, "vkGetInstanceProcAddr"));
  }
  return 0;
}
