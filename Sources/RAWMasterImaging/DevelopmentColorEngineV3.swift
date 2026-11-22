import Foundation
import CoreImage
import Metal
import CryptoKit
import RAWMasterCore

/// Own versioned operators. Initial reference calibration is not Photos algorithm equivalence or qualification.
enum DevelopmentColorEngineV3 {
  static let operatorVersion = "rawmaster-point-v3.4-white/encoded-srgb-hue-fit256/curves-PCHIP-v3.1-parametric-v1"
  static let linearSRGB = DevelopmentColorEngineV2.linearSRGB
  static let context = makeContext()
  static func makeContext() -> CIContext {
    CIContext(options:[.workingColorSpace:linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false])
  }
  struct Kernels { let point, curvesLevels: CIKernel }
  private static let loaded: Result<Kernels,Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsDynamicLibraries else { throw DevelopmentError.unsupportedEngine }
    let kernels = try CIKernel.kernels(withMetalString:metalSource)
    guard let point = kernels.first(where:{$0.name == "rawmasterPointV3"}), let curves = kernels.first(where:{$0.name == "rawmasterCurvesLevelsV3"}) else { throw DevelopmentError.unsupportedEngine }
    return .init(point:point,curvesLevels:curves)
  }
  static var sourceSHA256: String { SHA256.hash(data:Data(metalSource.utf8)).map { String(format:"%02x",$0) }.joined() }
  static func prewarm(){_ = try? loaded.get()}
  static func pointwiseActive(_ p: DevelopmentAdjustmentsV3) -> Bool {
    (p.light.enabled && (p.light.brightness != 0 || p.light.contrast != 0 || p.light.blackPoint != 0 || p.light.whites != 0)) ||
    (p.color.enabled && (p.color.saturation != 0 || p.color.vibrance != 0 || p.color.cast != 0)) || p.blackAndWhite.enabled ||
    (p.effects?.enabled == true && (p.effects?.grain ?? 0) != 0)
  }
  static func curvesActive(_ p: DevelopmentCurvesV3) -> Bool {
    p.enabled && ((p.refineSaturation ?? 0) != 0 || p.parametric?.isActive == true || [p.rgb,p.red,p.green,p.blue].contains { !$0.curve.isNeutral || $0.inputBlack != 0 || $0.inputWhite != 1 })
  }
  static func levelsActive(_ p: DevelopmentLevelsV3) -> Bool { p.enabled && [p.luminance,p.rgb,p.red,p.green,p.blue].contains { $0 != .identity } }
  static func applyPointwise(_ p: DevelopmentAdjustmentsV3, to image: CIImage, context: CIContext? = nil,
                             checkCancellation: (() throws -> Void)? = nil, proxyScale: Double = 1) throws -> CIImage {
    try p.validate(); guard pointwiseActive(p) else { return image }
    let generalGrain = p.effects?.enabled == true && (p.effects?.grain ?? 0) != 0
    if p.blackAndWhite.enabled && (generalGrain || (p.blackAndWhite.grain != 0 && p.blackAndWhite.grainSamplingVersion != nil)) {
      return try DevelopmentGrainSamplingEngineV1.apply(p,to:image,context:context,checkCancellation:checkCancellation)
    }
    if generalGrain, let effects = p.effects {
      var point = p
      point.effects?.grain = 0
      let toned = try applyPointwise(point, to: image, context: context, checkCancellation: checkCancellation)
      return try DevelopmentGrainSamplingEngineV1.applyColorGrain(effects, to: toned, proxyScale: proxyScale)
    }
    let l = p.light, c = p.color, b = p.blackAndWhite
    let effectGrain = p.effects?.enabled == true ? p.effects?.grain ?? 0:0
    let combinedGrain = min(1,b.grain+effectGrain)
    let arguments: [Any] = [image,CIVector(x:l.brightness,y:l.contrast,z:l.blackPoint,w:l.whites),
      CIVector(x:c.saturation,y:c.vibrance,z:c.cast,w:0),CIVector(x:b.intensity,y:b.neutrals,z:b.tone,w:combinedGrain),
      CIVector(x:l.enabled ? 1:0,y:c.enabled ? 1:0,z:b.enabled ? 1:0,w:0)]
    guard let result = try loaded.get().point.apply(extent:image.extent,roiCallback:{ _,rect in rect },arguments:arguments) else { throw DevelopmentError.unreadable }
    return result
  }
  struct LevelPoint { let x, y: Double }
  /// Endpoint handles outrank coincident inner handles; midtones outrank shadows/highlights.
  /// Piecewise-linear five-handle mapping is our v3.1 definition, not a claim about Photos interpolation.
  static func levelPoints(_ value: DevelopmentLevelsChannelV3) -> [LevelPoint] {
    guard case .manual(let p) = value else { return [] }
    let span = p.outputWhite-p.outputBlack
    let candidates = [(p.black,p.outputBlack,3),(p.shadows,p.outputBlack+span*0.25,1),
      (p.midtones,p.outputBlack+span*0.5,2),(p.highlights,p.outputBlack+span*0.75,1),(p.white,p.outputWhite,3)]
    var unique: [(Double,Double,Int)] = []
    for value in candidates {
      if let last = unique.last, Float(last.0) == Float(value.0) {
        if value.2 > last.2 { unique[unique.count-1] = value }
      } else { unique.append(value) }
    }
    return unique.map { .init(x:$0.0,y:$0.1) }
  }
  static func referenceLevel(_ x: Double, points: [LevelPoint]) -> Double {
    guard let first = points.first, let last = points.last else { return x }
    if x <= first.x { return x+first.y-first.x }; if x >= last.x { return x+last.y-last.x }
    for i in 1..<points.count where x <= points[i].x {
      let a = points[i-1], b = points[i], t = (x-a.x)/(b.x-a.x); return a.y+(b.y-a.y)*t
    }
    return x
  }
  static func applyCurvesAndLevels(_ p: DevelopmentAdjustmentsV3, to image: CIImage, canonicalNaturalEvidence:PreviewNaturalCurveFiniteEvidenceV1? = nil) throws -> CIImage {
    if p.curves.enabled, let amount=p.curves.refineSaturation, amount != 0 {
      var withoutRefine=p;withoutRefine.curves.refineSaturation=nil
      let developed=try applyCurvesAndLevels(withoutRefine,to:image,canonicalNaturalEvidence:canonicalNaturalEvidence)
      return try DevelopmentRefineSaturationEngineV3.apply(p.curves,to:developed)
    }
    if p.curves.enabled, let parametric = p.curves.parametric, parametric.isActive {
      // Parametric tone is a separate, ordered GPU stage before the point channels and levels.
      var prefix = p
      prefix.levels = .init()
      prefix.curves = .init(enabled:true,rgb:.init(curve:try parametric.pointCurve()),algorithm:.legacyPCHIPV1)
      let developed = try applyLegacyCurvesAndLevels(prefix,to:image)
      var suffix = p; suffix.curves.parametric = nil
      return try applyCurvesAndLevels(suffix,to:developed,canonicalNaturalEvidence:canonicalNaturalEvidence)
    }
    if p.curves.algorithm == .naturalCubicGamma512LumaV1, curvesActive(p.curves) {
      try p.validate()
      let curved = try DevelopmentNaturalCubicCurvesV1.apply(p.curves,to:image,canonicalNaturalEvidence:canonicalNaturalEvidence)
      var levelsOnly = p; levelsOnly.curves.enabled = false
      return try applyLegacyCurvesAndLevels(levelsOnly,to:curved)
    }
    return try applyLegacyCurvesAndLevels(p,to:image)
  }
  /// Historical combined implementation. Its body and Metal source stay exact.
  static func applyLegacyCurvesAndLevels(_ p: DevelopmentAdjustmentsV3, to image: CIImage) throws -> CIImage {
    try p.validate(); let curvesOn = curvesActive(p.curves), levelsOn = levelsActive(p.levels)
    guard curvesOn || levelsOn else { return image }
    let channels = [p.curves.rgb,p.curves.red,p.curves.green,p.curves.blue]
    for channel in channels { guard Float(channel.inputBlack) < Float(channel.inputWhite) else { throw DevelopmentV3Error.unrepresentableParameters } }
    let legacyCurves = DevelopmentCurves(rgb:channels[0].curve,red:channels[1].curve,green:channels[2].curve,blue:channels[3].curve)
    let table = try DevelopmentColorEngineV2.Parameters(.init(curves:legacyCurves))
    let curveMask = curvesOn ? channels.enumerated().reduce(0) { $0 | (($1.element.curve.isNeutral && $1.element.inputBlack == 0 && $1.element.inputWhite == 1) ? 0:(1 << $1.offset)) } : 0
    let levels = [p.levels.luminance,p.levels.rgb,p.levels.red,p.levels.green,p.levels.blue]
    let points = levels.map(levelPoints), counts = points.map(\.count)
    let levelMask = levelsOn ? levels.enumerated().reduce(0) { $0 | ($1.element == .identity ? 0:(1 << $1.offset)) } : 0
    var storage = [Float](repeating:0,count:5*5*4)
    for row in 0..<5 { for (i,point) in points[row].enumerated() { let n = (row*5+i)*4; storage[n] = Float(point.x); storage[n+1] = Float(point.y); storage[n+3] = 1 } }
    let bytes = storage.withUnsafeBytes { Data($0) }
    let levelImage = CIImage(bitmapData:bytes,bytesPerRow:5*16,size:.init(width:5,height:5),format:.RGBAf,colorSpace:nil).samplingNearest()
    let arguments: [Any] = [image,table.image(),CIVector(x:Double(table.pieces[1].count),y:Double(table.pieces[2].count),z:Double(table.pieces[3].count),w:Double(table.pieces[4].count)),
      CIVector(x:channels[0].inputBlack,y:channels[1].inputBlack,z:channels[2].inputBlack,w:channels[3].inputBlack),
      CIVector(x:channels[0].inputWhite,y:channels[1].inputWhite,z:channels[2].inputWhite,w:channels[3].inputWhite),
      levelImage,CIVector(x:Double(counts[0]),y:Double(counts[1]),z:Double(counts[2]),w:Double(counts[3])),Double(counts[4]),CIVector(x:Double(curveMask),y:Double(levelMask),z:0,w:0)]
    guard let result = try loaded.get().curvesLevels.apply(extent:image.extent,roiCallback:{ index,rect in
      if index == 1 { return CGRect(x:0,y:0,width:30,height:5) }; if index == 2 { return CGRect(x:0,y:0,width:5,height:5) }; return rect
    },arguments:arguments) else { throw DevelopmentError.unreadable }
    return result
  }
  static func validateFinite(_ image: CIImage, context: CIContext = context,
                             checkCancellation: (() throws -> Void)? = nil) throws {
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: "显影有限值检查", stage: "全域归约", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer { ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome,
      pixelCount: outcome == .succeeded ? Int(image.extent.width * image.extent.height) : 0) }
    let mask=try DevelopmentColorEngineV2.finiteMaskForV3(image)
    let maximum=try DevelopmentCheckedMaximumV3.maximum(mask,domain:image.extent,context:context,checkCancellation:checkCancellation)
    guard maximum.x < 0.5 else { throw DevelopmentError.invalidEncoding }
    outcome = .succeeded
  }
  /// Retained direct-read regression seam. Production now uses the shared checked maximum
  /// transport, which validates all returned components after each real joined task.
  static func checkedFinitePixel(_ writeAndJoin: (UnsafeMutableRawPointer) throws -> Void) throws {
    var pixel = SIMD4<Float>(repeating:Float.nan)
    try withUnsafeMutableBytes(of:&pixel) { bytes in try writeAndJoin(bytes.baseAddress!) }
    // Cancellation never abandons an in-flight task or releases the borrowed pointer early.
    try Task.checkCancellation()
    guard pixel.x.isFinite, pixel.x < 0.5 else { throw DevelopmentError.invalidEncoding }
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float v3e(float x) { float a=abs(x); return (x<0?-1.0:1.0)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055); }
float v3d(float x) { float a=abs(x); return (x<0?-1.0:1.0)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4)); }
float3 v3e3(float3 x) { return float3(v3e(x.r),v3e(x.g),v3e(x.b)); }
float3 v3d3(float3 x) { return float3(v3d(x.r),v3d(x.g),v3d(x.b)); }
float v3y(float3 c) { return dot(c,float3(.2126,.7152,.0722)); }
float v3contrast(float x,float amount) {
  if(x<=0 || x>=1 || amount==0) return x;
  float pivot=.55, power=exp2(1.3*amount);
  return x<pivot?pivot*pow(x/pivot,power):1.0-(1.0-pivot)*pow((1.0-x)/(1.0-pivot),power);
}
float v3noise(float2 position) {
  uint2 p=uint2(int2(floor(position))); uint n=p.x*0x9e3779b9u ^ p.y*0x85ebca6bu ^ 0x021a31b7u;
  n^=n>>16; n*=0x7feb352du; n^=n>>15; n*=0x846ca68bu; n^=n>>16;
  return float(n>>8)*(1.0/16777216.0)-.5;
}
[[stitchable]] float4 rawmasterPointV3(sampler src,float4 light,float4 color,float4 bw,float4 flags) {
  float4 p=src.sample(src.coord()); if(!all(isfinite(p)) || p.a<=0) return p;
  float3 c=p.rgb/p.a;
  if(flags.x>0) {
    float y=v3y(c), u=v3e(y), w=clamp(u,0.0,1.0), target=v3contrast(u+.8*light.x*w*(1.0-w),light.y);
    float output=v3d(target); c=abs(y)>1e-8?c*(output/y):c+float3(output-y);
    float black=.05*light.z; c=(c-float3(black))/(1.0-black);
    // White adjusts the upper tonal range without moving the black endpoint.
    float whiteWeight=smoothstep(.45,1.0,clamp(v3e(v3y(c)),0.0,1.0));
    c*=1.0+.35*light.w*whiteWeight;
  }
  if(flags.y>0) {
    float3 e=v3e3(c); float l=v3y(e), top=max(e.r,max(e.g,e.b)), bottom=min(e.r,min(e.g,e.b));
    float sat=clamp((top-bottom)/max(abs(top),1e-4),0.0,1.0);
    float skin=(e.r>e.g && e.g>e.b)?0.5:1.0;
    float warm=(e.r>e.b && e.g>e.b)?1.0:0.0;
    float blue=max(0.0,e.b-max(e.r,e.g))*(1.0-clamp(l,0.0,1.0));
    e=float3(l)+(e-float3(l))*((1.0+color.x*(1.0-.391*warm))*(1.0+1.35*color.y*(1.0-sat)*skin));
    // One fixed256-source-sample calibration; does not imply recovery of Photos' color domain.
    e+=blue*(color.x*float3(-2.576,-.364,.447)+color.y*float3(-1.830,-.494,-.142));
    // Versioned initial cast calibration; not a recovered proprietary filter.
    float3 tint=float3(dot(e,float3(.0214143,.0479051,-.0105798))-.0019973,
      0.0,dot(e,float3(-.0231834,-.0894344,-.0299565))+.0047775);
    e+=2.0*color.z*tint; c=v3d3(e);
  }
  if(flags.z>0) {
    float3 e=v3e3(c); float g=v3y(e)+bw.x*(.09*(e.g-e.r)+.392*(e.g-e.b));
    float w=clamp(g,0.0,1.0); g+=.8*bw.y*w*(1.0-w); g=v3contrast(g,bw.z);
    if(bw.w!=0) g+=v3noise(src.coord())*(.06*bw.w)*(.35+sqrt(max(w,0.0)));
    c=float3(v3d(g));
  }
  return float4(c*p.a,p.a);
}
float v3curve(sampler table,float x,int row,int count) {
  float4 a=table.sample(float2(.5,float(row)+.5)), b=table.sample(float2(1.5,float(row)+.5));
  if(x<0) return x+b.b;
  for(int i=0;i<15;i++) { if(i>=count) break; a=table.sample(float2(float(i*2)+.5,float(row)+.5)); b=table.sample(float2(float(i*2)+1.5,float(row)+.5)); if(x<=a.g || i==count-1) break; }
  if(x>1) return x+(a.b+b.r+b.g+b.b)-1.0;
  float t=(x-a.r)/(a.g-a.r); return ((a.b*t+b.r)*t+b.g)*t+b.b;
}
float v3level(sampler table,float x,int row,int count) {
  if(count==0) return x;
  float2 a=table.sample(float2(.5,float(row)+.5)).rg;
  if(x<=a.x) return x+a.y-a.x;
  for(int i=1;i<5;i++) {
    if(i>=count) break; float2 b=table.sample(float2(float(i)+.5,float(row)+.5)).rg;
    if(x<=b.x) return mix(a.y,b.y,(x-a.x)/(b.x-a.x)); a=b;
  }
  return x+a.y-a.x;
}
[[stitchable]] float4 rawmasterCurvesLevelsV3(sampler src,sampler curves,float4 counts,float4 blacks,float4 whites,
 sampler levels,float4 levelCounts,float blueCount,float4 masks) {
  float4 p=src.sample(src.coord()); if(!all(isfinite(p)) || p.a<=0) return p;
  float3 c=v3e3(p.rgb/p.a); int cm=int(masks.x), lm=int(masks.y);
  for(int i=0;i<3;i++) {
    if((cm&1)!=0) c[i]=v3curve(curves,(c[i]-blacks.x)/(whites.x-blacks.x),1,int(counts.x));
    if((cm&(1<<(i+1)))!=0) c[i]=v3curve(curves,(c[i]-blacks[i+1])/(whites[i+1]-blacks[i+1]),i+2,int(counts[i+1]));
  }
  if((lm&1)!=0) { float y=v3y(c), output=v3level(levels,y,0,int(levelCounts.x)); c+=float3(output-y); }
  for(int i=0;i<3;i++) {
    if((lm&2)!=0) c[i]=v3level(levels,c[i],1,int(levelCounts.y));
    if((lm&(1<<(i+2)))!=0) { float n=i==0?levelCounts.z:(i==1?levelCounts.w:blueCount); c[i]=v3level(levels,c[i],i+2,int(n)); }
  }
  return float4(v3d3(c)*p.a,p.a);
}
} }
"""#
}
