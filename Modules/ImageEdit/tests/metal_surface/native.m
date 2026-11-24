#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

@interface RMReplaySurfaces : NSObject {
@public
  IOSurfaceRef surfaces[3];
  id<MTLDevice> device;
  id<MTLTexture> textures[3];
}
@end
@implementation RMReplaySurfaces
- (void)dealloc {
  for (int i = 0; i < 3; ++i)
    if (surfaces[i])
      CFRelease(surfaces[i]);
}
@end

void *rm_replay_create(void *nativeDevice, uint32_t width, uint32_t height,
                       const float *rgba, const float *mask) {
  @autoreleasepool {
    id<MTLDevice> device = (__bridge id<MTLDevice>)nativeDevice;
    RMReplaySurfaces *owner = [RMReplaySurfaces new];
    owner->device = device;
    for (int i = 0; i < 3; ++i) {
      uint32_t pixelBytes = i == 1 ? 4 : 16;
      size_t tight = width * pixelBytes;
      size_t stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, tight);
      NSDictionary *props = @{
        (__bridge NSString *)kIOSurfaceWidth : @(width),
        (__bridge NSString *)kIOSurfaceHeight : @(height),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(stride),
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(pixelBytes),
        (__bridge NSString *)kIOSurfaceAllocSize : @(stride * height),
        (__bridge NSString *)kIOSurfacePixelFormat :
            @(i == 1 ? kCVPixelFormatType_OneComponent32Float
                     : kCVPixelFormatType_128RGBAFloat),
      };
      IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
      if (!surface)
        return NULL;
      owner->surfaces[i] = surface;
      if (IOSurfaceLock(surface, 0, NULL) != KERN_SUCCESS)
        return NULL;
      uint8_t *base = IOSurfaceGetBaseAddress(surface);
      memset(base, 0, IOSurfaceGetAllocSize(surface));
      if (i != 2) {
        const uint8_t *src = (const uint8_t *)(i == 1 ? mask : rgba);
        for (uint32_t y = 0; y < height; ++y)
          memcpy(base + y * stride, src + y * tight, tight);
      }
      if (IOSurfaceUnlock(surface, 0, NULL) != KERN_SUCCESS)
        return NULL;
      MTLTextureDescriptor *d = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:i == 1 ? MTLPixelFormatR32Float
                                                    : MTLPixelFormatRGBA32Float
                                       width:width
                                      height:height
                                   mipmapped:NO];
      d.usage = i == 2 ? MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead
                       : MTLTextureUsageShaderRead;
      d.storageMode = MTLStorageModeShared;
      d.hazardTrackingMode = MTLHazardTrackingModeTracked;
      owner->textures[i] = [device newTextureWithDescriptor:d
                                                  iosurface:surface
                                                      plane:0];
      if (!owner->textures[i] || owner->textures[i].device != device ||
          IOSurfaceGetID(owner->textures[i].iosurface) !=
              IOSurfaceGetID(surface))
        return NULL;
    }
    return (__bridge_retained void *)owner;
  }
}
void *rm_replay_texture(void *owner, uint32_t i) {
  return (__bridge_retained void *)((__bridge RMReplaySurfaces *)owner)
      ->textures[i];
}
uint32_t rm_replay_id(void *owner, uint32_t i) {
  return IOSurfaceGetID(((__bridge RMReplaySurfaces *)owner)->surfaces[i]);
}
size_t rm_replay_stride(void *owner, uint32_t i) {
  return IOSurfaceGetBytesPerRow(
      ((__bridge RMReplaySurfaces *)owner)->surfaces[i]);
}
uint64_t rm_replay_registry(void *owner, uint32_t i) {
  return ((__bridge RMReplaySurfaces *)owner)->textures[i].device.registryID;
}

bool rm_replay_read(void *owner, float *rgba, bool viaCI) {
  @autoreleasepool {
    RMReplaySurfaces *p = (__bridge RMReplaySurfaces *)owner;
    IOSurfaceRef surface = p->surfaces[2];
    size_t w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface),
           row = IOSurfaceGetBytesPerRow(surface);
    if (!viaCI) {
      if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS)
        return false;
      const uint8_t *base = IOSurfaceGetBaseAddress(surface);
      for (size_t y = 0; y < h; ++y)
        memcpy(rgba + y * w * 4, base + y * row, w * 16);
      return IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL) ==
             KERN_SUCCESS;
    }
    CVPixelBufferRef cv = NULL;
    NSDictionary *attrs =
        @{(__bridge NSString *)kCVPixelBufferMetalCompatibilityKey : @YES};
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                         (__bridge CFDictionaryRef)attrs,
                                         &cv) != kCVReturnSuccess)
      return false;
    BOOL same = CVPixelBufferGetIOSurface(cv) &&
                IOSurfaceGetID(CVPixelBufferGetIOSurface(cv)) ==
                    IOSurfaceGetID(surface);
    CGColorSpaceRef space =
        CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    CIImage *image = [CIImage
        imageWithCVPixelBuffer:cv
                       options:@{kCIImageColorSpace : (__bridge id)space}];
    CIContext *ctx = [CIContext
        contextWithMTLDevice:p->device
                     options:@{
                       kCIContextWorkingColorSpace : (__bridge id)space,
                       kCIContextWorkingFormat : @(kCIFormatRGBAf),
                       kCIContextCacheIntermediates : @NO
                     }];
    CIRenderDestination *d =
        [[CIRenderDestination alloc] initWithBitmapData:rgba
                                                  width:w
                                                 height:h
                                            bytesPerRow:w * 16
                                                 format:kCIFormatRGBAf];
    d.colorSpace = space;
    d.flipped = YES;
    d.alphaMode = CIRenderDestinationAlphaPremultiplied;
    d.clamped = NO;
    d.dithered = NO;
    NSError *error = nil;
    CIRenderTask *task = [ctx startTaskToRender:image
                                  toDestination:d
                                          error:&error];
    BOOL ok = task && [task waitUntilCompletedAndReturnError:&error] != nil;
    if (!ok)
      NSLog(@"replay Core Image consumer failed %@", error);
    CGColorSpaceRelease(space);
    CVPixelBufferRelease(cv);
    return same && ok;
  }
}
void rm_replay_release(void *owner) { (void)CFBridgingRelease(owner); }

void rm_replay_drop_host_textures(void *owner) {
  RMReplaySurfaces *p = (__bridge RMReplaySurfaces *)owner;
  for (int i = 0; i < 3; ++i)
    p->textures[i] = nil;
}
