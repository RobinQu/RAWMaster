float rmMaskPointEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float rmMaskPointDecode(float x){float a=abs(x);return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));}
float4 rmCompositeGrain(float4 pixel,float noise,float mask,float amount){
 if(mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a,e=float3(rmMaskPointEncode(c.r),rmMaskPointEncode(c.g),rmMaskPointEncode(c.b));
 float level=clamp(rmMaskPointEncode(dot(c,float3(.2126,.7152,.0722))),0.0,1.0);
 e+=noise*(.06*amount*mask)*(.35+sqrt(level));
 return float4(float3(rmMaskPointDecode(e.r),rmMaskPointDecode(e.g),rmMaskPointDecode(e.b))*pixel.a,pixel.a);
}
