import AppKit
import CoreImage
import RAWMasterCore

/// Preview-only nonneutral v2 RAW path. Canonical services never call this entry point.
enum PreviewRawBaseRenderer {
  static let nativeContract = "fresh-canonical-RAW-v2/scale1/draftfalse/linear-F32-premul/v1"
  private static func descriptor(capture: URL, sourceKey: String, recipe: DevelopmentRecipe) throws -> RawBaseDescriptor {
    try autoreleasepool {
      guard let raw = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
      raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = Float(recipe.exposureEV)
      let mode: String
      switch recipe.whiteBalance {
      case .asShot: mode = "asShot" // Intentionally do not restore/set native WB.
      case let .temperatureTint(t,v): mode = "temperatureTint"; raw.neutralTemperature = Float(t); raw.neutralTint = Float(v)
      }
      guard let native = raw.outputImage, native.extent.minX == 0, native.extent.minY == 0,
        native.extent == native.extent.integral, native.extent.width > 0, native.extent.height > 0,
        native.extent.width < 50000, native.extent.height < 50000 else { throw RawBaseCacheError.ineligible }
      return RawBaseDescriptor(sourceKey:sourceKey,decoder:raw.decoderVersion.rawValue,
        nativeContract:nativeContract,
        exposureBits:Float(recipe.exposureEV).bitPattern,whiteBalanceMode:mode,
        temperatureBits:raw.neutralTemperature.bitPattern,tintBits:raw.neutralTint.bitPattern,
        orientation:raw.orientation.rawValue,width:Int(native.extent.width),height:Int(native.extent.height))
    }
  }
  static func render(capture: URL, sourceKey: String, recipe: DevelopmentRecipe, maxPixel: Int,
                     pool: PreviewRawBasePool, memoryHint: Int, captureStamp: PreviewFileStamp, decoderIdentity: String) throws -> PreviewPixels? {
    try cacheAttempt { try renderEligible(capture:capture,sourceKey:sourceKey,recipe:recipe,maxPixel:maxPixel,pool:pool,memoryHint:memoryHint,captureStamp:captureStamp,decoderIdentity:decoderIdentity) }
  }
  static func cacheAttempt<T>(_ attempt: () throws -> T) throws -> T? {
    do { return try attempt() }
    catch RawBaseCacheError.ineligible { return nil }
    catch RawBaseCacheError.unavailable { return nil }
    catch RawBaseCacheError.capacity { return nil }
    // In-flight/checkpoint failures propagate; they MUST NOT trigger a second RAW render.
  }
  /// The factory seam verifies that a warm resident hit never opens RAW metadata.
  static func resolvePin(pool: PreviewRawBasePool, request: RawBaseResidentRequestKey, maxPixel: Int,
                         descriptor: () throws -> RawBaseDescriptor,
                         fill: (RawBaseDescriptor, RawBaseStorage) throws -> Void) throws -> RawBasePin {
    if maxPixel > 0, let resident = pool.acquireResident(request) { return resident }
    let actual = try descriptor()
    if maxPixel == 0 { pool.evictUnpinned(except:actual) }
    return try pool.acquire(actual,verifiedRequest:request) { try fill(actual,$0) }
  }
  private static func renderEligible(capture: URL, sourceKey: String, recipe: DevelopmentRecipe, maxPixel: Int,
                     pool: PreviewRawBasePool, memoryHint: Int, captureStamp: PreviewFileStamp, decoderIdentity: String) throws -> PreviewPixels {
    let request = RawBaseResidentRequestKey(sourceKey:sourceKey,captureStamp:captureStamp,decoderIdentity:decoderIdentity,nativeContract:nativeContract,recipe:recipe)
    let pin = try resolvePin(pool:pool,request:request,maxPixel:maxPixel,descriptor:{ try descriptor(capture:capture,sourceKey:sourceKey,recipe:recipe) }) { descriptor, storage in
      try autoreleasepool {
        guard let raw = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
        raw.scaleFactor = 1; raw.isDraftModeEnabled = false; raw.exposure = Float(recipe.exposureEV)
        if case let .temperatureTint(t,v) = recipe.whiteBalance { raw.neutralTemperature = Float(t); raw.neutralTint = Float(v) }
        guard raw.decoderVersion.rawValue == descriptor.decoder, raw.orientation.rawValue == descriptor.orientation,
          raw.neutralTemperature.bitPattern == descriptor.temperatureBits,
          raw.neutralTint.bitPattern == descriptor.tintBits, let image = raw.outputImage else { throw DevelopmentPreviewError.sourceInvalidated }
        let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,
          .workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:memoryHint])
        defer { context.clearCaches() }
        try storage.fill(image,context:context,mode:pool.nativeFillMode,checkpoint:pool.checkpoint) // actual task.wait + no-copy finite scan
      }
    }
    defer {
      pin.releaseAfterJoinedPipeline()
      if maxPixel == 0 { pool.retire(sourceKey:sourceKey) }
    }
    try pool.checkpoint("base-pinned-fill-context-dropped")
    // The autoreleasepool drains all graph/context views BEFORE the pin is released/accounted.
    return try autoreleasepool {
      let context = CIContext(options:[.cacheIntermediates:false,.workingColorSpace:DevelopmentColorEngineV2.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue,.memoryTarget:memoryHint])
      defer { context.clearCaches() }
      guard let color = recipe.color, !color.isNeutral else { throw DevelopmentPreviewError.invalidRequest }
      var image = try DevelopmentColorEngineV2.apply(color,to:pin.image)
      try pool.checkpoint("before-color-finite")
      try DevelopmentColorEngineV2.validateFinite(image,context:context)
      try pool.checkpoint("color-finite-joined")
      image = try PhotoRenderer.applyV2Geometry(image,recipe)
      let canonicalSize = image.extent.size
      let limit = maxPixel <= 0 ? max(image.extent.width,image.extent.height):CGFloat(max(64,min(4096,maxPixel)))
      let factor = min(1,limit/max(image.extent.width,image.extent.height))
      if factor < 1 { image = image.transformed(by:.init(scaleX:factor,y:factor)) }
      try pool.checkpoint("before-final-display-readback")
      guard let cg = context.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:PhotoRenderer.sRGB,deferred:false),
        let owned = CGContext(data:nil,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
          space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw DevelopmentError.unreadable }
      try pool.checkpoint("display-readback-joined")
      owned.setBlendMode(.copy); owned.interpolationQuality = .none
      owned.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
      guard let compact = owned.makeImage() else { throw DevelopmentError.unreadable }
      let bitmap = NSBitmapImageRep(cgImage:compact), result = NSImage(size:CGSize(width:cg.width,height:cg.height))
      result.addRepresentation(bitmap)
      try pool.checkpoint("owned-display-complete")
      return PreviewPixels(image:result,nativeSize:canonicalSize,outputSize:CGSize(width:cg.width,height:cg.height),bytes:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
  }
  static func v3CacheEligible(_ recipe: DevelopmentRecipe, sourceIsRAW: Bool) -> Bool {
    guard sourceIsRAW, recipe.schemaVersion == 3, let payload = recipe.adjustmentsV3, payload.aiDenoise == nil,
      (try? DevelopmentRendererV3.validateSupport(recipe,sourceIsRAW:true)) != nil else { return false }
    if DevelopmentBrillianceAdaptiveV1.isActive(payload.light) { return false }
    if DevelopmentRendererV3.hasNewEffects(payload) { return true }
    return payload.legacyBasis?.version == .v2 && payload.legacyBasis?.color?.isNeutral == false
  }
  static func renderV3(capture: URL, sourceKey: String, recipe: DevelopmentRecipe, maxPixel: Int,
                       pool: PreviewRawBasePool, memoryHint: Int, captureStamp: PreviewFileStamp,
                       decoderIdentity: String, decoderDefaultsFingerprint: String,
                       noiseDefaults: DevelopmentRAWNoiseReductionDefaultsV3,
                       thumbnailNativeSink: ((CIImage) throws -> Void)? = nil,
                       grainFinalTransport: PreviewGrainFinalTransportV1.Request? = nil) throws -> PreviewPixels? {
    try cacheAttempt {
      try DevelopmentRendererV3.validateSupport(recipe,sourceIsRAW:true)
      guard recipe.adjustmentsV3?.aiDenoise == nil else { throw RawBaseCacheError.ineligible }
      if DevelopmentBrillianceAdaptiveV1.isActive(recipe.adjustmentsV3!.light) {
        // This worker already serializes native renders. The adaptive operator has its own
        // bounded native transport; retaining a whole RGBAf base here duplicates its input.
        // Retire only idle cache owners, then use the existing canonical source/decoder path.
        pool.evictUnpinned()
        throw RawBaseCacheError.ineligible
      }
      let parameters = try DevelopmentRendererV3.NativeParameters(recipe.adjustmentsV3!,noiseDefaults:noiseDefaults,originalDefaultsFingerprint:decoderDefaultsFingerprint)
      let effectiveFingerprint = try parameters.effectiveFingerprint(original:decoderDefaultsFingerprint)
      let request = RawBaseResidentRequestKey(sourceKey:sourceKey,captureStamp:captureStamp,decoderIdentity:decoderIdentity,
        nativeContract:DevelopmentRendererV3.nativeContract,exposureBits:parameters.exposure.bitPattern,
        whiteBalance:parameters.whiteBalanceRequest,nativeParameterFingerprint:effectiveFingerprint)
      let pin = try resolvePin(pool:pool,request:request,maxPixel:maxPixel,descriptor:{
        guard let raw = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
        try DevelopmentRendererV3.configure(raw,parameters:parameters)
        guard let native = raw.outputImage, native.extent.minX == 0, native.extent.minY == 0,
          native.extent == native.extent.integral, native.extent.width > 0, native.extent.height > 0,
          native.extent.width < 50000, native.extent.height < 50000 else { throw RawBaseCacheError.ineligible }
        return RawBaseDescriptor(sourceKey:sourceKey,decoder:raw.decoderVersion.rawValue,nativeContract:DevelopmentRendererV3.nativeContract,
          exposureBits:raw.exposure.bitPattern,whiteBalanceMode:parameters.whiteBalance == .asShot ? "asShot":"temperatureTint",
          temperatureBits:raw.neutralTemperature.bitPattern,tintBits:raw.neutralTint.bitPattern,
          orientation:raw.orientation.rawValue,width:Int(native.extent.width),height:Int(native.extent.height),nativeParameterFingerprint:effectiveFingerprint)
      }) { descriptor,storage in
        try autoreleasepool {
          guard let raw = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
          try DevelopmentRendererV3.configure(raw,parameters:parameters)
          guard let image = raw.outputImage, raw.decoderVersion.rawValue == descriptor.decoder,
            raw.exposure.bitPattern == descriptor.exposureBits, raw.orientation.rawValue == descriptor.orientation,
            raw.neutralTemperature.bitPattern == descriptor.temperatureBits, raw.neutralTint.bitPattern == descriptor.tintBits,
            effectiveFingerprint == descriptor.nativeParameterFingerprint else { throw DevelopmentPreviewError.sourceInvalidated }
          let context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryHint])
          defer { context.clearCaches() }
          try storage.fill(image,context:context,mode:pool.nativeFillMode,checkpoint:pool.checkpoint)
        }
      }
      defer { pin.releaseAfterJoinedPipeline(); if maxPixel == 0 { pool.retire(sourceKey:sourceKey) } }
      return try autoreleasepool {
        let context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryHint])
        defer { context.clearCaches() }
        try pool.checkpoint("v3-base-pinned")
        let graph = try DevelopmentRendererV3.develop(capture,recipe:recipe,suppliedRawBase:pin.image,context:context,thumbnailNativeSink:thumbnailNativeSink)
        try pool.checkpoint("v3-finite-joined")
        let result = try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:maxPixel,grainFinalTransport:grainFinalTransport)
        try pool.checkpoint("v3-owned-display-joined")
        return result
      }
    }
  }

}

