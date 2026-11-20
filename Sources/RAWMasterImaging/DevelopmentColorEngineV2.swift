import Foundation
import CoreImage
import CryptoKit
import Metal
import RAWMasterCore

/// Versioned, pointwise canonical color processing. There is intentionally no RAW-base cache here.
enum DevelopmentColorEngineV2 {
  static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
  static let context = CIContext(options: [.workingColorSpace: linearSRGB,
    .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
  struct Kernels { let color: CIKernel; let finite: CIKernel; let compileNanoseconds: UInt64 }
  private static let loaded: Result<Kernels, Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsDynamicLibraries else { throw DevelopmentError.unsupportedEngine }
    let started = DispatchTime.now().uptimeNanoseconds
    let kernels = try CIKernel.kernels(withMetalString: metalSource)
    guard let color = kernels.first(where: { $0.name == "rawmasterColorV2" }),
      let finite = kernels.first(where: { $0.name == "rawmasterFiniteV2" }) else { throw DevelopmentError.unsupportedEngine }
    return Kernels(color: color, finite: finite, compileNanoseconds: DispatchTime.now().uptimeNanoseconds-started)
  }
  static var sourceSHA256: String { SHA256.hash(data: Data(metalSource.utf8)).map { String(format: "%02x", $0) }.joined() }
  static func compileNanoseconds() throws -> UInt64 { try loaded.get().compileNanoseconds }

  struct Piece {
    let x0: Double, x1: Double, a: Double, b: Double, c: Double, d: Double
    func value(_ x: Double) -> Double { let t = (x-x0)/(x1-x0); return ((a*t+b)*t+c)*t+d }
  }
  struct Parameters {
    let color: DevelopmentColorAdjustments
    let pieces: [[Piece]] // tone,master,R,G,B
    let wheels: [SIMD4<Double>]
    init(_ color: DevelopmentColorAdjustments) throws {
      try color.validate(); self.color = color
      let t = color.tones
      // Algebraically normalized anchors; endpoint+100 must remain exactly within[0,1].
      let anchors = [(t.blacks/100+1)/12,(7+3*t.shadows/100)/24,0.5,(17+3*t.highlights/100)/24,(11+t.whites/100)/12]
      let tone = DevelopmentCurve(points: zip([0.0,0.25,0.5,0.75,1.0],anchors).map { .init(x:$0.0,y:$0.1) })
      func convert(_ curve: DevelopmentCurve, tone: Bool = false) throws -> [Piece] {
        try curve.segments().map { .init(x0:$0.lowerX,x1:$0.upperX,a:$0.a*(tone ? 1.2:1),b:$0.b*(tone ? 1.2:1),
          c:$0.c*(tone ? 1.2:1),d:$0.d*(tone ? 1.2:1)-(tone ? 0.1:0)) }
      }
      pieces = try [convert(tone,tone:true),convert(color.curves.rgb),convert(color.curves.red),convert(color.curves.green),convert(color.curves.blue)]
      wheels = [color.grading.shadows,color.grading.midtones,color.grading.highlights,color.grading.global].map { w in
        let angle = w.hueDegrees * .pi / 180
        let q = SIMD3<Double>(cos(angle),cos(angle-2 * .pi/3),cos(angle+2 * .pi/3))
        let v = (q-SIMD3<Double>(repeating: luma(q))) * (0.15*w.saturation/100)
        return .init(v.x,v.y,v.z,0.25*w.luminance/100)
      }
    }
    func evaluate(_ x: Double, row: Int) -> Double {
      let p = pieces[row]
      if x < 0 { return x+p[0].d }
      if x > 1 { return x+p[p.count-1].value(1)-1 }
      return (p.first { x <= $0.x1 } ?? p[p.count-1]).value(x)
    }
    func image() -> CIImage {
      var storage = [Float](repeating: 0,count:30*5*4)
      for (row, pieces) in pieces.enumerated() { for (index,p) in pieces.enumerated() {
        let start = (row*30+index*2)*4
        let values = [p.x0,p.x1,p.a,1,p.b,p.c,p.d,1]
        for i in 0..<8 { storage[start+i] = Float(values[i]) }
      } }
      let data = storage.withUnsafeBytes { Data($0) }
      return CIImage(bitmapData:data,bytesPerRow:30*16,size:CGSize(width:30,height:5),format:.RGBAf,colorSpace:nil)
        .samplingNearest()
    }
  }
  private static func vector(_ value: SIMD4<Double>) -> CIVector { CIVector(x:value.x,y:value.y,z:value.z,w:value.w) }
  static func apply(_ color: DevelopmentColorAdjustments, to image: CIImage) throws -> CIImage {
    try color.validate(); if color.isNeutral { return image }
    let params = try Parameters(color), kernel = try loaded.get().color, tones = color.tones, curves = color.curves
    let active = [curves.rgb,curves.red,curves.green,curves.blue].enumerated().reduce(0) { $0 | ($1.element.isNeutral ? 0:(1 << $1.offset)) }
    let toneActive = [tones.contrast,tones.highlights,tones.shadows,tones.whites,tones.blacks].contains { $0 != 0 }
    let args: [Any] = [image,params.image(),
      vector(.init(pow(2,tones.contrast/100),toneActive ? 1:0,0,0)),
      vector(.init(Double(params.pieces[1].count),Double(params.pieces[2].count),Double(params.pieces[3].count),Double(params.pieces[4].count))),
      vector(params.wheels[0]),vector(params.wheels[1]),vector(params.wheels[2]),vector(params.wheels[3]),
      vector(.init(tones.vibrance/100,tones.saturation/100,color.grading.blending/100,color.grading.balance/100)),
      vector(.init(Double(active),color.grading.isNeutral ? 0:1,(tones.vibrance != 0 || tones.saturation != 0) ? 1:0,0))]
    guard let result = kernel.apply(extent:image.extent,roiCallback:{ index,rect in index == 1 ? CGRect(x:0,y:0,width:30,height:5):rect },arguments:args) else { throw DevelopmentError.unreadable }
    return result
  }
  /// Validate before SDR encoding can hide NaN/Inf. This uncached reference pass is not a speed claim.
  static func validateFinite(_ image: CIImage, context: CIContext = context) throws {
    guard let mask = try loaded.get().finite.apply(extent:image.extent,roiCallback:{ _,rect in rect },arguments:[image]) else { throw DevelopmentError.unreadable }
    let maximum = mask.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:image.extent)])
    var pixel = [Float](repeating:0,count:4)
    context.render(maximum,toBitmap:&pixel,rowBytes:16,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBAf,colorSpace:linearSRGB)
    guard pixel[0].isFinite, pixel[0] < 0.5 else { throw DevelopmentError.invalidEncoding }
  }
  /// V3-only caller reuses the exact historical finite mask/reduction graph. The V2 entry
  /// above intentionally retains its original construction, void render and predicate unchanged.
  static func finiteMaskForV3(_ image: CIImage) throws -> CIImage {
    guard let mask = try loaded.get().finite.apply(extent:image.extent,roiCallback:{ _,rect in rect },arguments:[image]) else { throw DevelopmentError.unreadable }
    return mask
  }
  static func finiteMaximumForV3(_ image: CIImage) throws -> CIImage {
    guard let mask = try loaded.get().finite.apply(extent:image.extent,roiCallback:{ _,rect in rect },arguments:[image]) else { throw DevelopmentError.unreadable }
    return mask.applyingFilter("CIAreaMaximum",parameters:[kCIInputExtentKey:CIVector(cgRect:image.extent)])
  }
  static func luma(_ value: SIMD3<Double>) -> Double { value.x*0.2126+value.y*0.7152+value.z*0.0722 }
  static func encode(_ x: Double) -> Double { let a = abs(x); return (x < 0 ? -1:1)*(a <= 0.0031308 ? 12.92*a:1.055*pow(a,1/2.4)-0.055) }
  static func decode(_ x: Double) -> Double { let a = abs(x); return (x < 0 ? -1:1)*(a <= 0.04045 ? a/12.92:pow((a+0.055)/1.055,2.4)) }
  static func smooth(_ a: Double,_ b: Double,_ x: Double) -> Double { let t = min(1,max(0,(x-a)/(b-a))); return t*t*(3-2*t) }
  static func reference(_ input: SIMD4<Double>, color: DevelopmentColorAdjustments) throws -> SIMD4<Double> {
    try color.validate(); guard (0..<4).allSatisfy({ input[$0].isFinite }) else { throw DevelopmentError.invalidEncoding }
    if color.isNeutral { return input }
    let alpha = input.w; if alpha <= 0 { return SIMD4(0,0,0,alpha) }
    let p = try Parameters(color), t = color.tones
    var c = SIMD3(input.x,input.y,input.z)/alpha
    if [t.contrast,t.highlights,t.shadows,t.whites,t.blacks].contains(where:{ $0 != 0 }) {
      let y = luma(c), encoded = encode(y), out = decode(0.5+pow(2,t.contrast/100)*(p.evaluate(encoded,row:0)-0.5))
      c += SIMD3(repeating:out-y)
    }
    c = SIMD3(encode(c.x),encode(c.y),encode(c.z))
    let curves = [color.curves.red,color.curves.green,color.curves.blue]
    for channel in 0..<3 {
      if !color.curves.rgb.isNeutral { c[channel] = p.evaluate(c[channel],row:1) }
      if !curves[channel].isNeutral { c[channel] = p.evaluate(c[channel],row:channel+2) }
    }
    if !color.grading.isNeutral {
      let u = min(1,max(0,luma(c))), center = 0.5-0.25*color.grading.balance/100, radius = 0.1+0.4*color.grading.blending/100
      let ws = 1-smooth(center-radius,center,u), wh = smooth(center,center+radius,u), weights = [ws,1-ws-wh,wh]
      var wheel = SIMD4<Double>(repeating:0)
      for index in 0..<3 { wheel += p.wheels[index]*weights[index] }
      c += SIMD3(wheel.x,wheel.y,wheel.z)*(4*u*(1-u))+SIMD3(repeating:wheel.w)
      c += SIMD3(p.wheels[3].x,p.wheels[3].y,p.wheels[3].z)*(4*u*(1-u))+SIMD3(repeating:p.wheels[3].w)
    }
    if t.vibrance != 0 || t.saturation != 0 {
      let l = luma(c), top = max(c.x,max(c.y,c.z)), bottom = min(c.x,min(c.y,c.z))
      let saturation = min(1,max(0,(top-bottom)/max(abs(top),1e-4)))
      c = SIMD3(repeating:l)+(c-SIMD3(repeating:l))*((1+t.saturation/100)*(1+t.vibrance/100*(1-saturation)))
    }
    c = SIMD3(decode(c.x),decode(c.y),decode(c.z))*alpha
    guard (0..<3).allSatisfy({ c[$0].isFinite }) else { throw DevelopmentError.invalidEncoding }
    return SIMD4(c.x,c.y,c.z,alpha)
  }

  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float rmLuma(float3 v) { return dot(v,float3(0.2126,0.7152,0.0722)); }
float rmE(float x) { float a=abs(x); return (x<0?-1.0:1.0)*(a<=0.0031308?12.92*a:1.055*pow(a,1.0/2.4)-0.055); }
float rmD(float x) { float a=abs(x); return (x<0?-1.0:1.0)*(a<=0.04045?a/12.92:pow((a+0.055)/1.055,2.4)); }
float3 rmE3(float3 x) { return float3(rmE(x.r),rmE(x.g),rmE(x.b)); }
float3 rmD3(float3 x) { return float3(rmD(x.r),rmD(x.g),rmD(x.b)); }
float rmCurve(sampler table,float x,int row,int count) {
  float4 first=table.sample(float2(0.5,float(row)+0.5));
  float4 firstB=table.sample(float2(1.5,float(row)+0.5));
  if(x<0) return x+firstB.b;
  float4 a=first,b=firstB;
  for(int i=0;i<15;i++) {
    if(i>=count) break;
    a=table.sample(float2(float(i*2)+0.5,float(row)+0.5));
    b=table.sample(float2(float(i*2)+1.5,float(row)+0.5));
    if(x<=a.g || i==count-1) break;
  }
  if(x>1) return x+(a.b+b.r+b.g+b.b)-1.0;
  float t=(x-a.r)/(a.g-a.r);
  return ((a.b*t+b.r)*t+b.g)*t+b.b;
}
[[stitchable]] float4 rawmasterColorV2(sampler src,sampler coeff,float4 tone,float4 counts,
  float4 shadows,float4 midtones,float4 highlights,float4 global,float4 misc,float4 flags) {
  float4 pixel=src.sample(src.coord());
  // Preserve invalid source values for the finite validation mask, even under alpha0.
  if(!all(isfinite(pixel))) return pixel;
  float alpha=pixel.a;
  if(alpha<=0) return float4(0,0,0,alpha);
  float3 c=pixel.rgb/alpha;
  if(tone.y>0) {
    float y=rmLuma(c), p=rmE(y), out=rmD(0.5+tone.x*(rmCurve(coeff,p,0,4)-0.5));
    c+=float3(out-y);
  }
  c=rmE3(c);
  int mask=int(flags.x);
  for(int channel=0;channel<3;channel++) {
    if((mask&1)!=0) c[channel]=rmCurve(coeff,c[channel],1,int(counts.x));
    if((mask&(1<<(channel+1)))!=0) c[channel]=rmCurve(coeff,c[channel],channel+2,int(counts[channel+1]));
  }
  if(flags.y>0) {
    float u=clamp(rmLuma(c),0.0,1.0), m=0.5-0.25*misc.w, r=0.1+0.4*misc.z;
    float ws=1.0-smoothstep(m-r,m,u), wh=smoothstep(m,m+r,u);
    float4 wheel=ws*shadows+(1.0-ws-wh)*midtones+wh*highlights;
    c+=wheel.rgb*(4.0*u*(1.0-u))+float3(wheel.a);
    c+=global.rgb*(4.0*u*(1.0-u))+float3(global.a);
  }
  if(flags.z>0) {
    float l=rmLuma(c), top=max(c.r,max(c.g,c.b)), bottom=min(c.r,min(c.g,c.b));
    float s=clamp((top-bottom)/max(abs(top),1e-4),0.0,1.0);
    c=float3(l)+(c-float3(l))*((1.0+misc.y)*(1.0+misc.x*(1.0-s)));
  }
  return float4(rmD3(c)*alpha,alpha);
}
[[stitchable]] float4 rawmasterFiniteV2(sampler src) {
  float4 p=src.sample(src.coord()); return float4(all(isfinite(p))?0.0:1.0,0,0,1);
}
} }
"""#
}
