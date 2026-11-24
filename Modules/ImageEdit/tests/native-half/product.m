#import <Foundation/Foundation.h>
#import "metal_fixture.h"
#include "ImageEditLoader.h"
#include "probe.h"
#include <dlfcn.h>
#include <string.h>

static RMImagePlan *recipe(RMImageRuntime *runtime, const char *curvedWhite, const char *color) {
  char wire[1024];
  snprintf(wire, sizeof(wire),
    "{\"version\":2,\"working\":\"extended-linear-srgb-premul-f32\",\"output\":\"c\",\"nodes\":["
    "{\"id\":\"s\",\"op\":\"source\"},{\"id\":\"b\",\"op\":\"basic_v3\",\"image\":\"s\"%s},"
    "{\"id\":\"c\",\"op\":\"curves_levels_v3\",\"image\":\"b\",\"curves\":{\"red\":{\"points\":["
    "{\"x\":0,\"y\":0},{\"x\":0.5,\"y\":0.6},{\"x\":1,\"y\":1}],\"inputBlack\":0,\"inputWhite\":%s}},"
    "\"levels\":{\"blue\":{\"black\":0,\"shadows\":0.3,\"midtones\":0.5,\"highlights\":0.7,\"white\":1,"
    "\"outputBlack\":0.05,\"outputWhite\":0.95}}}]}", color, curvedWhite);
  RMImagePlan *plan = NULL;
  return rm_image_host_plan_open(runtime, (const uint8_t *)wire, strlen(wire), NULL, 0, RM_IMAGE_CPU, &plan) == 0 ? plan : NULL;
}

// The published witness uses the frozen Phase X research library as its reference.
// A fresh native-half-probe build is also accepted for local reproduction.
// All plans and programs are closed by the same dynamically loaded runtime that opened them.
int main(int argc, char **argv) { @autoreleasepool {
  ENSURE(argc == 3);
  RMImageRuntime *product = rm_image_host_open(argv[1]), *legacy = rm_image_host_open(argv[2]);
  void *library = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
  ENSURE(product && legacy && library);
  __typeof__(&rm_image_half_program_open_probe_v1) openProbe = dlsym(library, "rm_image_half_program_open_probe_v1");
  __typeof__(&rm_image_half_render_probe_v1) renderProbe = dlsym(library, "rm_image_half_render_probe_v1");
  __typeof__(&rm_image_half_program_close_probe_v1) closeProbe = dlsym(library, "rm_image_half_program_close_probe_v1");
  ENSURE(openProbe && renderProbe && closeProbe);
  RMImagePlan *a = recipe(product, "1", ""), *b = recipe(product, "0.95", "");
  RMImagePlan *oldA = recipe(legacy, "1", ""), *oldB = recipe(legacy, "0.95", "");
  RMImagePlan *mixed = recipe(product, "1", ",\"color\":{\"saturation\":0.2,\"vibrance\":0,\"cast\":0}");
  RMImagePlan *overflow = recipe(product, "1e-36", "");
  ENSURE(a && b && oldA && oldB && mixed && overflow);
  RMImageMetalHalfProgram *p = (RMImageMetalHalfProgram *)(uintptr_t)1;
  bool referenceHasProduct = dlsym(library,"rm_image_metal_half_program_open_v1") != NULL;
  int expectedStatus = referenceHasProduct ? RM_IMAGE_INVALID : RM_IMAGE_BACKEND;
  ENSURE(rm_image_host_metal_half_program_open(legacy, oldA, NULL, &p) == expectedStatus && !p);
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  id<MTLCommandQueue> queue = [device newCommandQueue];
  ENSURE(device && queue);
  ENSURE(rm_image_host_metal_half_program_open(product, mixed, (__bridge void *)device, &p) == RM_IMAGE_INVALID && !p);
  ENSURE(rm_image_host_metal_half_program_open(product, a, (__bridge void *)device, &p) == 0 && p);
  RMHalfProbe *reference = NULL;
  ENSURE(openProbe(oldA, (__bridge void *)device, &reference) == 0 && reference);
  enum { W = 34, H = 1030, pitch = 512 };
  id<MTLTexture> input = texture(device, MTLPixelFormatRGBA16Float, W, H, MTLStorageModePrivate);
  id<MTLTexture> output = texture(device, MTLPixelFormatRGBA32Float, W/2, H/2, MTLStorageModePrivate);
  id<MTLTexture> referenceOutput = texture(device, MTLPixelFormatRGBA32Float, W/2, H/2, MTLStorageModePrivate);
  id<MTLBuffer> source = [device newBufferWithLength:pitch*H options:MTLResourceStorageModeShared];
  id<MTLBuffer> read = [device newBufferWithLength:pitch*H/2 options:MTLResourceStorageModeShared];
  for (int y = 0; y < H; ++y) {
    __fp16 *row = (__fp16 *)((uint8_t *)source.contents + y*pitch);
    for (int x = 0; x < W; ++x) {
      row[x*4] = x/32.f; row[x*4+1] = y/512.f; row[x*4+2] = -x/32.f; row[x*4+3] = 1;
    }
  }
  ENSURE(copy(queue,input,source,pitch,true));
  // Both external textures must be initialized before their first HAL import.
  // Distinct contents also keep an omitted destination write visible to this comparison.
  memset(read.contents,0xff,pitch*H/2);
  ENSURE(copy(queue,output,read,pitch,true));
  memset(read.contents,0x55,pitch*H/2);
  ENSURE(copy(queue,referenceOutput,read,pitch,true));
  puts("Independently initialized product and frozen reference output textures with distinct patterns and joined both producers.");
  void *in = (__bridge void *)input, *out = (__bridge void *)output;
  Gate g={0};
  ENSURE(rm_image_host_metal_half_render(product,p,a,in,out,77,NULL,&g) == RM_IMAGE_INVALID);
  ENSURE(rm_image_host_metal_half_render(product,p,mixed,in,out,77,current,&g) == RM_IMAGE_INVALID);
  id<MTLTexture> aliased = [input newTextureViewWithPixelFormat:MTLPixelFormatRGBA16Float];
  ENSURE(rm_image_host_metal_half_render(product,p,a,(__bridge void *)aliased,out,77,current,&g) == RM_IMAGE_INVALID);
  RMImagePlan *plans[] = {a,b,a}, *referencePlans[] = {oldA,oldB,oldA};
  for (int i=0; i<3; ++i) {
    ENSURE(renderProbe(reference,referencePlans[i],in,(__bridge void *)referenceOutput,6,77,current,&g) == 0);
    ENSURE(copy(queue,referenceOutput,read,pitch,false));
    NSData *expected = [NSData dataWithBytes:read.contents length:pitch*H/2];
    ENSURE(rm_image_host_metal_half_render(product,p,plans[i],in,out,77,current,&g) == 0);
    ENSURE(copy(queue,output,read,pitch,false));
    for (int y=0; y<H/2; ++y) {
      ENSURE(memcmp((uint8_t *)read.contents+y*pitch,(const uint8_t *)expected.bytes+y*pitch,W/2*16)==0);
    }
  }
  printf("Three rebound curves/levels A/B/A equal frozen four-band F32 on every component at 34x1030.\n");
  // For a four-band first group the entry and four encoding checks precede the final
  // pre-submit (6), immediately-post-submit (7), and post-join (8) callbacks.
  NSUInteger before=device.currentAllocatedSize, middle=0;
  for (int attempt=0; attempt<32; ++attempt) {
    @autoreleasepool {
      g=(Gate){0,6};
      ENSURE(rm_image_host_metal_half_render(product,p,a,in,out,77,current,&g)==RM_IMAGE_METAL_STALE && g.calls==6);
    }
    if (attempt==15) middle=device.currentAllocatedSize;
  }
  printf("Reported device allocation before, after 16 and after 32 cancelled renders: %llu, %llu, %llu bytes.\n",
    (unsigned long long)before,(unsigned long long)middle,(unsigned long long)device.currentAllocatedSize);
  for (int gate=7; gate<=8; ++gate) {
    g=(Gate){0,(unsigned)gate};
    ENSURE(rm_image_host_metal_half_render(product,p,b,in,out,77,current,&g)==RM_IMAGE_METAL_STALE && g.calls==gate);
  }
  g=(Gate){0};
  ENSURE(rm_image_host_metal_half_render(product,p,overflow,in,out,77,current,&g)==RM_IMAGE_RENDER);
  __fp16 *tail=(__fp16 *)source.contents;
  tail[3]=0.5;
  ENSURE(copy(queue,input,source,pitch,true));
  ENSURE(rm_image_host_metal_half_render(product,p,a,in,out,77,current,&g)==RM_IMAGE_RENDER);
  tail[3]=1;
  ENSURE(copy(queue,input,source,pitch,true));
  ENSURE(rm_image_host_metal_half_render(product,p,b,in,out,77,current,&g)==0);
  printf("32 pre-submit revocations, post-submit and post-join revoke, overflow and six-row-tail nonopaque rejection, retry passed.\n");
  closeProbe(reference); rm_image_host_metal_half_program_close(product,p);
  for (int i=0;i<2;++i) { rm_image_host_plan_close(product,plans[i]); rm_image_host_plan_close(legacy,referencePlans[i]); }
  rm_image_host_plan_close(product,mixed); rm_image_host_plan_close(product,overflow);
  rm_image_host_close(legacy); dlclose(library); rm_image_host_close(product);
  return 0;
}}
