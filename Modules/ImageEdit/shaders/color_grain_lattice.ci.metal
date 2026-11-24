float rmColorGrainHash(int2 p) {
  uint2 v=uint2(p); uint n=v.x*0x9e3779b9u ^ v.y*0x85ebca6bu ^ 0x021a31b7u;
  n^=n>>16; n*=0x7feb352du; n^=n>>15; n*=0x846ca68bu; n^=n>>16;
  return float(n>>8)*(1.0/16777216.0)-.5;
}
float rmColorGrainAt(int2 p, float size, float roughness) {
  if (size<0.0) return rmColorGrainHash(p);
  int2 cell=int2(floor(float2(p)/(1.0+15.0*size)));
  float a=rmColorGrainHash(cell), b=rmColorGrainHash(cell+int2(17,29));
  return mix(a,(a+b)*.5,1.0-roughness);
}
float rmSourceGrainSample(float2 at,float4 settings) {
  float2 native=at/settings.w-.5; int2 low=int2(floor(native)); float2 t=fract(native);
  float noise=rmColorGrainAt(low,settings.y,settings.z);
  if (settings.w<1.0) {
    float right=rmColorGrainAt(low+int2(1,0),settings.y,settings.z);
    float upper=rmColorGrainAt(low+int2(0,1),settings.y,settings.z);
    float diagonal=rmColorGrainAt(low+int2(1,1),settings.y,settings.z);
    noise=mix(mix(noise,right,t.x),mix(upper,diagonal,t.x),t.y);
  }
  return noise;
}
