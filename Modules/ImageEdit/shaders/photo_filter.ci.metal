#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rmFilterAxisV1(int k){return float((65535*k+31)/63)/65535.0;}
float rmFilterEncodeV1(float x){return x<=.0031308?12.92*x:1.055*pow(x,1.0/2.4)-.055;}
float3 rmFilterNodeV1(sampler table,int3 node){
 int index=node.x+64*node.y+4096*node.z;
 float2 at=float2(float(index%512)+.5,float(index/512)+.5);
 return table.sample(table.transform(at)).rgb;
}
float3 rmFilterCubeV1(sampler table,int3 cell,float3 f){
 float3 a=mix(rmFilterNodeV1(table,cell),rmFilterNodeV1(table,cell+int3(1,0,0)),f.x);
 float3 b=mix(rmFilterNodeV1(table,cell+int3(0,1,0)),rmFilterNodeV1(table,cell+int3(1,1,0)),f.x);
 float3 c=mix(rmFilterNodeV1(table,cell+int3(0,0,1)),rmFilterNodeV1(table,cell+int3(1,0,1)),f.x);
 float3 d=mix(rmFilterNodeV1(table,cell+int3(0,1,1)),rmFilterNodeV1(table,cell+int3(1,1,1)),f.x);
 return mix(mix(a,b,f.y),mix(c,d,f.y),f.z);
}
[[stitchable]] float4 rmPhotoFilterV1(sampler source,sampler lower,sampler upper,float4 params,float4 transport,destination dest){
 float4 p=source.sample(source.transform(dest.coord()));
 if(!all(isfinite(p))||p.a<0)return float4(as_type<float>(0x7fc00000u));
 if(p.a>1){
  uint bits=as_type<uint>(p.a);
  if(transport.x>.5&&bits>=0x3f800001u&&bits<=0x3f800003u)p.a=1;
  else return float4(as_type<float>(0x7fc00000u));
 }
 if(p.a<1.0/65535.0)return p;
 float3 u=p.rgb/p.a;if(!all(isfinite(u)))return float4(as_type<float>(0x7fc00000u));
 float3 bounded=clamp(u,0.0,1.0);
 float3 q=float3(rmFilterEncodeV1(bounded.r),rmFilterEncodeV1(bounded.g),rmFilterEncodeV1(bounded.b));
 int3 cell=int3(clamp(floor(q*63.0),0.0,62.0));float3 f;
 for(int c=0;c<3;c++){
  if(cell[c]>0&&q[c]<rmFilterAxisV1(cell[c]))cell[c]--;
  if(cell[c]<62&&q[c]>rmFilterAxisV1(cell[c]+1))cell[c]++;
  f[c]=(q[c]-rmFilterAxisV1(cell[c]))/(rmFilterAxisV1(cell[c]+1)-rmFilterAxisV1(cell[c]));
 }
 float3 delta;
 if(params.y>.5)delta=rmFilterCubeV1(upper,cell,f)*params.x;
 else if(params.x==0)delta=rmFilterCubeV1(lower,cell,f);
 else delta=mix(rmFilterCubeV1(lower,cell,f),rmFilterCubeV1(upper,cell,f),params.x);
 float3 v=u+delta;
 // Only outside the captured cube: Mono/Noir residuals lose chroma continuously withglobalt.
 // Exact100 then projects FINALv tostrictgray. Cube/lowalpha paths andSilvertone are untouched.
 if(params.z>.5&&(any(u<0.0)||any(u>1.0))){
  float3 base=clamp(u,0.0,1.0),residual=u-base;
  float luminance=dot(residual,float3(.2126,.7152,.0722));
  v=base+delta+mix(residual,float3(luminance),params.w);
  if(params.z>1.5){float y=dot(v,float3(.2126,.7152,.0722));v=float3(y);}
 }
 return float4(v*p.a,p.a); // No linearRGB clamp; actual sourcealpha is preserved.
}
} }
