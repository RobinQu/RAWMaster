float rmMaskSmooth(float a,float b,float x){float t=clamp((x-a)/max(b-a,1e-5),0.0,1.0);return t*t*(3-2*t);}
float rmMaskCompute(float4 pixel,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float2 coord){
 float2 uv=float2(coord.x/range.z,1.0-coord.y/range.w);int kind=int(mode.x);float mask=0;
 if(kind==0){float2 a=line.xy,b=line.zw,d=b-a;float t=dot(uv-a,d)/max(dot(d,d),1e-6);mask=rmMaskSmooth(0.0,max(mode.w,0.001),t);}
 else if(kind==1){float d=length((uv-radial.xy)/radial.zw);mask=1.0-rmMaskSmooth(1.0-mode.w,1.0,d);}
 else if(kind==2){float3 c=clamp(pixel.rgb/pixel.a,0.0,1.0);float y=dot(c,float3(.2126,.7152,.0722));float f=max(mode.w*.5,.001);mask=rmMaskSmooth(range.x-f,range.x+f,y)*(1.0-rmMaskSmooth(range.y-f,range.y+f,y));}
 else{float4 s=subject.sample(subject.coord());mask=s.a>0?s.r/s.a:0;}
 mask=clamp(mask,0.0,1.0);if(mode.y>.5)mask=1.0-mask;return mask*mode.z;
}
