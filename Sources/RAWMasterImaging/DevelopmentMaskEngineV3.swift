import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// Source-space, ordered local tonal and Glow layers. Subject inference is captured into the recipe;
/// replay is deterministic. Glow style/range/spread/warmth/direction/softness are globally shared.
enum DevelopmentMaskEngineV3 {
  static let operatorVersion="mask-v14-local-dehaze/linear-radial-range-subject/ordered-f32/source-normalized/local-glow-fused-v1/local-point-color-v1/local-light-extended-v1/local-wb-composite-v1/local-hue-colorize-v1/local-log-bands-v1/local-grain-v1/local-curves-v1/local-grading-v1/local-detail-v1/local-defringe-protection-v1/point-library-isolated-v1"
  private struct Kernels { let layer,glowLayer,pointColor,pointColorOnly,composite,grain,sourceGrain,moire,dehaze,scopeCoverage:CIKernel }
  private static let kernels:Result<Kernels,Error>=Result {
    guard let device=MTLCreateSystemDefaultDevice(),device.supportsDynamicLibraries else{throw DevelopmentError.unsupportedEngine}
    let all=try CIKernel.kernels(withMetalString:metalSource)
    // Keep the point-cloud kernel isolated from differently parameterized layer kernels.
    let pointAll=try CIKernel.kernels(withMetalString:metalSource)
    func get(_ name:String,kernels:[CIKernel])->CIKernel?{kernels.first(where:{$0.name==name})}
    guard let layer=get("rmMaskLayerV7",kernels:all),let glowLayer=get("rmMaskGlowLayerV7",kernels:all),
      let pointColor=get("rmMaskPointColorV7",kernels:pointAll),let pointColorOnly=get("rmMaskPointColorOnly",kernels:pointAll),let composite=get("rmMaskComposite",kernels:all),
      let grain=get("rmMaskGrain",kernels:all),let sourceGrain=get("rmSourceMaskGrain",kernels:all),let moire=get("rmMaskMoire",kernels:all),let dehaze=get("rmMaskDehaze",kernels:all),
      let scopeCoverage=get("rmMaskScopeCoverage",kernels:all) else{throw DevelopmentError.unsupportedEngine}
    return .init(layer:layer,glowLayer:glowLayer,pointColor:pointColor,pointColorOnly:pointColorOnly,composite:composite,grain:grain,sourceGrain:sourceGrain,moire:moire,dehaze:dehaze,scopeCoverage:scopeCoverage)
  }
  /// Captures coverage before the selected layer edits its pixels. Later layers may change
  /// the displayed colors without changing which pixels a luminance range originally selected.
  final class ScopeSelection {
    let layer: DevelopmentMaskLayerV3
    private(set) var coverage: CIImage?
    init(_ layer: DevelopmentMaskLayerV3) { self.layer = layer }
    func capture(_ input: CIImage) throws {
      let (subject, args) = try maskInputs(layer, image: input)
      guard let result = try kernels.get().scopeCoverage.apply(extent: input.extent,
        roiCallback:maskROI(layer, subject:subject, index:1), arguments: args) else { throw DevelopmentV3Error.invalidGraph }
      coverage = result
    }
  }
  private static func maskInputs(_ layer: DevelopmentMaskLayerV3, image: CIImage, opacity: Double? = nil) throws -> (CIImage, [Any]) {
    let subject: CIImage
    if layer.kind == .subject {
      guard let data = layer.subjectPNG, let decoded = CIImage(data: data, options: layer.semanticSnapshot == nil ? [:] : [.colorSpace: NSNull()]), !decoded.extent.isEmpty else { throw DevelopmentError.unreadable }
      subject = decoded.transformed(by: .init(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
        .transformed(by: .init(scaleX: image.extent.width / decoded.extent.width, y: image.extent.height / decoded.extent.height))
    } else { subject = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) }
    let kind: Double = switch layer.kind { case .linear: 0; case .radial: 1; case .range: 2; case .subject: 3 }
    return (subject, [image, subject, CIVector(x: kind, y: layer.inverted ? 1 : 0, z: opacity ?? layer.opacity, w: layer.feather),
      CIVector(x: layer.start.x, y: layer.start.y, z: layer.end.x, w: layer.end.y),
      CIVector(x: layer.center.x, y: layer.center.y, z: layer.radiusX, w: layer.radiusY),
      CIVector(x: layer.rangeLower, y: layer.rangeUpper, z: image.extent.width, w: image.extent.height)])
  }
  /// Frozen Gray8 is already transformed to source coordinates. Each pointwise kernel samples
  /// only its output tile and one original Gray8 texel on either side for interpolation.
  /// Requesting the entire upscaled matte for every finite-reduction tile forces a native F32
  /// intermediate (about 960 MB on a 61 MP capture), including for a one-pixel reduction.
  static func maskROI(_ layer: DevelopmentMaskLayerV3, subject: CIImage, index: Int32) -> CIKernelROICallback {
    let extent = subject.extent
    guard let snapshot = layer.semanticSnapshot else { return { sampler, rect in sampler == index ? extent : rect } }
    let dx = max(1, ceil(extent.width / CGFloat(snapshot.width)))
    let dy = max(1, ceil(extent.height / CGFloat(snapshot.height)))
    return { sampler, rect in
      sampler == index ? rect.insetBy(dx: -dx, dy: -dy).intersection(extent) : rect
    }
  }
  static func prewarm(){_ = try? kernels.get()}
  static func active(_ layers:[DevelopmentMaskLayerV3])->Bool {
    layers.contains{$0.enabled && $0.opacity>0 && !$0.adjustments.isNeutral}
  }
  static func usesDefringe(_ layers:[DevelopmentMaskLayerV3])->Bool {
    layers.contains{$0.enabled && $0.opacity>0 && ($0.adjustments.defringe ?? 0) != 0}
  }
  private static func pointParameters(_ sample:DevelopmentPointColorSampleV3)->(CIVector,CIVector) {
    let color=sample.sampledColor
    let encoded=SIMD3<Double>(DevelopmentColorEngineV2.encode(color.red),DevelopmentColorEngineV2.encode(color.green),DevelopmentColorEngineV2.encode(color.blue))
    let high=max(encoded.x,max(encoded.y,encoded.z)),low=min(encoded.x,min(encoded.y,encoded.z))
    let saturation=high>1e-8 ? (high-low)/high:0
    return (CIVector(x:DevelopmentGlobalEngineV3.hue(encoded),y:sample.hue/360,z:sample.saturation/100,w:sample.luminance/70),
      CIVector(x:sample.range,y:(sample.variance ?? 0)/100,z:saturation,w:high))
  }
  static func apply(_ layers:[DevelopmentMaskLayerV3],to input:CIImage,context:CIContext,
                    glow sharedGlow:DevelopmentGlowV3?=nil,optics:DevelopmentOpticsV3?=nil,
                    checkCancellation:(()throws->Void)?=nil,deferValidation:Bool=false,scopeSelection:ScopeSelection?=nil,sourceGrainScale:Double?=nil,legacyCoverage:DevelopmentLegacyMaskOutput.Coverage?=nil)throws->CIImage {
    try DevelopmentMaskLayerV3.validateLayers(layers)
    guard active(layers) else { try scopeSelection?.capture(input); return input }
    try sharedGlow?.validate()
    let hasGlow=layers.contains{$0.enabled && $0.opacity>0 && ($0.adjustments.glowAmount ?? 0)>0}
    let localDefringe=usesDefringe(layers)
    let telemetry=ImagePerformanceTelemetry.shared.begin(operation:"DevelopmentMaskEngineV3.apply",
      stage:hasGlow ? "local-glow":localDefringe ? "local-defringe":"local-tone",boundary:deferValidation ? .graphBuild : .apiReturn)
    let pixels=Int(input.extent.width*input.extent.height)
    var telemetryOutcome=ImagePerformanceOutcome.failed
    defer{ImagePerformanceTelemetry.shared.end(telemetry,outcome:telemetryOutcome,pixelCount:pixels)}
    let kernels=try self.kernels.get()
    var image=input
    if localDefringe {
      // Global correction is deferred only for this new path. Negative amounts restore the actual
      // pre-Defringe pixels, rather than undoing earlier local layers or adding another blur.
      let unprotected=image
      image=try DevelopmentDefringeEngineV3.apply(optics,to:image)
      for layer in layers where layer.enabled && layer.opacity>0 && (layer.adjustments.defringe ?? 0)<0 {
        try checkCancellation?()
        let (subject, geometry) = try maskInputs(layer, image: image, opacity: layer.opacity * min(1, -(layer.adjustments.defringe ?? 0)))
        var args = geometry
        args.insert(unprotected,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:args)else{throw DevelopmentError.unreadable}
        image=output
      }
    }
    for layer in layers {
      if layer.id == scopeSelection?.layer.id { try scopeSelection?.capture(image) }
      guard layer.enabled, layer.opacity>0, !layer.adjustments.isNeutral else { continue }
      try checkCancellation?()
      try legacyCoverage?.capture(layer, input: image)
      let a=layer.adjustments
      let (subject, geometry) = try maskInputs(layer, image: image)
      var args: [Any] = geometry + [
        CIVector(x:a.exposure,y:a.highlights,z:a.shadows,w:a.saturation),
        CIVector(x:a.contrast ?? 0,y:a.whites ?? 0,z:a.blacks ?? 0,w:0),
        CIVector(x:a.hue ?? 0,y:a.fineAdjustment == true ? 0.1:1,z:a.colorizeAmount ?? 1,w:0),
        CIVector(x:a.colorize?.red ?? 0,y:a.colorize?.green ?? 0,z:a.colorize?.blue ?? 0,w:a.colorize == nil ? 0:1)]
      let temperature=a.temperature ?? 0,tint=a.tint ?? 0
      if temperature != 0 || tint != 0 {
        // Local offsets are defined around the image-working 6500K reference, not camera As Shot metadata.
        let warmed=image.applyingFilter("CITemperatureAndTint",parameters:[
          "inputNeutral":CIVector(x:6500,y:0),
          "inputTargetNeutral":CIVector(x:6500+5000*temperature,y:150*tint)])
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(warmed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      let texture=a.texture ?? 0,clarity=a.clarity ?? 0
      if texture != 0 || clarity != 0 {
        let portrait=image.extent.height>image.extent.width
        let bandInput=portrait ? image.oriented(.left):image
        let size=DevelopmentPixelSize(width:Int(bandInput.extent.width),height:Int(bandInput.extent.height))
        let radii=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:size)
        var changed=bandInput
        if texture != 0 { changed=try DevelopmentAdvancedDetailEngineV3.applyBand(.texture,amount:texture*100,to:changed,radius:radii.texture) }
        if clarity != 0 { changed=try DevelopmentAdvancedDetailEngineV3.applyBand(.clarity,amount:clarity*100,to:changed,radius:radii.clarity) }
        if portrait { changed=changed.oriented(.right) }
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let grain=a.grain,grain>0 {
        let settings=DevelopmentEffectsV3(enabled:true,grain:grain,grainSize:a.grainSize,grainRoughness:a.grainRoughness)
        var grainArgs=Array(args.prefix(6))
        let filtered:CIImage?
        if let sourceGrainScale {
          guard sourceGrainScale>0,sourceGrainScale<=1 else {throw DevelopmentV3Error.invalidGraph}
          grainArgs.append(DevelopmentGrainSamplingEngineV1.colorGrainSettings(settings,scale:sourceGrainScale))
          if layer.kind == .subject {
            filtered=kernels.sourceGrain.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:1),arguments:grainArgs)
          } else {
            // Analytic masks only need the colour input. A second 1x1 sampler can collide
            // with another cached Core Image program after a long sequence of local edits.
            grainArgs.remove(at:1)
            filtered=try analyticalGrain.get().apply(extent:image.extent,roiCallback:{_,rect in rect},arguments:grainArgs)
          }
        } else {
          let noise=try DevelopmentGrainSamplingEngineV1.image(image.extent,effects:settings)
          grainArgs.insert(noise,at:1);grainArgs.append(grain)
          filtered=kernels.grain.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:grainArgs)
        }
        guard let output=filtered else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
        // The native-lattice kernel already composites its mask. Avoid asking Core Image
        // to fuse a second, neutral tonal kernel with a different argument layout.
        if sourceGrainScale != nil {
          var remaining=a
          remaining.grain=nil
          if remaining.isNeutral { continue }
        }
      }
      if let curves=a.curves,curves.enabled {
        var local=DevelopmentAdjustmentsV3();local.curves=curves
        let changed=try DevelopmentColorEngineV3.applyCurvesAndLevels(local,to:image)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let grading=a.grading,!grading.isNeutral {
        let changed=try DevelopmentColorEngineV2.apply(.init(grading:grading),to:image)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let lut = a.gradingLUT, lut.amount > 0 {
        let changed = try DevelopmentGradingLUTEngine.apply(lut, to: image)
        var compositeArgs = Array(args.prefix(6))
        compositeArgs.insert(changed, at: 1)
        guard let output = kernels.composite.apply(extent:image.extent, roiCallback:maskROI(layer, subject:subject, index:2),
                                                   arguments:compositeArgs) else { throw DevelopmentError.unreadable }
        image = output
        args[0] = image
      }
      if let defringe=a.defringe,defringe>0 {
        let local=DevelopmentOpticsV3(defringe:.init(enabled:true,purpleAmount:defringe*100,greenAmount:defringe*100))
        let changed=try DevelopmentDefringeEngineV3.apply(local,to:image)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      let sharpness=a.sharpness ?? 0,noiseReduction=a.noiseReduction ?? 0
      if sharpness>0 || noiseReduction>0 {
        var local=DevelopmentAdjustmentsV3()
        if sharpness>0 { local.sharpen = .init(enabled:true,intensity:sharpness) }
        if noiseReduction>0 { local.noiseReduction = .init(enabled:true,sourceCapability:.image,nonRawAmount:noiseReduction*5) }
        let changed=try DevelopmentGlobalEngineV3.apply(local,to:image,sourceIsRAW:false)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if sharpness<0 {
        let changed=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(0.1,-sharpness*1.2)]).cropped(to:image.extent)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let moire=a.moireReduction,moire>0 {
        let blurred=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.5]).cropped(to:image.extent)
        var moireArgs=Array(args.prefix(6));moireArgs.insert(blurred,at:1);moireArgs.append(moire)
        guard let output=kernels.moire.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:moireArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let dehaze=a.dehaze,dehaze != 0 {
        let radius=max(1,min(image.extent.width,image.extent.height)*0.01)
        let airlight=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:image.extent)
        var dehazeArgs=Array(args.prefix(6));dehazeArgs.insert(airlight,at:1);dehazeArgs.append(dehaze)
        guard let output=kernels.dehaze.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:dehazeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let sample=a.pointColor,sample.isActive {
        let (point,options)=Self.pointParameters(sample)
        var other = a
        other.pointColor = nil
        // Glow's compositing kernel applies tone after Glow. A Point Color-only layer can
        // also omit all four tonal vectors and preserve the original alpha and untouched RGB.
        let pointOnly = other.isNeutral || (a.glowAmount ?? 0) > 0
        let pointArgs = (pointOnly ? Array(args.prefix(6)) : args) + [point, options]
        let kernel = pointOnly ? kernels.pointColorOnly : kernels.pointColor
        guard let output=kernel.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:1),arguments:pointArgs)else{throw DevelopmentError.unreadable}
        image=output
        if let amount=a.glowAmount,amount>0 {
          var settings=sharedGlow ?? .init()
          settings.enabled=true;settings.amount=amount*100
          let glowed=try DevelopmentGlowEngineV3.apply(settings,to:image)
          var glowArgs=Array(args.prefix(10));glowArgs[0]=image;glowArgs.insert(glowed,at:1)
          guard let combined=kernels.glowLayer.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:glowArgs)else{throw DevelopmentError.unreadable}
          image=combined
        }
        // Without Glow, Point Color also applies tone in the same GPU pass.
        continue
      }
      if let amount=a.glowAmount,amount>0 {
        var settings=sharedGlow ?? .init()
        settings.enabled=true;settings.amount=amount*100
        let glowed=try DevelopmentGlowEngineV3.apply(settings,to:image)
        // The final kernel computes coverage from the pre-layer pixels, composites Glow, then
        // applies tone. No full-frame coverage texture or separate tonal pass is required.
        var glowArgs=args;glowArgs.insert(glowed,at:1)
        guard let output=kernels.glowLayer.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:glowArgs)else{throw DevelopmentError.unreadable}
        image=output
      }else{
        guard let output=kernels.layer.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:1),arguments:args)else{throw DevelopmentError.unreadable}
        image=output
      }
    }
    // Proxy inputs and parameters are validated and arithmetic is bounded; canonical retains this operator-level gate.
    if !deferValidation { try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation) }
    telemetryOutcome = .succeeded
    return image
  }
  private static let maskGeometryMetal = #"""
float rmMaskSmooth(float a,float b,float x){float t=clamp((x-a)/max(b-a,1e-5),0.0,1.0);return t*t*(3-2*t);}
float rmMaskCompute(float4 pixel,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float2 coord){
 float2 uv=float2(coord.x/range.z,1.0-coord.y/range.w);int kind=int(mode.x);float mask=0;
 if(kind==0){float2 a=line.xy,b=line.zw,d=b-a;float t=dot(uv-a,d)/max(dot(d,d),1e-6);mask=rmMaskSmooth(0.0,max(mode.w,0.001),t);}
 else if(kind==1){float d=length((uv-radial.xy)/radial.zw);mask=1.0-rmMaskSmooth(1.0-mode.w,1.0,d);}
 else if(kind==2){float3 c=clamp(pixel.rgb/pixel.a,0.0,1.0);float y=dot(c,float3(.2126,.7152,.0722));float f=max(mode.w*.5,.001);mask=rmMaskSmooth(range.x-f,range.x+f,y)*(1.0-rmMaskSmooth(range.y-f,range.y+f,y));}
 else{float4 s=subject.sample(subject.coord());mask=s.a>0?s.r/s.a:0;}
 mask=clamp(mask,0.0,1.0);if(mode.y>.5)mask=1.0-mask;return mask*mode.z;
}
"""#
  private static let grainTransferMetal = #"""
float rmMaskPointEncode(float x){float a=abs(x);return sign(x)*(a<=.0031308?12.92*a:1.055*pow(a,1.0/2.4)-.055);}
float rmMaskPointDecode(float x){float a=abs(x);return sign(x)*(a<=.04045?a/12.92:pow((a+.055)/1.055,2.4));}
float4 rmCompositeGrain(float4 pixel,float noise,float mask,float amount){
 if(mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a,e=float3(rmMaskPointEncode(c.r),rmMaskPointEncode(c.g),rmMaskPointEncode(c.b));
 float level=clamp(rmMaskPointEncode(dot(c,float3(.2126,.7152,.0722))),0.0,1.0);
 e+=noise*(.06*amount*mask)*(.35+sqrt(level));
 return float4(float3(rmMaskPointDecode(e.r),rmMaskPointDecode(e.g),rmMaskPointDecode(e.b))*pixel.a,pixel.a);
}
"""#

  private static let analyticalGrain:Result<CIKernel,Error> = Result {
    let source = #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    \#(maskGeometryMetal)
    \#(grainTransferMetal)
    \#(DevelopmentGrainSamplingEngineV1.colorGrainLattice)
    [[stitchable]] float4 rmAnalyticalMaskGrain(sampler src,float4 mode,float4 line,float4 radial,float4 range,float4 settings,destination dest){
      float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
      if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
      float mask=rmMaskCompute(pixel,src,mode,line,radial,range,at);
      return rmCompositeGrain(pixel,rmSourceGrainSample(at,settings),mask,settings.x);
    }
    } }
    """#
    guard let kernel=try CIKernel.kernels(withMetalString:source).first(where:{$0.name == "rmAnalyticalMaskGrain"}) else {throw DevelopmentError.unsupportedEngine}
    return kernel
  }
  static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
\#(maskGeometryMetal)
[[stitchable]] float4 rmMaskScopeCoverage(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,destination dest){
 float4 pixel=src.sample(src.coord());
 if(!all(isfinite(pixel))||pixel.a<=0)return float4(0.0);
 return float4(rmMaskCompute(pixel,subject,mode,line,radial,range,dest.coord()));
}
[[stitchable]] float4 rmMaskComposite(sampler src,sampler adjusted,sampler subject,float4 mode,float4 line,float4 radial,float4 range,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 changed=adjusted.sample(adjusted.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(changed))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 return float4(mix(pixel.rgb,changed.rgb,mask),pixel.a);
}
\#(grainTransferMetal)
[[stitchable]] float4 rmMaskGrain(sampler src,sampler noise,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float amount,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 sample=noise.sample(noise.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(sample))||pixel.a<=0)return pixel;
 return rmCompositeGrain(pixel,sample.r,rmMaskCompute(pixel,subject,mode,line,radial,range,at),amount);
}
\#(DevelopmentGrainSamplingEngineV1.colorGrainLattice)
[[stitchable]] float4 rmSourceMaskGrain(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float4 settings,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
 return rmCompositeGrain(pixel,rmSourceGrainSample(at,settings),rmMaskCompute(pixel,subject,mode,line,radial,range,at),settings.x);
}
[[stitchable]] float4 rmMaskMoire(sampler src,sampler blurred,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float amount,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 smooth=blurred.sample(blurred.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(smooth))||pixel.a<=0||smooth.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);if(mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a,b=smooth.rgb/smooth.a;
 float y=dot(c,float3(.2126,.7152,.0722)),by=dot(b,float3(.2126,.7152,.0722));
 float3 target=float3(y)+b-float3(by);c=mix(c,target,clamp(amount*mask,0.0,1.0));
 return float4(c*pixel.a,pixel.a);
}
[[stitchable]] float4 rmMaskDehaze(sampler src,sampler air,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float amount,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));float4 airlight=air.sample(air.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(airlight))||pixel.a<=0||airlight.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);if(mask<=0)return pixel;
 float3 u=pixel.rgb/pixel.a,a=airlight.rgb/airlight.a;
 float dark=clamp(1.0-dot(a,float3(.2126,.7152,.0722)),0.0,1.0),v=amount*mask;
 float3 j;if(v>=0){float t=clamp(1.0-.85*v*dark,.20,1.0);j=(u-a)/t+a;}
 else{float t=1.0/(1.0+.85*(-v)*dark);j=t*u+(1.0-t)*a;}
 return float4(j*pixel.a,pixel.a);
}
float3 rmMaskPointHSV(float3 c);
float3 rmMaskPointRGB(float3 hsv);
float4 rmMaskTone(float4 pixel,float mask,float4 adjustment,float4 tone,float4 color,float4 colorize){
 if(!all(isfinite(pixel))||pixel.a<=0||mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a;c*=exp2(2.0*adjustment.x*mask);
 float y=dot(c,float3(.2126,.7152,.0722));float encoded=clamp(rmMaskPointEncode(y),0.0,1.0);
 c*=1.0+.5*adjustment.y*rmMaskSmooth(.5,1.0,encoded)*mask;
 c*=1.0+.5*adjustment.z*(1.0-rmMaskSmooth(0.0,.5,encoded))*mask;
 y=dot(c,float3(.2126,.7152,.0722));encoded=rmMaskPointEncode(y);float contrast=tone.x*mask;
 if(encoded>0&&encoded<1&&contrast!=0){
  float pivot=.55,power=exp2(1.3*contrast);
  float target=encoded<pivot?pivot*pow(encoded/pivot,power):1.0-(1.0-pivot)*pow((1.0-encoded)/(1.0-pivot),power);
  float decoded=rmMaskPointDecode(target);c=abs(y)>1e-8?c*(decoded/y):c+float3(decoded-y);
 }
 float black=.05*tone.z*mask;c=(c-float3(black))/(1.0-black);
 float whiteWeight=smoothstep(.45,1.0,clamp(rmMaskPointEncode(dot(c,float3(.2126,.7152,.0722))),0.0,1.0));
 c*=1.0+.35*tone.y*whiteWeight*mask;
 float hue=color.x*color.y*mask;
 if(hue!=0){
  float3 e=float3(rmMaskPointEncode(c.r),rmMaskPointEncode(c.g),rmMaskPointEncode(c.b)),hsv=rmMaskPointHSV(e);
  hsv.x=fract(hsv.x+hue+1.0);float3 shifted=rmMaskPointRGB(hsv);
  c=float3(rmMaskPointDecode(shifted.r),rmMaskPointDecode(shifted.g),rmMaskPointDecode(shifted.b));
 }
 if(colorize.w>0&&color.z>0){
  float level=clamp(dot(c,float3(.2126,.7152,.0722)),0.0,1.0);
  c=mix(c,colorize.rgb*level,clamp(color.z*colorize.w*mask,0.0,1.0));
 }
 float gray=dot(c,float3(.2126,.7152,.0722));c=float3(gray)+(c-float3(gray))*(1.0+adjustment.w*mask);
 return float4(c*pixel.a,pixel.a);
}
[[stitchable]] float4 rmMaskLayerV7(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float4 adjustment,float4 tone,float4 color,float4 colorize,destination dest){
 float4 pixel=src.sample(src.coord());float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,dest.coord());
 return rmMaskTone(pixel,mask,adjustment,tone,color,colorize);
}
float3 rmMaskPointHSV(float3 c){float hi=max(c.r,max(c.g,c.b)),lo=min(c.r,min(c.g,c.b)),d=hi-lo,h=0;
 if(d>1e-8){if(hi==c.r)h=(c.g-c.b)/d;else if(hi==c.g)h=2.0+(c.b-c.r)/d;else h=4.0+(c.r-c.g)/d;}
 h=h/6.0-floor(h/6.0);return float3(h,hi>1e-8?d/hi:0,hi);}
float3 rmMaskPointRGB(float3 hsv){float3 p=abs(fract(hsv.xxx+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0);
 return hsv.z*mix(float3(1),clamp(p-1.0,0.0,1.0),hsv.y);}
float4 rmMaskPointColorPixel(float4 pixel,float mask,float4 point,float4 options){
 if(!all(isfinite(pixel))||pixel.a<=0||mask<=0)return pixel;
 float3 c=pixel.rgb/pixel.a,e=float3(rmMaskPointEncode(c.r),rmMaskPointEncode(c.g),rmMaskPointEncode(c.b));
 float3 hsv=rmMaskPointHSV(e);float d=abs(hsv.x-point.x);d=min(d,1.0-d);
 float w=mask*(1.0-smoothstep(max(.005,.2*options.x)*.3,max(.005,.2*options.x),d))*smoothstep(.015,.12,hsv.y);
 if(w>0){
  float hd=point.x-hsv.x;hd-=floor(hd+.5);float variance=options.y;
  hsv.x=fract(hsv.x+w*point.y+.5*w*variance*hd+1.0);
  hsv.y=max(0.0,hsv.y*(1.0+w*point.z)+.5*w*variance*(options.z-hsv.y));
  hsv.z+=.5*w*variance*(options.w-hsv.z);
  float3 out=rmMaskPointRGB(hsv);float y=dot(out,float3(.2126,.7152,.0722)),u=clamp(y,0.0,1.0);
  out+=point.w*w*.35*4*u*(1-u);
  pixel=float4(float3(rmMaskPointDecode(out.r),rmMaskPointDecode(out.g),rmMaskPointDecode(out.b))*pixel.a,pixel.a);
 }
 return pixel;
}
[[stitchable]] float4 rmMaskPointColorOnly(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,
 float4 point,float4 options,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 return rmMaskPointColorPixel(pixel,mask,point,options);
}
[[stitchable]] float4 rmMaskPointColorV7(sampler src,sampler subject,float4 mode,float4 line,float4 radial,float4 range,
 float4 adjustment,float4 tone,float4 color,float4 colorize,float4 point,float4 options,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 if(!all(isfinite(pixel))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 return rmMaskTone(rmMaskPointColorPixel(pixel,mask,point,options),mask,adjustment,tone,color,colorize);
}
[[stitchable]] float4 rmMaskGlowLayerV7(sampler src,sampler glow,sampler subject,float4 mode,float4 line,float4 radial,float4 range,float4 adjustment,float4 tone,float4 color,float4 colorize,destination dest){
 float2 at=dest.coord();float4 pixel=src.sample(src.transform(at));
 float4 lighted=glow.sample(glow.transform(at));
 if(!all(isfinite(pixel))||!all(isfinite(lighted))||pixel.a<=0)return pixel;
 float mask=rmMaskCompute(pixel,subject,mode,line,radial,range,at);
 float4 composited=float4(mix(pixel.rgb,lighted.rgb,mask),pixel.a);
 return rmMaskTone(composited,mask,adjustment,tone,color,colorize);
}
} }
"""#
}
