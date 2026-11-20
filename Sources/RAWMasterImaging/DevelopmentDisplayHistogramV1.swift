import Foundation
import CoreImage
import RAWMasterCore

/// Sampled display luminance only. This DTO cannot supply RGB/scalars to automatic adjustments.
public struct DevelopmentDisplayHistogramV1: Equatable, Sendable {
  public static let samplingVersion = "display-tile16-v1"
  public let luminance:[UInt64]
  public let visibleSamples,transparentSamples:Int
  public let sampledSize:DevelopmentPixelSize
  public init(luminance:[UInt64],visibleSamples:Int,transparentSamples:Int,sampledSize:DevelopmentPixelSize) {
    self.luminance=luminance;self.visibleSamples=visibleSamples;self.transparentSamples=transparentSamples;self.sampledSize=sampledSize
  }
  func validate()throws {
    guard (1...128).contains(sampledSize.width),(1...128).contains(sampledSize.height),luminance.count==256,
      visibleSamples>=0,transparentSamples>=0,visibleSamples<=16384,transparentSamples<=16384,
      visibleSamples+transparentSamples==sampledSize.width*sampledSize.height,
      luminance.allSatisfy({$0<=UInt64(visibleSamples)}),luminance.reduce(0,+)==UInt64(visibleSamples) else {throw DevelopmentPreviewError.invalidRequest}
  }
}

/// Separate versioned display contract. Old exact histogram/scalar cache and operators are untouched.
enum DevelopmentDisplayHistogramEngineV1 {
  static let version=DevelopmentDisplayHistogramV1.samplingVersion
  struct CacheKey:Equatable {
    let source:DevelopmentLocalEditSourceBinding
    let generation:UInt64
    let recipeFingerprint:String
    let stage:DevelopmentAnalysisStage
    let roi:NormalizedCrop
    let filterIdentity:String?
    let samplingVersion:String
  }
  struct CacheEntry:Equatable {let key:CacheKey;let value:DevelopmentDisplayHistogramV1}
  struct ProxyPixels {let rgba:[Float];let width,height:Int}
  static func check(_ cancellation:DevelopmentAnalysisCancellation?)throws {
    try Task.checkCancellation();try cancellation?.check()
  }
  /// Same global128 proxy geometry, explicitly versioned tiled output semantics.
  /// The padded backing satisfies CIContext's rowBytes*height requirement for column-offset pointers.
  static func renderProxy(_ image:CIImage,roi:NormalizedCrop,context:CIContext,
                          checkCancellation:()throws->Void = {})throws->ProxyPixels {
    let e=image.extent
    guard !e.isEmpty,!e.isInfinite,e.minX.isFinite,e.minY.isFinite,e.width.isFinite,e.height.isFinite,
      [roi.x,roi.y,roi.width,roi.height].allSatisfy(\.isFinite),roi.x>=0,roi.y>=0,roi.width>0,roi.height>0,
      roi.x+roi.width<=1,roi.y+roi.height<=1 else {throw DevelopmentPreviewError.invalidRequest}
    let rect=CGRect(x:e.minX+e.width*roi.x,y:e.minY+e.height*(1-roi.y-roi.height),width:e.width*roi.width,height:e.height*roi.height)
    let factor=min(1,Double(128)/max(rect.width,rect.height))
    let width=max(1,Int(floor(rect.width*factor))),height=max(1,Int(floor(rect.height*factor)))
    let proxy=image.cropped(to:rect).transformed(by:.init(translationX:-rect.minX,y:-rect.minY)).transformed(by:.init(scaleX:Double(width)/rect.width,y:Double(height)/rect.height))
    // A void render must overwrite every logical component; unwritten pixels cannot become black.
    var pixels=[Float](repeating:Float(bitPattern:0x7fc00000),count:width*height*4)
    pixels.append(contentsOf:repeatElement(Float(0),count:width*4))
    try pixels.withUnsafeMutableBytes { bytes in
      for y in stride(from:0,to:height,by:16) {for x in stride(from:0,to:width,by:16) {
        try Task.checkCancellation();try checkCancellation()
        let w=min(16,width-x),h=min(16,height-y)
        let destinationRow=height-y-h
        autoreleasepool {
          context.render(proxy,toBitmap:bytes.baseAddress!.advanced(by:(destinationRow*width+x)*16),rowBytes:width*16,
            bounds:.init(x:x,y:y,width:w,height:h),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
          context.clearCaches()
        }
        // No cancellation may release the native slot before the synchronous tile has joined.
        try Task.checkCancellation();try checkCancellation()
      }}
    }
    pixels.removeLast(width*4)
    guard pixels.allSatisfy(\.isFinite)else{throw DevelopmentError.invalidEncoding}
    return .init(rgba:pixels,width:width,height:height)
  }
  static func histogram(_ pixels:ProxyPixels)throws->DevelopmentDisplayHistogramV1 {
    guard (1...128).contains(pixels.width),(1...128).contains(pixels.height),pixels.rgba.count==pixels.width*pixels.height*4 else {throw DevelopmentPreviewError.invalidRequest}
    var bins=[UInt64](repeating:0,count:256),visible=0,transparent=0
    for i in 0..<(pixels.width*pixels.height) {
      let n=i*4;guard (0..<4).allSatisfy({pixels.rgba[n+$0].isFinite})else{throw DevelopmentError.invalidEncoding}
      let alpha=Double(pixels.rgba[n+3]);if alpha<=0{transparent+=1;continue}
      let c=SIMD3(Double(pixels.rgba[n]),Double(pixels.rgba[n+1]),Double(pixels.rgba[n+2]))/alpha
      let y=DevelopmentColorEngineV2.encode(DevelopmentColorEngineV2.luma(c))
      bins[Int((min(1,max(0,y))*255).rounded(.down))]+=1;visible+=1
    }
    let value=DevelopmentDisplayHistogramV1(luminance:bins,visibleSamples:visible,transparentSamples:transparent,sampledSize:.init(width:pixels.width,height:pixels.height))
    try value.validate();return value
  }
  static func run(capture:URL,request:DevelopmentAnalysisRequest,sourceBinding:DevelopmentLocalEditSourceBinding,memoryHint:Int,
                  cache:inout CacheEntry?,cancellation:DevelopmentAnalysisCancellation?=nil,sourceAuthority:()throws->Void)throws->DevelopmentAnalysisResult {
    guard request.operation.isDisplayHistogram else{throw DevelopmentPreviewError.invalidRequest}
    try request.validate();try sourceBinding.validate();try check(cancellation);try sourceAuthority()
    let isRAW=PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased())
    if request.preview.recipe.schemaVersion==3 {try DevelopmentRendererV3.validateSupport(try DevelopmentAnalysisEngine.samplingSupportRecipe(request),sourceIsRAW:isRAW)}
    let sampling=try DevelopmentAnalysisEngine.samplingRecipe(request),fingerprint=try EditingFingerprint.of(sampling)
    let filterIdentity=try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(sampling)
    let samplingVersion=try DevelopmentAnalysisEngine.validatedSamplingVersion(request)
    let key=CacheKey(source:sourceBinding,generation:request.preview.sourceGeneration,recipeFingerprint:fingerprint,stage:request.stage,roi:request.roi,filterIdentity:filterIdentity,samplingVersion:samplingVersion)
    let value:DevelopmentDisplayHistogramV1
    if let entry=cache,entry.key==key {try entry.value.validate();value=entry.value}
    else {
      let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryHint])
      defer{context.clearCaches()}
      let graph=try DevelopmentRendererV3.develop(capture,recipe:sampling,applyGeometry:false,context:context,checkCancellation:{try check(cancellation)})
      let pixels=try renderProxy(graph.image,roi:request.roi,context:context,checkCancellation:{try check(cancellation)})
      value=try histogram(pixels)
      try check(cancellation);try sourceAuthority();try check(cancellation)
      cache = .init(key:key,value:value)
    }
    try check(cancellation);try sourceAuthority();try check(cancellation)
    let binding=DevelopmentAnalysisBinding(sourceContentID:sourceBinding.sourceContentID,sourceGeneration:request.preview.sourceGeneration,expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:request.stage)
    let geometry=request.preview.recipe.adjustmentsV3?.geometry ?? DevelopmentGeometryV3(version:request.preview.recipe.schemaVersion==2 ? .legacyV2:.legacyV1,straightenDegrees:request.preview.recipe.straightenDegrees,crop:request.preview.recipe.crop)
    return .init(operationID:request.operationID,sessionID:request.preview.sessionID,consumerID:request.preview.consumerID,revision:request.preview.revision,role:request.preview.role,quality:request.preview.quality,actualRecipe:request.preview.recipe,clientCorrelation:request.preview.clientCorrelation,binding:binding,sourceBinding:sourceBinding,presentedRecipeFingerprint:request.presentedRecipeFingerprint,roi:request.roi,samplingRecipeFingerprint:fingerprint,samplingVersion:samplingVersion,geometryMapping:try geometry.mapping(sourceSize:sourceBinding.sourceSize),value:.displayHistogram(value))
  }
}
