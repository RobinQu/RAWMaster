#ifndef RAWMASTER_NATIVE_HALF_FIXTURE_H
#define RAWMASTER_NATIVE_HALF_FIXTURE_H
#import <Metal/Metal.h>
#include <stdio.h>
#define ENSURE(expr) do { if (!(expr)) { fprintf(stderr,"failed at line %d: %s\n",__LINE__,#expr);return 1; } } while(0)
typedef struct { unsigned calls, rejectAt; } Gate;
static uint32_t current(void *raw,uint64_t revision) {
  Gate *g=raw;
  return revision==77 && (++g->calls<g->rejectAt || g->rejectAt==0);
}
static id<MTLTexture> texture(id<MTLDevice> d,MTLPixelFormat format,NSUInteger w,NSUInteger h,MTLStorageMode storage) {
  MTLTextureDescriptor *t=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
  t.storageMode=storage;t.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsagePixelFormatView;
  return [d newTextureWithDescriptor:t];
}
static bool copy(id<MTLCommandQueue> queue,id<MTLTexture> t,id<MTLBuffer> b,NSUInteger pitch,bool upload) {
  id<MTLCommandBuffer> c=[queue commandBuffer];id<MTLBlitCommandEncoder> e=[c blitCommandEncoder];
  MTLSize size=MTLSizeMake(t.width,t.height,1);MTLOrigin origin=MTLOriginMake(0,0,0);
  if(upload)[e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:pitch sourceBytesPerImage:pitch*t.height sourceSize:size toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:origin];
  else [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:origin sourceSize:size toBuffer:b destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch*t.height];
  [e endEncoding];[c commit];[c waitUntilCompleted];return c.status==MTLCommandBufferStatusCompleted;
}
#endif
