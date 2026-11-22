import CoreImage

/// A single selected hue uses uniform parameters and can run pointwise across any image tile.
enum DevelopmentPointColorKernelV3 {
  static let kernel = CIColorKernel(source: #"""
float scEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float scDecode(float x){float a=abs(x);return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));}
kernel vec4 rmSingleColor(__sample pixel, vec4 shifts, vec4 options, float mode){
 if(pixel.a<=0.0)return pixel;
 vec3 c=pixel.rgb/pixel.a, e=vec3(scEncode(c.r),scEncode(c.g),scEncode(c.b));
 float hi=max(e.r,max(e.g,e.b)),lo=min(e.r,min(e.g,e.b)),span=hi-lo,h=0.0;
 if(span>1e-8)h=hi==e.r?(e.g-e.b)/span:(hi==e.g?2.0+(e.b-e.r)/span:4.0+(e.r-e.g)/span);
 h=fract(h/6.0+1.0);float sat=hi>1e-8?span/hi:0.0;
 float hueDistance=shifts.x-h;hueDistance-=floor(hueDistance+.5);
 float width=max(.005,.2*options.x);
 float weight=(1.0-smoothstep(width*.3,width,abs(hueDistance)))*smoothstep(.015,.12,sat);
 if(mode>1.5)return vec4(mix(vec3(dot(c,vec3(.2126,.7152,.0722))),c,weight)*pixel.a,pixel.a);
 if(mode>.5)return vec4(vec3(weight*pixel.a),pixel.a);
 if(weight<=0.0)return pixel;
 float variance=.5*weight*options.y;
 h=fract(h+shifts.y*weight+variance*hueDistance+1.0);
 sat=max(0.0,sat*(1.0+weight*shifts.z)+variance*(options.z-sat));
 hi+=variance*(options.w-hi);
 vec3 triangle=abs(fract(vec3(h)+vec3(0.0,2.0/3.0,1.0/3.0))*6.0-3.0);
 vec3 outColor=hi*mix(vec3(1.0),clamp(triangle-1.0,0.0,1.0),sat);
 float y=clamp(dot(outColor,vec3(.2126,.7152,.0722)),0.0,1.0);
 outColor+=weight*shifts.w*1.4*y*(1.0-y);
 return vec4(vec3(scDecode(outColor.r),scDecode(outColor.g),scDecode(outColor.b))*pixel.a,pixel.a);
}
"""#)
}
