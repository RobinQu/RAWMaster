import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// RAWMaster's versioned adaptive Brilliance. Canonical rendering derives its map and guide
/// from one full native prefix; the explicitly approximate interactive proxy uses its own
/// bounded prefix. The existing opaque SDR +0.5 Photos comparison does not qualify RAW or combined edits.
enum DevelopmentBrillianceAdaptiveV1 {
  static let version = "rawmaster-adaptive-brilliance-v1/native-prefix-map31/straight-linear-rgb"
  /// Only immutable 31x31 maps are shared. The caller's key binds source, proxy and every
  /// upstream parameter; settled/save/export do not supply a key and retain canonical evaluation.
  private static let interactiveMaps:NSCache<NSString,MapRows> = {
    let cache=NSCache<NSString,MapRows>();cache.countLimit=4;return cache
  }()
  static func makeContext()->CIContext {
    CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
      .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
  }
  /// Each complete finite scan joins its native tasks before the short context leaves this
  /// pool. The caller retains only its unchanged CIImage graph, never this validation owner.
  static func withOwnedFiniteValidationContext(sourceIsRAW:Bool,_ body:(CIContext)throws->Void)throws {
    weak var witness:CIContext?
    let outcome:Result<Void,Error> = autoreleasepool {
      // A real RAW finite tile required 616,714,240 bytes on the measured source.
      // Keep this budget local to validation; map and final output retain their old targets.
      let owned=sourceIsRAW ? CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:768]):makeContext()
      witness=owned
      defer{owned.clearCaches()}
      return Result{try body(owned)}
    }
    guard witness == nil else {
      // Keep the native/cancellation error as the primary failure after leaving the pool.
      if case .failure(let original)=outcome {throw original}
      throw PreviewPresentationError.allocationProtocol
    }
    try outcome.get()
  }
  /// Full native finite-mask readback replaces only the reduction transport for this
  /// adaptive operator. The original mask shader and acceptance rule are unchanged.
  static let maximumMaskBandWidth=16_384 // At most4MiB of NaN-initialized Rf storage.
  static func supportsFiniteMaskBands(_ extent:CGRect)->Bool {
    DevelopmentCheckedMaximumV3.isIntegralDomain(extent) &&
      extent.width <= CGFloat(maximumMaskBandWidth) &&
      extent.height <= CGFloat(DevelopmentLocalEditLimits.maximumSourceDimension)
  }
  static func validateFinite(_ image:CIImage,context:CIContext,
    checkCancellation:(()throws->Void)?=nil,
    observeBandForTesting:((CGRect,Int)throws->Void)?=nil)throws {
    let extent=image.extent
    guard supportsFiniteMaskBands(extent) else {
      try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:checkCancellation)
      return
    }
    let mask=try DevelopmentColorEngineV2.finiteMaskForV3(image)
    let width=Int(extent.width),height=Int(extent.height)
    let diagnostic=ProcessInfo.processInfo.environment["RAWMASTER_MAXIMUM_QA_SCALARS"] == "1"
    let id=diagnostic ? UUID().uuidString:""
    var completedRows=0,currentRow=0
    func trace(_ phase:String) {
      guard diagnostic else{return}
      let record:[String:Any]=["tag":"rawmaster-adaptive-finite-mask64","phase":phase,"validationID":id,
        "width":width,"height":height,"completedRows":completedRows,"currentRow":currentRow,
        "uptimeNanoseconds":DispatchTime.now().uptimeNanoseconds]
      guard var data=try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]) else{return}
      data.append(0x0a);try? FileHandle.standardError.write(contentsOf:data)
    }
    trace("begin")
    do {
      for row in stride(from:0,to:height,by:64) {
        currentRow=row
        let rows=min(64,height-row),rect=CGRect(x:extent.minX,y:extent.minY+CGFloat(row),width:extent.width,height:CGFloat(rows))
        do {
          // The native task and borrowed mask buffer have left their short pool before
          // cache release, also for start/wait/cancellation/malformed-mask failures.
          defer{context.clearCaches()}
          try autoreleasepool {
            try checkedFiniteMaskBand(width:width,rows:rows,checkCancellation:checkCancellation){pointer in
              let destination=CIRenderDestination(bitmapData:pointer,width:width,height:rows,bytesPerRow:width*4,format:.Rf)
              destination.colorSpace=nil;destination.alphaMode = .none // Raw R mask data; no RGB-to-gray conversion.
              destination.isClamped=false;destination.isDithered=false;destination.isFlipped=true
              let task=try context.startTask(toRender:mask,from:rect,to:destination,at:.zero)
              do{_ = try task.waitUntilCompleted()}
              catch{let primary=error;_ = try? task.waitUntilCompleted();throw primary}
            }
            try observeBandForTesting?(rect,width*rows)
          }
        }
        completedRows += rows
      }
      trace("success")
    }catch{trace("failure");throw error}
  }
  /// The writer must join before returning or throwing. Poison initialization proves
  /// that every mask element was written, including the final partial band.
  static func checkedFiniteMaskBand(width:Int,rows:Int,checkCancellation:(()throws->Void)?=nil,
    writeAndJoin:(UnsafeMutableRawPointer)throws->Void)throws {
    guard width>0,width<=maximumMaskBandWidth,(1...64).contains(rows) else {
      throw DevelopmentV3Error.invalidGraph
    }
    try Task.checkCancellation();try checkCancellation?()
    var values=[Float](repeating:.nan,count:width*rows)
    try values.withUnsafeMutableBytes{try writeAndJoin($0.baseAddress!)}
    try Task.checkCancellation();try checkCancellation?()
    guard values.allSatisfy({$0.isFinite && $0<0.5}) else{throw DevelopmentError.invalidEncoding}
  }
  static func isActive(_ light:DevelopmentLightV3)->Bool {
    light.enabled && light.brillianceVersion == .adaptiveLocalV1 && light.brilliance != 0
  }
  static func nativeGraphSupported(_ extent:CGRect)->Bool {
    guard (try? BrilliancePlan(extent:extent)) != nil,
      extent.width <= CGFloat(DevelopmentLocalEditLimits.maximumSourceDimension),
      extent.height <= CGFloat(DevelopmentLocalEditLimits.maximumSourceDimension),
      let scale=try? BrillianceMapCPU.scale(width:Int(extent.width),height:Int(extent.height)) else {return false}
    let rowBytes=(scale.width*4+63) & ~63
    return (try? BrillianceMapCPU.layout(width:scale.width,height:scale.height,
      bytesPerRow:rowBytes,byteCount:rowBytes*scale.height)) != nil
  }
  static func mapWorkingBytes(_ extent:CGRect)->Int {
    guard nativeGraphSupported(extent),let scale=try? BrillianceMapCPU.scale(width:Int(extent.width),height:Int(extent.height)) else{return 0}
    // BGRA8 capture, the 1,922-byte map, counts/bins, and bounded small scalar storage.
    return ((scale.width*4+63) & ~63)*scale.height+16384
  }
  private struct AlphaKernels {let straight,restore:CIKernel}
  private static let alphaKernels:Result<AlphaKernels,Error> = Result {
    guard DevelopmentKernelCapability.supported else {throw DevelopmentError.unsupportedEngine}
    let kernels=try CIKernel.kernels(withMetalString:alphaSource)
    guard let straight=kernels.first(where:{$0.name=="rmBrillianceStraightV1"}),
      let restore=kernels.first(where:{$0.name=="rmBrillianceRestoreAlphaV1"}) else {throw DevelopmentError.unsupportedEngine}
    return .init(straight:straight,restore:restore)
  }
  static func apply(_ light:DevelopmentLightV3,to image:CIImage,sourceIsRAW:Bool=false,context:CIContext?=nil,
                    checkCancellation:(()throws->Void)?=nil,interactiveMapKey:String?=nil,interactiveProxy:Bool=false)throws->CIImage {
    try light.validate()
    // No map, kernel, context, or alpha normalization for zero/disabled/other versions.
    guard isActive(light) else {return image}
    let check:()throws->Void = {try Task.checkCancellation();try checkCancellation?()}
    try check()
    guard nativeGraphSupported(image.extent) else {
      // A tiny or very thin native source cannot support the recovered 31-cell/blur geometry.
      // This is a deterministic source-dimension fallback, never a viewport-dependent choice.
      var old=light;old.brillianceVersion=nil;old.shadows=0;old.highlights=0
      return try DevelopmentSpatialEngineV3.applyLight(old,to:image)
    }
    let profile = ProcessInfo.processInfo.environment["RAWMASTER_BRILLIANCE_PROFILE"] == "1"
    let start = DispatchTime.now().uptimeNanoseconds
    let kernels=try alphaKernels.get()
    guard let straight=kernels.straight.apply(extent:image.extent,roiCallback:{_,r in r},arguments:[image]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    let afterStraight = DispatchTime.now().uptimeNanoseconds
    let rows:MapRows
    if let interactiveMapKey,let cached=interactiveMaps.object(forKey:interactiveMapKey as NSString) {
      rows=cached
    } else {
      rows=try MapRows(makeMap(straight,check:check),width:31,height:31)
      if let interactiveMapKey{interactiveMaps.setObject(rows,forKey:interactiveMapKey as NSString)}
    }
    let afterMap = DispatchTime.now().uptimeNanoseconds
    let processed:CIImage
    if !interactiveProxy,let materialized=try DevelopmentBrillianceNativeRGV1.apply(straight,rows:rows,strength:light.brilliance,sourceIsRAW:sourceIsRAW,context:context,check:check) {
      processed=materialized
    } else if #available(macOS 26.0,*) {
      processed=try PublicBrilliance.graph(image:straight,provider:rows,local:light.brilliance,shadow:0,observeTiledJoint:{_ in})
    } else {
      processed=try PublicBrilliance.graph(image:straight,provider:rows,local:light.brilliance,shadow:0)
    }
    let afterNative = DispatchTime.now().uptimeNanoseconds
    guard let result=kernels.restore.apply(extent:image.extent,roiCallback:{_,r in r},arguments:[processed,image]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    try check()
    if profile {
      let ms: (UInt64) -> Double = { Double($0) / 1_000_000 }
      print("BRILLIANCE-STAGE straight=\(String(format:"%.1f",ms(afterStraight-start))) map=\(String(format:"%.1f",ms(afterMap-afterStraight))) native=\(String(format:"%.1f",ms(afterNative-afterMap))) restore=\(String(format:"%.1f",ms(DispatchTime.now().uptimeNanoseconds-afterNative)))")
    }
    return result
  }
  /// Bounded source-native statistics. The only CPU raster is a <=16 MiB proxy; the immutable
  /// map retained by the returned graph is 1,922 bytes. No full raster or context escapes here.
  private static func makeMap(_ image:CIImage,check:()throws->Void)throws->Data {
    let scale=try BrillianceMapCPU.scale(width:Int(image.extent.width),height:Int(image.extent.height))
    let rowBytes=(scale.width*4+63) & ~63
    _ = try BrillianceMapCPU.layout(width:scale.width,height:scale.height,bytesPerRow:rowBytes,byteCount:rowBytes*scale.height)
    return try autoreleasepool {
      var proxy=Data(count:rowBytes*scale.height)
      let space=DevelopmentColorEngineV3.linearSRGB
      let context=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf.rawValue,
        .cacheIntermediates:false,.highQualityDownsample:false,.memoryTarget:512])
      defer {context.clearCaches()}
      let extent=CGRect(x:0,y:0,width:scale.width,height:scale.height)
      let factor=CGFloat(scale.numerator)/CGFloat(scale.denominator)
      let sampled=image.clampedToExtent().samplingNearest().transformed(by:.init(scaleX:factor,y:factor),highQualityDownsample:true).cropped(to:extent)
      try check()
      try proxy.withUnsafeMutableBytes {bytes in
        let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:scale.width,height:scale.height,bytesPerRow:rowBytes,format:.BGRA8)
        destination.colorSpace=space;destination.alphaMode = .premultiplied
        destination.isClamped=true;destination.isDithered=false;destination.isFlipped=true
        let task=try context.startTask(toRender:sampled,from:extent,to:destination,at:.zero)
        do {_ = try task.waitUntilCompleted()}
        catch {let original=error;_ = try? task.waitUntilCompleted();throw original}
      }
      try check()
      return try BrillianceMapCPU.generate(proxy,width:scale.width,height:scale.height,bytesPerRow:rowBytes,check:check).bytes
    }
  }
  static let alphaSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmBrillianceStraightV1(sampler source) {
  float4 p=source.sample(source.coord());
  if(!all(isfinite(p))) return p;
  if(p.a<=0.0) return float4(0.0,0.0,0.0,1.0);
  return float4(p.rgb/p.a,1.0);
}
[[stitchable]] float4 rmBrillianceRestoreAlphaV1(sampler adjusted,sampler source) {
  float4 p=source.sample(source.coord());
  // Preserve invalid inputs so the unchanged canonical finite/alpha validator rejects them.
  // Alpha-zero pixels retain their original hidden RGB. For alpha>0, process straight RGB
  // and multiply by the original coverage, including negative/HDR parts restored by poly.
  if(!all(isfinite(p)) || p.a<=0.0) return p;
  float4 q=adjusted.sample(adjusted.coord());
  if(!all(isfinite(q))) return q;
  return float4(q.rgb*p.a,p.a);
}
} }
"""#
}
