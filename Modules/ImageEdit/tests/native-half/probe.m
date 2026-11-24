#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "probe.h"
#include <math.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "metal_fixture.h"
static RMImagePlan *plan(const char *wire) {
  RMImagePlan *p=NULL;
  return rm_image_plan_open_v2((const uint8_t*)wire,strlen(wire),NULL,0,RM_IMAGE_CPU,&p)==0?p:NULL;
}
int main(void) { @autoreleasepool {
  id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];
  enum {w=34,h=1026,pitch=512}; // Four full bands and a final two-row band.
  id<MTLTexture> source=texture(device,MTLPixelFormatRGBA16Float,w,h,MTLStorageModePrivate);
  id<MTLTexture> target=texture(device,MTLPixelFormatRGBA32Float,w/2,h/2,MTLStorageModePrivate);
  id<MTLBuffer> from=[device newBufferWithLength:pitch*h options:MTLResourceStorageModeShared], to=[device newBufferWithLength:pitch*h/2 options:MTLResourceStorageModeShared];
  for(int y=0;y<h;y++)for(int x=0;x<w;x++) {
    __fp16 *p=(__fp16*)((uint8_t*)from.contents+y*pitch)+4*x;
    p[0]=x/32.f;p[1]=y/512.f;p[2]=-x/32.f;p[3]=1;
  }
  ENSURE(copy(queue,source,from,pitch,true));
  ENSURE(copy(queue,target,to,pitch,true));
  RMImagePlan *linear=plan("{\"version\":2,\"working\":\"extended-linear-srgb-premul-f32\",\"output\":\"s\",\"nodes\":[{\"op\":\"source\",\"id\":\"s\"}]}");
  RMHalfProbe *program=NULL;
  ENSURE(linear);
  ENSURE(rm_image_half_program_open_probe_v1(linear,(__bridge void*)device,&program)==0&&program);
  Dl_info linked={0};
  ENSURE(dladdr((const void*)rm_image_half_render_probe_v1,&linked)&&linked.dli_fname);
  printf("loaded %s\n",linked.dli_fname);
  Gate g={0};
  const int checkedModes[]={0,3,4,5,6};
  for(int mode=0;mode<=6;mode++) {
    int rc=rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,mode,77,current,&g);
    fprintf(stderr,"mode %d -> %d\n",mode,rc); ENSURE(rc==0 && copy(queue,target,to,pitch,false));
    float error=0;
    for(int y=0;y<h/2;y++)for(int x=0;x<w/2;x++) {
      float *v=(float*)((uint8_t*)to.contents+y*pitch)+4*x;
      float a=(2*x+0.5f)/32.f,b=(h-1-2*y-0.5f)/512.f;
      error=fmaxf(error,fmaxf(fabsf(v[0]-a),fmaxf(fabsf(v[1]-b),fabsf(v[2]+a)))); ENSURE(v[3]==1.f);
    }
    printf("mode %d all %d native / %d half coordinates, max %g\n",mode,w*h,w*h/4,error);
    ENSURE(error<2e-6);
  }
  for (int i=0;i<16;i++) {
    g=(Gate){0,3};
    ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,3+i%2,77,current,&g)==5 && g.calls==3);
  }
  printf("16 successive revocations at the final pre-submit check returned stale\n");
  for (int mode=3;mode<=4;mode++) {
    g=(Gate){0,4};
    ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,mode,77,current,&g)==5);
    g=(Gate){0};
    ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,mode,77,current,&g)==0);
  }
  for (int mode=5;mode<=6;mode++) {
    int depth=mode==5?2:4;
    for (int gate=depth+2;gate<=depth+3;gate++) {
      g=(Gate){0,gate};
      ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,mode,77,current,&g)==5);
      ENSURE(g.calls==gate);
    }
    g=(Gate){0};
    ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,mode,77,current,&g)==0);
  }
  printf("grouped pre-submit and post-submit revocations for two/four bands drained and retried\n");
  id<MTLTexture> shared=texture(device,MTLPixelFormatRGBA16Float,w,h,MTLStorageModeShared);
  id<MTLTexture> view=[source newTextureViewWithPixelFormat:MTLPixelFormatRGBA16Float];
  ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)shared,(__bridge void*)target,3,77,current,&g)==1);
  ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)view,(__bridge void*)target,3,77,current,&g)==1);
  const char *curveFormat="{\"version\":2,\"working\":\"extended-linear-srgb-premul-f32\",\"output\":\"c\",\"nodes\":[{\"op\":\"source\",\"id\":\"s\"},{\"op\":\"basic_v3\",\"id\":\"b\",\"image\":\"s\"},{\"op\":\"curves_levels_v3\",\"id\":\"c\",\"image\":\"b\",\"curves\":{\"red\":{\"inputBlack\":0,\"inputWhite\":%s,\"points\":[{\"x\":0,\"y\":0},{\"x\":0.5,\"y\":0.6},{\"x\":1,\"y\":1}]}},\"levels\":{\"blue\":{\"black\":0,\"shadows\":0.3,\"midtones\":0.5,\"highlights\":0.7,\"white\":1,\"outputBlack\":0.05,\"outputWhite\":0.95}}}]}";
  char wire[1200];
  snprintf(wire,sizeof(wire),curveFormat,"1"); RMImagePlan *curved=plan(wire);
  snprintf(wire,sizeof(wire),curveFormat,"0.95"); RMImagePlan *changed=plan(wire);
  snprintf(wire,sizeof(wire),curveFormat,"1e-36"); RMImagePlan *overflow=plan(wire);
  RMHalfProbe *curveProgram=NULL;
  ENSURE(curved && changed && overflow);
  ENSURE(rm_image_half_program_open_probe_v1(curved,(__bridge void*)device,&curveProgram)==0);
  float *samples=malloc(w*h*4*sizeof(float)),*native=malloc(w*h*4*sizeof(float));
  ENSURE(samples && native);
  for(int y=0;y<h;y++)for(int i=0;i<4*w;i++)
    samples[y*w*4+i]=((__fp16*)((uint8_t*)from.contents+y*pitch))[i];
  RMImagePlan *cases[]={curved,changed,curved};
  for(int n=0;n<3;n++) {
    ENSURE(rm_image_plan_render_v2(cases[n],w,h,samples,w*h*4,NULL,0,native,w*h*4)==0);
    ENSURE(rm_image_half_render_probe_v1(curveProgram,cases[n],(__bridge void*)source,(__bridge void*)target,3,77,current,&g)==0);
    ENSURE(copy(queue,target,to,pitch,false));
    NSData *atomicFrame=[NSData dataWithBytes:to.contents length:pitch*h/2];
    for(int mode=4;mode<=6;mode++) {
      ENSURE(rm_image_half_render_probe_v1(curveProgram,cases[n],(__bridge void*)source,(__bridge void*)target,mode,77,current,&g)==0);
      ENSURE(copy(queue,target,to,pitch,false));
      for(int y=0;y<h/2;y++)
        ENSURE(memcmp((const uint8_t*)atomicFrame.bytes+y*pitch,(const uint8_t*)to.contents+y*pitch,w/2*16)==0);
    }
    float error=0;
    for(int y=0;y<h/2;y++)for(int x=0;x<w/2;x++)for(int c=0;c<4;c++) {
      float expected=0;
      for(int j=0;j<2;j++)for(int i=0;i<2;i++) expected+=0.25f*native[((h-1-2*y-j)*w+2*x+i)*4+c];
      const float got=((float*)((uint8_t*)to.contents+y*pitch))[4*x+c];
      error=fmaxf(error,fabsf(expected-got));
    }
    printf("active curve/manual level rebound %d RGB and alpha vs native CPU max %g; modes 3/4/5/6 identical bits\n",n,error);
    ENSURE(error<2e-6);
  }
  ENSURE(rm_image_half_render_probe_v1(curveProgram,linear,(__bridge void*)source,(__bridge void*)target,3,77,current,&g)==1);
  for(int k=0;k<5;k++)ENSURE(rm_image_half_render_probe_v1(curveProgram,overflow,(__bridge void*)source,(__bridge void*)target,checkedModes[k],77,current,&g)==3);
  free(native);free(samples);
  rm_image_half_program_close_probe_v1(curveProgram);
  rm_image_plan_close_v1(curved);rm_image_plan_close_v1(changed);rm_image_plan_close_v1(overflow);
  uint16_t *last=(uint16_t*)((uint8_t*)from.contents+(h-1)*pitch)+4*(w-1);
  for(int i=0;i<3;i++) {
    last[3]=i==0?0x3bff:0x3c00;last[0]=i==1?0x7e01:i==2?0x7c00:0;
    ENSURE(copy(queue,source,from,pitch,true));
    for(int k=0;k<5;k++)
      ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,checkedModes[k],77,current,&g)==3);
  }
  ((__fp16*)last)[0]=(w-1)/32.f;
  // The first physical sensor row feeds the last logical two-row band.
  uint16_t *logicalEnd=(uint16_t*)from.contents+4*(w-1);
  logicalEnd[0]=0x7e01;
  ENSURE(copy(queue,source,from,pitch,true));
  for(int k=0;k<5;k++)
    ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,checkedModes[k],77,current,&g)==3);
  ((__fp16*)logicalEnd)[0]=(w-1)/32.f;
  // Force a missing contribution inside the second half of the first full 8x8 workgroup.
  uint16_t *inner=(uint16_t*)((uint8_t*)from.contents+(h-6)*pitch)+4*2;
  inner[0]=0x7e01;
  ENSURE(copy(queue,source,from,pitch,true));
  ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,4,77,current,&g)==3);
  ((__fp16*)inner)[0]=2/32.f;
  uint16_t *secondBand=(uint16_t*)((uint8_t*)from.contents+(h-1-256-7)*pitch)+4*8;
  secondBand[0]=0x7c00;
  ENSURE(copy(queue,source,from,pitch,true));
  for(int mode=5;mode<=6;mode++)
    ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,mode,77,current,&g)==3);
  ((__fp16*)secondBand)[0]=8/32.f;
  ENSURE(copy(queue,source,from,pitch,true));
  ENSURE(rm_image_half_render_probe_v1(program,linear,(__bridge void*)source,(__bridge void*)target,4,77,current,&g)==0);
  printf("NaN in final two-row logical band rejected in all counters; interior lane invalid rejected; restored input retry passed\n");
  rm_image_half_program_close_probe_v1(program);rm_image_plan_close_v1(linear);
  printf("passed stale-after-submit/retry, private root, nonopaque/NaN/Inf\n");return 0;
}}
