#include "rawmaster_image_metal.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <float.h>
#include <math.h>
#include <string.h>
extern void *rm_replay_create(void *, uint32_t, uint32_t, const float *,
                              const float *);
extern void *rm_replay_texture(void *, uint32_t);
extern bool rm_replay_read(void *, float *, bool);
extern void rm_replay_release(void *);
extern void rm_replay_drop_host_textures(void *);
static uint32_t calls, releases;
static uint32_t obsolete_after_submit(void *context, uint64_t revision) {
  assert(context == &calls && revision == 78);
  return ++calls == 1;
}
static void release_lease(void *context) {
  assert(context == &releases);
  ++releases;
}
static RMImagePlan *recipe(NSString *nodes, const char *catalog) {
  NSString *json = [NSString
      stringWithFormat:@"{\"version\":1,\"working\":\"extended-linear-srgb-"
                       @"premul-f32\",\"output\":\"o\",\"nodes\":%@}",
                       nodes];
  RMImagePlan *result = NULL;
  assert(rm_image_plan_open_v1((const uint8_t *)json.UTF8String,
                               strlen(json.UTF8String),
                               (const uint8_t *)catalog, strlen(catalog),
                               RM_IMAGE_CPU, &result) == 0);
  return result;
}
static RMImagePlan *named_plan(int count, BOOL invalidLast, BOOL rename,
                               double scale) {
  NSMutableArray *nodes =
      [NSMutableArray arrayWithObject:@{@"id" : @"source", @"op" : @"source"}];
  NSString *parent = @"source";
  for (int i = 0; i < count; ++i) {
    NSString *mask = rename && i == count - 1
                         ? @"renamed"
                         : [NSString stringWithFormat:@"mask%02d", i];
    NSString *next = [NSString stringWithFormat:@"node%02d", i];
    [nodes addObject:@{@"id" : mask, @"op" : @"mask"}];
    double ev = invalidLast && i == count - 1
                    ? 0.0
                    : scale * (i % 2 == 0 ? 0.5 : -0.75);
    [nodes addObject:@{
      @"id" : next,
      @"op" : @"masked_exposure",
      @"image" : parent,
      @"mask" : mask,
      @"ev" : @(ev)
    }];
    parent = next;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{
    @"version" : @2,
    @"working" : @"extended-linear-srgb-premul-f32",
    @"output" : parent,
    @"nodes" : nodes
  }
                                                 options:0
                                                   error:NULL];
  RMImagePlan *result = NULL;
  assert(rm_image_plan_open_v2(data.bytes, data.length, NULL, 0, RM_IMAGE_CPU,
                               &result) == RM_IMAGE_OK);
  return result;
}

// The fixture creates different padded plane-zero IOSurfaces. Production
// receives only their MTLTexture handles.
static float named_surfaces(id<MTLDevice> device, int count, BOOL invalidLast) {
  enum { w = 9, h = 5, n = w * h, limit = 32 };
  assert(count >= 2 && count <= limit);
  float rgba[n * 4], masks[limit][n], actual[n * 4], expected[n * 4];
  char names[limit][12];
  void *owners[limit] = {0};
  RMImageCoverageV2 cpu[limit] = {0};
  RMImageMetalCoverageV2 coverage[limit] = {0};
  id<MTLTexture> maskTextures[limit];
  for (int p = 0; p < n; ++p) {
    rgba[p * 4] = (p - 10) / 40.f;
    rgba[p * 4 + 1] = (p + 1) / 38.f;
    rgba[p * 4 + 2] = 1.5f;
    rgba[p * 4 + 3] = 1;
  }
  for (int slot = 0; slot < count; ++slot) {
    snprintf(names[slot], sizeof(names[slot]), "mask%02d", slot);
    for (int p = 0; p < n; ++p)
      masks[slot][p] = (float)((p * (slot + 1) + 3 * slot) % 19) / 18;
    if (invalidLast && slot == count - 1)
      masks[slot][n - 1] = NAN;
    owners[slot] =
        rm_replay_create((__bridge void *)device, w, h, rgba, masks[slot]);
    assert(owners[slot]);
    maskTextures[slot] = CFBridgingRelease(rm_replay_texture(owners[slot], 1));
    int index = count - 1 - slot;
    coverage[index] = (RMImageMetalCoverageV2){
        (const uint8_t *)names[slot], strlen(names[slot]),
        (__bridge void *)maskTextures[slot]};
    cpu[index] = (RMImageCoverageV2){(const uint8_t *)names[slot],
                                     strlen(names[slot]), masks[slot], n};
  }
  id<MTLTexture> input = CFBridgingRelease(rm_replay_texture(owners[0], 0));
  id<MTLTexture> output = CFBridgingRelease(rm_replay_texture(owners[0], 2));
  RMImagePlan *plan = named_plan(count, invalidLast, NO, 1);
  RMImagePlan *edited = named_plan(count, invalidLast, NO, 0.5);
  RMImagePlan *renamed = named_plan(count, invalidLast, YES, 1);
  RMImageMetalProgram *program = NULL;
  assert(rm_image_metal_program_open_v1(plan, (__bridge void *)device,
                                        &program) == RM_IMAGE_OK);
  RMImageMetalSurfacesV2 descriptor = {.struct_size = sizeof(descriptor),
                                       .width = w,
                                       .height = h,
                                       .input_rgba = (__bridge void *)input,
                                       .output_rgba = (__bridge void *)output,
                                       .coverage = coverage,
                                       .coverage_count = count,
                                       .lease_context = &releases,
                                       .release_lease = release_lease};
  RMImageMetalSurfacesV1 positional = {.struct_size = sizeof(positional),
                                       .width = w,
                                       .height = h,
                                       .input_rgba = (__bridge void *)input,
                                       .output_rgba = (__bridge void *)output,
                                       .coverage_r32 =
                                           (__bridge void *)maskTextures[0]};
  uint32_t before = releases;
  RMImageMetalFrame *frame = NULL;
  assert(rm_image_metal_frame_bind_v1(program, plan, &positional, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  RMImageMetalSurfacesV2 bad = descriptor;
  bad.coverage_count--;
  assert(rm_image_metal_frame_bind_v2(program, plan, &bad, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  bad = descriptor;
  bad.flags = 1;
  assert(rm_image_metal_frame_bind_v2(program, plan, &bad, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  bad = descriptor;
  bad.coverage = NULL;
  assert(rm_image_metal_frame_bind_v2(program, plan, &bad, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  bad = descriptor;
  bad.struct_size = 4;
  assert(rm_image_metal_frame_bind_v2(program, plan, &bad, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  bad = descriptor;
  bad.output_rgba = bad.input_rgba;
  assert(rm_image_metal_frame_bind_v2(program, plan, &bad, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  const RMImageMetalCoverageV2 last = coverage[count - 1];
  coverage[count - 1].id = coverage[0].id;
  assert(rm_image_metal_frame_bind_v2(program, plan, &descriptor, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  coverage[count - 1] = last;
  coverage[count - 1].texture = (__bridge void *)output;
  assert(rm_image_metal_frame_bind_v2(program, plan, &descriptor, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  // A second Metal object naming the same IOSurface must also be rejected.
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                   width:w
                                  height:h
                               mipmapped:NO];
  td.storageMode = MTLStorageModeShared;
  td.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> alias =
      [device newTextureWithDescriptor:td
                             iosurface:maskTextures[count - 1].iosurface
                                 plane:0];
  assert(alias && alias != maskTextures[count - 1]);
  coverage[count - 1].texture = (__bridge void *)alias;
  assert(rm_image_metal_frame_bind_v2(program, plan, &descriptor, &frame) ==
             RM_IMAGE_INVALID &&
         frame == NULL);
  coverage[count - 1] = last;
  assert(releases == before);
  assert(rm_image_metal_frame_bind_v2(program, plan, &descriptor, &frame) ==
             RM_IMAGE_OK &&
         frame);
  rm_image_metal_program_close_v1(program);
  alias = nil;
  input = nil;
  output = nil;
  for (int slot = 0; slot < count; ++slot) {
    maskTextures[slot] = nil;
    rm_replay_drop_host_textures(owners[slot]);
    coverage[slot] = (RMImageMetalCoverageV2){0};
  }
  assert(rm_image_metal_frame_render_v1(frame, renamed, 77, NULL, NULL) ==
         RM_IMAGE_INVALID);
  float largest = 0;
  for (int step = 0; step < 3; ++step) {
    RMImagePlan *parameters = step == 1 ? edited : plan;
    int status =
        rm_image_metal_frame_render_v1(frame, parameters, 77, NULL, NULL);
    if (invalidLast) {
      assert(status == RM_IMAGE_RENDER);
      continue;
    }
    assert(status == RM_IMAGE_OK);
    assert(rm_image_plan_render_v2(parameters, w, h, rgba, n * 4, cpu, count,
                                   expected, n * 4) == RM_IMAGE_OK);
    assert(rm_replay_read(owners[0], actual, true));
    for (int i = 0; i < n * 4; ++i) {
      largest = fmaxf(largest, fabsf(expected[i] - actual[i]));
      assert(fabsf(expected[i] - actual[i]) < 2e-4);
    }
  }
  if (!invalidLast) {
    calls = 0;
    assert(rm_image_metal_frame_render_v1(frame, edited, 78,
                                          obsolete_after_submit,
                                          &calls) == RM_IMAGE_METAL_STALE &&
           calls == 2);
    assert(rm_image_metal_frame_render_v1(frame, plan, 79, NULL, NULL) ==
           RM_IMAGE_OK);
  }
  assert(releases == before);
  rm_image_metal_frame_close_v1(frame);
  assert(releases == before + 1);
  rm_image_plan_close_v1(renamed);
  rm_image_plan_close_v1(edited);
  rm_image_plan_close_v1(plan);
  for (int slot = 0; slot < count; ++slot)
    rm_replay_release(owners[slot]);
  return largest;
}

static RMImagePlan *subnormal_tone(int backend) {
  const char *json =
      "{\"version\":2,\"working\":\"extended-linear-srgb-premul-f32\",\"output\":\"o\","
      "\"nodes\":[{\"id\":\"s\",\"op\":\"source\"},{\"id\":\"m\",\"op\":\"mask\"},"
      "{\"id\":\"o\",\"op\":\"mask_tone_v3\",\"image\":\"s\",\"mask\":\"m\","
      "\"control\":\"exposure\",\"amount\":-0.5}]}";
  RMImagePlan *plan = NULL;
  assert(rm_image_plan_open_v2((const uint8_t *)json, strlen(json), NULL, 0,
                               backend, &plan) == RM_IMAGE_OK);
  return plan;
}

static size_t subnormal_surfaces(id<MTLDevice> device) {
  const struct {
    uint32_t pixel[4], mask;
    int bufferedStatus, surfaceStatus;
  } cases[] = {
      {{3, 5, 0x80000003, 1}, 0x3f800000, RM_IMAGE_OK, RM_IMAGE_OK},
      {{0x007fffff, 0x807fffff, 0x007fffff, 0x007fffff}, 0x3f800000,
       RM_IMAGE_OK, RM_IMAGE_OK},
      {{0x7f7fffff, 1, 0x80000001, 1}, 0x80000000, RM_IMAGE_OK, RM_IMAGE_OK},
      {{0x7f7fffff, 1, 0x80000001, 1}, 0x3f800000, RM_IMAGE_RENDER,
       RM_IMAGE_RENDER},
      {{0x7f7fffff, 1, 0x80000001, 1}, 1, RM_IMAGE_RENDER, RM_IMAGE_RENDER},
      {{0, 0, 0, 0x80000001}, 0, RM_IMAGE_INVALID, RM_IMAGE_RENDER},
      {{1, 0, 0, 0}, 0, RM_IMAGE_INVALID, RM_IMAGE_RENDER},
      {{0x80000000, 0, 0x80000000, 0x80000000}, 0x3f800000, RM_IMAGE_OK,
       RM_IMAGE_OK},
      {{0, 0, 0, 0x3f800000}, 0x80000001, RM_IMAGE_INVALID, RM_IMAGE_RENDER},
  };
  RMImagePlan *cpu = subnormal_tone(RM_IMAGE_CPU),
              *gpu = subnormal_tone(RM_IMAGE_GPU);
  RMImageMetalProgram *program = NULL;
  assert(rm_image_metal_program_open_v1(cpu, (__bridge void *)device,
                                       &program) == RM_IMAGE_OK);
  const uint8_t maskName[] = "m";
  const float sentinel[] = {7, 7, 7, 7};
  size_t count = sizeof(cases) / sizeof(cases[0]);
  for (size_t i = 0; i < count; ++i) {
    float input[4], mask, expected[4], buffered[4], borrowed[4];
    memcpy(input, cases[i].pixel, sizeof(input));
    memcpy(&mask, &cases[i].mask, sizeof(mask));
    memcpy(expected, sentinel, sizeof(expected));
    memcpy(buffered, sentinel, sizeof(buffered));
    const RMImageCoverageV2 coverage = {maskName, 1, &mask, 1};
    assert(rm_image_plan_render_v2(cpu, 1, 1, input, 4, &coverage, 1, expected,
                                   4) == cases[i].bufferedStatus);
    assert(rm_image_plan_render_v2(gpu, 1, 1, input, 4, &coverage, 1, buffered,
                                   4) == cases[i].bufferedStatus);
    assert(memcmp(expected, buffered, sizeof(expected)) == 0);
    if (cases[i].bufferedStatus != RM_IMAGE_OK)
      assert(memcmp(expected, sentinel, sizeof(expected)) == 0);

    void *owner = rm_replay_create((__bridge void *)device, 1, 1, input, &mask);
    assert(owner);
    id in = CFBridgingRelease(rm_replay_texture(owner, 0)),
       coverageTexture = CFBridgingRelease(rm_replay_texture(owner, 1)),
       out = CFBridgingRelease(rm_replay_texture(owner, 2));
    const RMImageMetalCoverageV2 plane = {maskName, 1,
                                         (__bridge void *)coverageTexture};
    const RMImageMetalSurfacesV2 descriptor = {
        .struct_size = sizeof(descriptor),
        .width = 1,
        .height = 1,
        .input_rgba = (__bridge void *)in,
        .output_rgba = (__bridge void *)out,
        .coverage = &plane,
        .coverage_count = 1,
        .lease_context = &releases,
        .release_lease = release_lease};
    RMImageMetalFrame *frame = NULL;
    uint32_t before = releases;
    assert(rm_image_metal_frame_bind_v2(program, cpu, &descriptor, &frame) ==
           RM_IMAGE_OK);
    if (i == 0) {
      calls = 0;
      assert(rm_image_metal_frame_render_v1(frame, cpu, 78,
                                            obsolete_after_submit, &calls) ==
             RM_IMAGE_METAL_STALE && calls == 2);
    }
    assert(rm_image_metal_frame_render_v1(frame, cpu, 79, NULL, NULL) ==
           cases[i].surfaceStatus);
    assert(rm_replay_read(owner, borrowed, false));
    if (cases[i].surfaceStatus == RM_IMAGE_OK) {
      assert(memcmp(expected, borrowed, sizeof(expected)) == 0);
    } else {
      const float unwritten[4] = {0};
      assert(memcmp(unwritten, borrowed, sizeof(borrowed)) == 0);
    }
    assert(releases == before);
    rm_image_metal_frame_close_v1(frame);
    assert(releases == before + 1);
    rm_replay_release(owner);
  }
  rm_image_metal_program_close_v1(program);
  rm_image_plan_close_v1(gpu);
  rm_image_plan_close_v1(cpu);
  return count;
}

static size_t frozen_tone_rounding(id<MTLDevice> device) {
  // Stock rmMaskTone readbacks from two checked RAWs, with the original frozen coverage.
  const struct {
    const char *control, *amount;
    uint32_t rgb[3], coverage, expected[3];
  } cases[] = {
      {"blacks", "-0.15", {0x3c46c000, 0x3c028000, 0x3b87e000}, 0x3defa428,
       {0x3c54f10d, 0x3c10c05f, 0x3ba47cd2}},
      {"whites", "0.15", {0x3f1f4000, 0x3f216000, 0x3f2ac000}, 0x3f7ff90b,
       {0x3f256da3, 0x3f27a2be, 0x3f315fdb}},
      {"whites", "0.55", {0x3f1ca000, 0x3f228000, 0x3f2ae000}, 0x3e426542,
       {0x3f20dcf2, 0x3f26e5a5, 0x3f2f7fa8}},
  };
  const uint8_t name[] = "m";
  const size_t count = sizeof(cases) / sizeof(cases[0]);
  for (size_t i = 0; i < count; ++i) {
    float input[4] = {0, 0, 0, 1}, expected[4] = {0, 0, 0, 1}, mask;
    memcpy(input, cases[i].rgb, sizeof(cases[i].rgb));
    memcpy(expected, cases[i].expected, sizeof(cases[i].expected));
    memcpy(&mask, &cases[i].coverage, sizeof(mask));
    char json[384];
    int length = snprintf(json, sizeof(json),
        "{\"version\":2,\"working\":\"extended-linear-srgb-premul-f32\",\"output\":\"o\","
        "\"nodes\":[{\"id\":\"s\",\"op\":\"source\"},{\"id\":\"m\",\"op\":\"mask\"},"
        "{\"id\":\"o\",\"op\":\"mask_tone_v3\",\"image\":\"s\",\"mask\":\"m\","
        "\"control\":\"%s\",\"amount\":%s}]}", cases[i].control, cases[i].amount);
    assert(length > 0 && (size_t)length < sizeof(json));

    RMImagePlan *cpu = NULL, *gpu = NULL;
    assert(rm_image_plan_open_v2((const uint8_t *)json, length, NULL, 0, RM_IMAGE_CPU, &cpu) == RM_IMAGE_OK);
    assert(rm_image_plan_open_v2((const uint8_t *)json, length, NULL, 0, RM_IMAGE_GPU, &gpu) == RM_IMAGE_OK);
    RMImageCoverageV2 coverage = {name, 1, &mask, 1};
    float cpuPixel[4], buffered[4], borrowed[4];
    assert(rm_image_plan_render_v2(cpu, 1, 1, input, 4, &coverage, 1, cpuPixel, 4) == RM_IMAGE_OK);
    assert(rm_image_plan_render_v2(gpu, 1, 1, input, 4, &coverage, 1, buffered, 4) == RM_IMAGE_OK);
    for (size_t channel = 0; channel < 4; ++channel)
      assert(fabsf(cpuPixel[channel] - expected[channel]) <= 2e-6f);
    assert(memcmp(buffered, expected, sizeof(expected)) == 0);

    void *owner = rm_replay_create((__bridge void *)device, 1, 1, input, &mask);
    assert(owner);
    id in = CFBridgingRelease(rm_replay_texture(owner, 0));
    id planeTexture = CFBridgingRelease(rm_replay_texture(owner, 1));
    id out = CFBridgingRelease(rm_replay_texture(owner, 2));
    RMImageMetalCoverageV2 plane = {name, 1, (__bridge void *)planeTexture};
    RMImageMetalSurfacesV2 surfaces = {
        .struct_size = sizeof(surfaces), .width = 1, .height = 1,
        .input_rgba = (__bridge void *)in, .output_rgba = (__bridge void *)out,
        .coverage = &plane, .coverage_count = 1};
    RMImageMetalProgram *program = NULL;
    RMImageMetalFrame *frame = NULL;
    assert(rm_image_metal_program_open_v1(cpu, (__bridge void *)device, &program) == RM_IMAGE_OK);
    assert(rm_image_metal_frame_bind_v2(program, cpu, &surfaces, &frame) == RM_IMAGE_OK);
    assert(rm_image_metal_frame_render_v1(frame, cpu, 1, NULL, NULL) == RM_IMAGE_OK);
    assert(rm_replay_read(owner, borrowed, false));
    assert(memcmp(borrowed, expected, sizeof(expected)) == 0);
    rm_image_metal_frame_close_v1(frame);
    rm_image_metal_program_close_v1(program);
    rm_replay_release(owner);
    rm_image_plan_close_v1(gpu);
    rm_image_plan_close_v1(cpu);
  }
  return count;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 2)
      return 2;
    assert(sizeof(RMImageMetalSurfacesV1) == 56);
    assert(rm_image_metal_surface_abi_version() == 1 &&
           rm_image_abi_version() == 1);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    enum { w = 7, h = 5, n = w * h };
    float rgba[n * 4], coverage[n], actual[n * 4], cpu[n * 4];
    for (uint32_t i = 0; i < n; i++) {
      rgba[4 * i] = (float)i / 80 - 0.1f;
      rgba[4 * i + 1] = (float)i / 20;
      rgba[4 * i + 2] = .25;
      rgba[4 * i + 3] = 1;
      coverage[i] = (float)(i % 7) / 6;
    }
    NSString *withMask =
        @"[{\"id\":\"s\",\"op\":\"source\"},{\"id\":\"m\",\"op\":\"mask\"},{"
        @"\"id\":\"a\",\"op\":\"masked_exposure\",\"image\":\"s\",\"mask\":"
        @"\"m\",\"ev\":-1.25},{\"id\":\"o\",\"op\":\"photo_filter\",\"image\":"
        @"\"a\",\"look\":\"vivid\",\"amount\":37.5}]";
    NSString *withoutMask = @"[{\"id\":\"s\",\"op\":\"source\"},{\"id\":\"o\","
                            @"\"op\":\"exposure\",\"image\":\"s\",\"ev\":0.5}]";
    RMImagePlan *a = recipe(withMask, argv[1]),
                *b = recipe([withMask
                                stringByReplacingOccurrencesOfString:@"37.5"
                                                          withString:@"43.75"],
                            argv[1]),
                *plain = recipe(withoutMask, argv[1]);
    RMImagePlan *raw = recipe(
        [withMask
            stringByReplacingOccurrencesOfString:@"37.5"
                                      withString:
                                          @"37.5,\"repairRawAlpha\":true"],
        argv[1]);
    float largest = 0;
    for (int test = 0; test < 8; test++) {
      BOOL masked = test < 2 || test == 5 || test == 7;
      BOOL valid = test == 0 || test == 2 || test == 5;
      /* Invalid coverage, nonfinite RGB and invalid source alpha must be
       * rejected on the GPU. */
      coverage[0] = test == 7 ? NAN : test == 1 ? 1.25 : 0;
      rgba[3] = test == 4 ? 1.125f : 1;
      rgba[0] = test == 3 ? NAN : -.1f;
      if (test == 5) {
        rgba[3] = nextafterf(nextafterf(nextafterf(1, 2), 2), 2);
      }
      if (test == 6) {
        rgba[0] = FLT_MAX;
      }
      RMImagePlan *p = test == 5 ? raw : (masked ? a : plain);
      void *owner =
          rm_replay_create((__bridge void *)device, w, h, rgba, coverage);
      assert(owner);
      id in = CFBridgingRelease(rm_replay_texture(owner, 0)),
         mask = CFBridgingRelease(rm_replay_texture(owner, 1)),
         out = CFBridgingRelease(rm_replay_texture(owner, 2));
      RMImageMetalProgram *program = NULL;
      assert(rm_image_metal_program_open_v1(
                 p, (__bridge void *)@"not an MTLDevice", &program) == 1 &&
             program == NULL);
      assert(rm_image_metal_program_open_v1(p, (__bridge void *)device,
                                            &program) == 0);
      RMImageMetalSurfacesV1 descriptor = {
          .struct_size = sizeof(descriptor),
          .width = w,
          .height = h,
          .input_rgba = (__bridge void *)in,
          .coverage_r32 = masked ? (__bridge void *)mask : NULL,
          .output_rgba = (__bridge void *)out,
          .lease_context = &releases,
          .release_lease = release_lease};
      uint32_t before = releases;
      RMImageMetalFrame *frame = NULL;
      RMImageMetalSurfacesV1 bad = descriptor;
      bad.width++;
      assert(rm_image_metal_frame_bind_v1(program, p, &bad, &frame) == 1 &&
             frame == NULL);
      bad = descriptor;
      bad.output_rgba = bad.input_rgba;
      assert(rm_image_metal_frame_bind_v1(program, p, &bad, &frame) == 1 &&
             frame == NULL);
      bad = descriptor;
      bad.struct_size = 4;
      assert(rm_image_metal_frame_bind_v1(program, p, &bad, &frame) == 1 &&
             frame == NULL);
      bad = descriptor;
      bad.coverage_r32 = masked ? NULL : (__bridge void *)mask;
      assert(rm_image_metal_frame_bind_v1(program, p, &bad, &frame) == 1 &&
             frame == NULL);
      assert(releases == before);
      assert(rm_image_metal_frame_bind_v1(program, p, &descriptor, &frame) ==
             0);
      rm_image_metal_program_close_v1(program);
      in = nil;
      mask = nil;
      out = nil;
      rm_replay_drop_host_textures(owner);
      int status = rm_image_metal_frame_render_v1(frame, p, 77, NULL, NULL);
      assert(status == (valid ? 0 : RM_IMAGE_RENDER));
      if (valid) {
        assert(rm_image_plan_render_v1(p, w, h, rgba, n * 4,
                                       masked ? coverage : NULL, masked ? n : 0,
                                       cpu, n * 4) == 0);
        assert(rm_replay_read(owner, actual, true));
        for (int k = 0; k < n * 4; ++k) {
          largest = fmaxf(largest, fabsf(cpu[k] - actual[k]));
          assert(fabsf(cpu[k] - actual[k]) < 2e-4);
        }
        if (test == 0) {
          assert(rm_image_metal_frame_render_v1(frame, plain, 77, NULL, NULL) ==
                 1);
          assert(rm_image_metal_frame_render_v1(
                     frame, b, 78, obsolete_after_submit, &calls) ==
                     RM_IMAGE_METAL_STALE &&
                 calls == 2);
          assert(rm_image_plan_render_v1(b, w, h, rgba, n * 4, coverage, n, cpu,
                                         n * 4) == 0);
          assert(rm_replay_read(owner, actual, false));
          for (int k = 0; k < n * 4; ++k)
            assert(fabsf(cpu[k] - actual[k]) < 2e-4);
        }
      }
      assert(releases == before);
      rm_image_metal_frame_close_v1(frame);
      assert(releases == before + 1);
      rm_replay_release(owner);
    }
    rm_image_plan_close_v1(raw);
    rm_image_plan_close_v1(a);
    rm_image_plan_close_v1(b);
    rm_image_plan_close_v1(plain);
    const uint32_t positionalReleases = releases;
    float namedError = named_surfaces(device, 2, NO);
    namedError = fmaxf(namedError, named_surfaces(device, 32, NO));
    named_surfaces(device, 32, YES);
    const uint32_t namedReleases = releases - positionalReleases;
    const size_t subnormalCases = subnormal_surfaces(device);
    const size_t roundingCases = frozen_tone_rounding(device);
    printf(
        "{\"abi\":1,\"descriptorBytes\":56,\"cpuVsNativeCIMaxAbs\":%.12g,"
        "\"validMaskedAndUnmasked\":true,\"invalidCoverageRejected\":true,"
        "\"invalidAlphaRejected\":true,\"nonfiniteInputRejected\":true,"
        "\"incompatiblePlanRejected\":true,"
        "\"badExtentAliasAndDescriptorRejected\":true,"
        "\"retainedAfterProgramClose\":true,\"hostTextureReferencesDropped\":"
        "true,\"nonfiniteCoverageRejected\":true,\"rawRepairThreeULPs\":true,"
        "\"nonfiniteOutputRejected\":true,\"postSubmitStaleStatus\":5,"
        "\"leaseReleases\":%u,\"namedPlaneCounts\":[2,32],"
        "\"namedVsNativeCIMaxAbs\":%.12g,"
        "\"lastPixelLastPlaneNaNZeroEVRejected\":true,"
        "\"distinctViewsSameIOSurfaceRejected\":true,"
        "\"namedPostSubmitStaleAndRetry\":true,\"namedLeaseReleases\":%u,"
        "\"subnormalBufferedAndBorrowedCases\":%zu,\"frozenToneRoundingCases\":%zu}\n",
        largest, positionalReleases, namedError, namedReleases, subnormalCases, roundingCases);
  }
}
