#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <stdint.h>
uint32_t rm_surface_identity(void *object) {
  id<MTLTexture> texture = (__bridge id<MTLTexture>)object;
  IOSurfaceRef surface = texture.iosurface;
  if (!surface || texture.iosurfacePlane != 0 ||
      IOSurfaceGetPlaneCount(surface) != 0)
    return 0;
  bool coverage = texture.pixelFormat == MTLPixelFormatR32Float;
  if (!coverage && texture.pixelFormat != MTLPixelFormatRGBA32Float)
    return 0;
  size_t element = coverage ? 4 : 16, width = texture.width,
         height = texture.height;
  if (width == 0 || height == 0 || IOSurfaceGetWidth(surface) != width ||
      IOSurfaceGetHeight(surface) != height ||
      IOSurfaceGetBytesPerElement(surface) != element ||
      width > SIZE_MAX / element)
    return 0;
  size_t row = IOSurfaceGetBytesPerRow(surface);
  if (row < width * element || height > SIZE_MAX / row ||
      IOSurfaceGetAllocSize(surface) < row * height)
    return 0;
  if (IOSurfaceGetPixelFormat(surface) !=
      (coverage ? kCVPixelFormatType_OneComponent32Float
                : kCVPixelFormatType_128RGBAFloat))
    return 0;
  return IOSurfaceGetID(surface);
}

bool rm_is_metal_device(void *object) {
  return [(__bridge id)object conformsToProtocol:@protocol(MTLDevice)];
}
bool rm_is_metal_texture(void *object) {
  return [(__bridge id)object conformsToProtocol:@protocol(MTLTexture)];
}

#ifdef RM_IMAGE_NATIVE_HALF_PROBE
double rm_half_probe_gpu_seconds(void *object) {
  id<MTLCommandBuffer> command = (__bridge id<MTLCommandBuffer>)object;
  return command.GPUEndTime - command.GPUStartTime;
}
#endif

bool rm_is_private_half_root(void *object) {
  if (!rm_is_metal_texture(object)) return false;
  id<MTLTexture> texture = (__bridge id<MTLTexture>)object;
  return texture.storageMode == MTLStorageModePrivate && !texture.parentTexture &&
         !texture.buffer && !texture.heap && !texture.iosurface && !texture.framebufferOnly &&
         !texture.isSparse && !texture.isAliasable && texture.hazardTrackingMode != MTLHazardTrackingModeUntracked;
}

// The caller owns one Objective-C retain on success. Check allocation and CPU
// visibility before Rust constructs a non-null Metal buffer handle.
void *rm_new_half_shared_buffer(void *device, uint64_t length) {
  id<MTLDevice> gpu = (__bridge id<MTLDevice>)device;
  id<MTLBuffer> buffer = [gpu newBufferWithLength:length options:MTLResourceStorageModeShared];
  if (!buffer || !buffer.contents || buffer.length != length) return NULL;
  return (__bridge_retained void *)buffer;
}
