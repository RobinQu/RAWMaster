import AppKit
import CoreImage
import ImageIO
import CryptoKit
import Metal
import Darwin
import RAWMasterCore

struct PreviewFileStamp: Hashable, Sendable {
  let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
  static func read(_ url: URL) throws -> Self {
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { throw DevelopmentPreviewError.sourceInvalidated }
    defer { Darwin.close(fd) }
    var value = stat()
    guard Darwin.fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw DevelopmentPreviewError.sourceInvalidated }
    return Self(device: value.st_dev, inode: value.st_ino, size: value.st_size,
      seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec,
      changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
  }
}
/// Private transport failure; Service maps this to sourceInvalidated after capture-scoped revocation.
struct PreviewCaptureFault: Error, Sendable {
  let captureID: UUID
}
struct PreviewPixels: @unchecked Sendable {
  let image: NSImage
  let nativeSize: CGSize
  let outputSize: CGSize
  let bytes: Int
  let approximation:PreviewApproximationInfo?
  let interactiveCanonicalFallbackReason:String?
  let nativePointwise:PreviewNativePointwiseReceiptV1?
  let actualGrainFinalTransport:String?
  let brilliancePublicObservation:DevelopmentBrilliancePublicV1.Observation?
  let dehazeTIFFObservation:DevelopmentDehazeTIFFPreviewV1.Observation?
  let presentationTicket:PreviewPresentationReservation?
  var managedPresentation:Bool{presentationTicket != nil}
  init(image:NSImage,nativeSize:CGSize,outputSize:CGSize,bytes:Int,approximation:PreviewApproximationInfo?=nil,interactiveCanonicalFallbackReason:String?=nil,presentationTicket:PreviewPresentationReservation?=nil,nativePointwise:PreviewNativePointwiseReceiptV1?=nil,actualGrainFinalTransport:String?=nil,brilliancePublicObservation:DevelopmentBrilliancePublicV1.Observation?=nil,dehazeTIFFObservation:DevelopmentDehazeTIFFPreviewV1.Observation?=nil) {
    self.image=image;self.nativeSize=nativeSize;self.outputSize=outputSize;self.bytes=bytes
    self.approximation=approximation;self.interactiveCanonicalFallbackReason=interactiveCanonicalFallbackReason;self.presentationTicket=presentationTicket;self.nativePointwise=nativePointwise
    self.actualGrainFinalTransport=actualGrainFinalTransport
    self.brilliancePublicObservation=brilliancePublicObservation;self.dehazeTIFFObservation=dehazeTIFFObservation
  }
}
/// Access the mutable filter and CIContext only on the service's single native worker.
final class PreviewNativeSource: @unchecked Sendable {
  let supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion>
  let capture: URL
  let captureID = UUID()
  let captureStamp: PreviewFileStamp
  let byteCount: Int64
  let artifact: Bool
  let decoder: String
  let nativePointwiseImageICCIdentity: String?
  let nativePointwiseImageDepth:Int?
  let nativePointwiseDeviceID:UInt64?
  let originalNativeDefaultsFingerprint:String?
  private let photoFilterKernelAvailable:Bool
  let localDecoderContractFingerprint: String
  let dehazeDecoderContractFingerprint: String
  let orientedNativeExtent:CGRect
  let nativeSize: CGSize
  let originalEXIFOrientation: Int
  let noiseReductionFacts: DevelopmentNoiseReductionFacts
  let asShotWhiteBalance: DevelopmentAsShotWhiteBalance?
  var hasRAWFilter: Bool { raw != nil }
  private var v3AnalysisCache: DevelopmentAnalysisCacheEntry?
  private var displayHistogramCache: DevelopmentDisplayHistogramEngineV1.CacheEntry?
  private var v3DecoderDefaultsFingerprint: String?
  private let raw: CIRAWFilter?
  private let base: CIImage?
  private let temperature: Float
  private let tint: Float
  private let contextMemoryLimitMiB: Int
  private(set) var context: CIContext
  private var retainedInteractiveContext: CIContext?
  init(capture: URL, byteCount: Int64, artifact: Bool, memoryLimit: Int) throws {
    self.capture = capture; self.byteCount = byteCount; self.artifact = artifact
    // Construct/warm the lazy filter kernel only on this existing native worker. Facts later
    // query only the validated store metadata; no actor-side CI context or new worker is made.
    let filterCapabilities = artifact ? DevelopmentPhotoFilterResourceStore.Capabilities(filters:[.original],resourceVersion:nil):DevelopmentPhotoFilterEngineV3.capabilities()
    photoFilterKernelAvailable = filterCapabilities.filters.count>1 && filterCapabilities.resourceVersion != nil
    captureStamp = try PreviewFileStamp.read(capture)
    nativePointwiseDeviceID=MTLCreateSystemDefaultDevice()?.registryID
    contextMemoryLimitMiB = memoryLimit
    context = CIContext(options: [.cacheIntermediates: false,
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      .memoryTarget: memoryLimit])
    let originalLocalDefaults: String?
    if !artifact && PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased()) {
      guard let filter = CIRAWFilter(imageURL: capture), let output = filter.outputImage else { throw DevelopmentError.unreadable }
      originalLocalDefaults = try DevelopmentRendererV3.decoderDefaultsFingerprint(filter)
      raw = filter; base = nil; temperature = filter.neutralTemperature; tint = filter.neutralTint
      noiseReductionFacts = .init(sourceCapability:.raw,raw:.init(
        luminanceNoiseSupported:filter.isLuminanceNoiseReductionSupported,
        colorNoiseSupported:filter.isColorNoiseReductionSupported,detailSupported:filter.isDetailSupported,
        defaultLuminanceNoise:filter.luminanceNoiseReductionAmount,
        defaultColorNoise:filter.colorNoiseReductionAmount,defaultDetail:filter.detailAmount))
      asShotWhiteBalance = .init(temperature:filter.neutralTemperature,tint:filter.neutralTint)
      filter.scaleFactor = 1; filter.isDraftModeEnabled = false
      decoder = filter.decoderVersion.rawValue; nativeSize = output.extent.size; orientedNativeExtent=output.extent; originalEXIFOrientation = Int(filter.orientation.rawValue)
    } else {
      guard let image = CIImage(contentsOf: capture, options: [.applyOrientationProperty: true]) else { throw DevelopmentError.unreadable }
      originalLocalDefaults = nil
      raw = nil; base = image; temperature = 6500; tint = 0; decoder = artifact ? "archived-image" : "image-io"
      noiseReductionFacts = .init(sourceCapability:.image,raw:nil); asShotWhiteBalance = nil
      nativeSize = image.extent.size;orientedNativeExtent=image.extent
      if let source = CGImageSourceCreateWithURL(capture as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any] {
        originalEXIFOrientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
      } else { originalEXIFOrientation = 1 }
    }
    let imageMetadata = raw == nil && !artifact ? PreviewNativePointwiseBaseV1.imageMetadata(capture):nil
    nativePointwiseImageICCIdentity=imageMetadata?.profile;nativePointwiseImageDepth=imageMetadata?.depth
    originalNativeDefaultsFingerprint=originalLocalDefaults
    guard nativeSize.width.isFinite,nativeSize.height.isFinite,nativeSize.width >= 1,nativeSize.height >= 1,
      nativeSize.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension),nativeSize.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentV3Error.invalidGraph }
    localDecoderContractFingerprint = try DevelopmentRendererV3.localDecoderFingerprint(decoder:decoder,originalDefaults:originalLocalDefaults,
      orientation:originalEXIFOrientation,size:nativeSize)
    dehazeDecoderContractFingerprint = try DevelopmentDehazeContextFactoryV1.decoderFingerprint(decoder:decoder,originalDefaults:originalLocalDefaults,
      orientation:originalEXIFOrientation,size:nativeSize)
    supportedGrainSamplingVersions=DevelopmentGrainSamplingEngineV1.admit(sourceIsRAW:raw != nil && !artifact,extent:orientedNativeExtent)
    try validateCaptureAuthority()
  }
  var photoFilterCapabilities:DevelopmentPhotoFilterResourceStore.Capabilities {
    guard !artifact,photoFilterKernelAvailable else{return .init(filters:[.original],resourceVersion:nil)}
    // Recheck payload/catalog stamps before advertising, including after a warm resource fault.
    return DevelopmentPhotoFilterResourceStore.shared.capabilities()
  }
  func dehazeContext(source:DevelopmentLocalEditSourceBinding,generation:UInt64)throws->DevelopmentDehazeContextV1 {
    try validateCaptureAuthority()
    guard !artifact,source.exifOrientation==originalEXIFOrientation,source.orientedWidth==Int(nativeSize.width),
      source.orientedHeight==Int(nativeSize.height) else { throw DevelopmentDehazePreparationError.invalidPreparation }
    let value=DevelopmentDehazeContextV1(source:source,sourceGeneration:generation,decoderContractFingerprint:dehazeDecoderContractFingerprint)
    try value.validate();return value
  }
  /// Immutable file metadata only: safe for the actor to check without touching mutable CI state.
  func validateCaptureAuthority() throws {
    guard let current = try? PreviewFileStamp.read(capture), current == captureStamp else { throw PreviewCaptureFault(captureID:captureID) }
  }
  /// The single joined preview worker calls this before independent native work:
  /// an eligible pointwise cold fill or analysis with its own context. clearCaches
  /// alone leaves the lease's last canonical CIContext alive. End that idle instance
  /// inside this pool before the independent operation creates another context.
  /// These are the SAME renderV3 options; this replacement is not evaluated here.
  /// Verified resident inputs and canonical/analysis graph bodies are unchanged.
  func retireIdleCanonicalContextForIndependentWork() {
    autoreleasepool {
      context.clearCaches()
      context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:contextMemoryLimitMiB])
      retainedInteractiveContext = nil
    }
  }
  func interactiveContext(memoryLimit: Int) throws -> CIContext {
    if let retainedInteractiveContext { return retainedInteractiveContext }
    let made = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryLimit])
    retainedInteractiveContext = made
    return made
  }
  func render(recipe: DevelopmentRecipe, maxPixel: Int, rawBasePool: PreviewRawBasePool? = nil, sourceKey: String = "",
              thumbnailNativeSink: ((CIImage) throws -> Void)? = nil,
              grainFinalTransport: PreviewGrainFinalTransportV1.Request? = nil,
              qaNeutralInput: PreviewNeutralOwnerBootstrapV1.Input? = nil,brillianceFinalTransport:DevelopmentBrilliancePublicV1.Request? = nil,dehazeTIFFRequest:DevelopmentDehazeTIFFPreviewV1.Request? = nil) throws -> PreviewPixels {
    try recipe.validate()
    if let request=dehazeTIFFRequest {
      guard maxPixel==2400,grainFinalTransport==nil,qaNeutralInput==nil,brillianceFinalTransport==nil,
        DevelopmentDehazeTIFFPreviewV1.recipeDomain(recipe),DevelopmentDehazeTIFFPreviewV1.sourceDomain(self) else{throw PreviewPresentationError.unsupported}
      try request.requireCurrent();try validateCaptureAuthority()
      retireIdleCanonicalContextForIndependentWork()
      switch try DevelopmentDehazeTIFFPreviewV1.render(native:self,recipe:recipe,request:request,thumbnailNativeSink:thumbnailNativeSink){
      case .produced(let result):return result
      case .legacyFallback(let actual):
        // Candidate tasks/graph/provider/file are already closed; this is not an error retry.
        try request.requireCurrent();try validateCaptureAuthority()
        let old=try render(recipe:recipe,maxPixel:maxPixel,rawBasePool:rawBasePool,sourceKey:sourceKey,thumbnailNativeSink:thumbnailNativeSink)
        return old.recordingDehazeTIFF(actual)
      }
    }
    if DevelopmentBrilliancePublicV1.active(recipe) {
      guard !hasRAWFilter,!artifact,maxPixel == 2400,let request=brillianceFinalTransport,grainFinalTransport == nil,
        qaNeutralInput == nil else{throw PreviewPresentationError.unsupported}
      try request.requireCurrent()
    }
    if qaNeutralInput != nil {
      guard raw == nil,!artifact,grainFinalTransport == nil,try PreviewNeutralOwnerBootstrapV1.recipeDomain(recipe),maxPixel == 2400 else {throw PreviewPresentationError.allocationProtocol}
    }
    if let grainFinalTransport {
      guard PreviewGrainFinalTransportV1.eligible(recipe:recipe,sourceIsRAW:raw != nil,artifact:artifact,maxPixel:maxPixel) else { throw PreviewPresentationError.unsupported }
      try grainFinalTransport.requireCurrent(maxPixel:maxPixel)
    }
    if recipe.schemaVersion == 3 {
      let legacyInput = raw != nil && recipe.adjustmentsV3?.blackAndWhite.requiresLegacyGrainCanonicalInput == true
      if legacyInput { try validateCaptureAuthority(); rawBasePool?.evictUnpinned() }
      return try renderV3(recipe:recipe,maxPixel:maxPixel,rawBasePool:legacyInput ? nil:rawBasePool,sourceKey:sourceKey,thumbnailNativeSink:thumbnailNativeSink,grainFinalTransport:grainFinalTransport,brillianceFinalTransport:brillianceFinalTransport)
    }
    guard recipe.engineVersion == "core-image-v1" || recipe.engineVersion == "rawmaster-color-v2" else { throw DevelopmentError.unsupportedEngine }
    if let rawBasePool, raw != nil, !artifact, recipe.schemaVersion == 2, recipe.color?.isNeutral == false {
      do { try validateCaptureAuthority() }
      catch { rawBasePool.retire(sourceKey:sourceKey); throw error }
      do {
        context.clearCaches()
        context = CIContext(options:[.cacheIntermediates:false,
          .workingColorSpace:DevelopmentColorEngineV2.linearSRGB,.memoryTarget:contextMemoryLimitMiB])
        let cached = try PreviewRawBaseRenderer.render(capture:capture,sourceKey:sourceKey,recipe:recipe,
          maxPixel:maxPixel,pool:rawBasePool,memoryHint:contextMemoryLimitMiB,captureStamp:captureStamp,decoderIdentity:decoder)
        try validateCaptureAuthority()
        if let cached { return cached }
      } catch {
        // Diagnose capture loss even when a decoder call failed before the normal post-check.
        do { try validateCaptureAuthority() } catch { rawBasePool.retire(sourceKey:sourceKey); throw error }
        throw error
      }
    }
    // Only the joined preview worker touches context/filter. Retaining one context across native
    // geometry epochs accumulated several GiB despite memoryTarget; replace it for each render.
    context.clearCaches()
    context = CIContext(options: [.cacheIntermediates: false,
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      .memoryTarget: contextMemoryLimitMiB])
    if recipe.schemaVersion == 2 && recipe.color?.isNeutral == false {
      context = CIContext(options: [.cacheIntermediates:false, .workingColorSpace:DevelopmentColorEngineV2.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue, .memoryTarget:contextMemoryLimitMiB])
    }
    var image: CIImage
    if let raw {
      raw.exposure = Float(recipe.exposureEV)
      // Restore the filter's original as-shot values after any explicit WB request.
      raw.neutralTemperature = temperature; raw.neutralTint = tint
      if case let .temperatureTint(t, v) = recipe.whiteBalance { raw.neutralTemperature = Float(t); raw.neutralTint = Float(v) }
      guard let output = raw.outputImage else { throw DevelopmentError.unreadable }; image = output
      try thumbnailNativeSink?(image)
    } else {
      if let qaNeutralInput {image=try qaNeutralInput.image(for:self,recipe:recipe,maxPixel:maxPixel)}
      else {guard let base else { throw DevelopmentError.unreadable }; image = base}
      try thumbnailNativeSink?(image)
      if !artifact {
        if case let .temperatureTint(t, v) = recipe.whiteBalance {
          image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: t, y: v), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if recipe.exposureEV != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposureEV]) }
      }
    }
    if let color = recipe.color, !color.isNeutral {
      image = try DevelopmentColorEngineV2.apply(color, to:image)
      try DevelopmentColorEngineV2.validateFinite(image,context:context)
    }
    // Same canonical geometry as PhotoRenderer.develop; no RAW scale/quality adaptation in P1.
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    if recipe.straightenDegrees != 0 {
      let w = image.extent.width, h = image.extent.height, angle = recipe.straightenDegrees * .pi / 180
      image = image.transformed(by: CGAffineTransform(translationX: -w/2, y: -h/2)).transformed(by: CGAffineTransform(rotationAngle: angle))
      let size = PhotoRenderer.inscribedSize(width: w, height: h, angle: abs(angle))
      image = image.cropped(to: CGRect(x: -size.width/2, y: -size.height/2, width: size.width, height: size.height))
      image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    let bounds = image.extent, crop = recipe.crop
    let rect = CGRect(x: bounds.width * crop.x, y: bounds.height * (1-crop.y-crop.height), width: bounds.width * crop.width, height: bounds.height * crop.height)
    let pixels = CGRect(x: ceil(rect.minX), y: ceil(rect.minY), width: floor(rect.maxX)-ceil(rect.minX), height: floor(rect.maxY)-ceil(rect.minY))
    guard pixels.width >= 1, pixels.height >= 1 else { throw DevelopmentError.invalidGeometry }
    image = image.cropped(to: pixels).transformed(by: CGAffineTransform(translationX: -pixels.minX, y: -pixels.minY))
    let canonicalSize = image.extent.size
    let limit = maxPixel <= 0 ? max(image.extent.width, image.extent.height) : CGFloat(max(64, min(4096, maxPixel)))
    let factor = min(1, limit / max(image.extent.width, image.extent.height))
    if factor < 1 { image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor)) }
    guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB, deferred: false) else { throw DevelopmentError.unreadable }
    // Own a compact CPU image independently of any CI/filter/context backing graph. Both the
    // materialization and copy are inside the render duration; preserve sRGB and premultiplied alpha.
    guard let owned = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
      bytesPerRow: cg.width * 4, space: PhotoRenderer.sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw DevelopmentError.unreadable }
    owned.setBlendMode(.copy); owned.interpolationQuality = .none
    owned.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let ownedCG = owned.makeImage() else { throw DevelopmentError.unreadable }
    let bitmap = NSBitmapImageRep(cgImage: ownedCG), result = NSImage(size: CGSize(width: cg.width, height: cg.height))
    result.addRepresentation(bitmap)
    return PreviewPixels(image: result, nativeSize: canonicalSize, outputSize: CGSize(width: cg.width, height: cg.height), bytes: bitmap.bytesPerRow * bitmap.pixelsHigh)
  }
  private func renderV3(recipe: DevelopmentRecipe, maxPixel: Int, rawBasePool: PreviewRawBasePool?, sourceKey: String,
                        thumbnailNativeSink: ((CIImage) throws -> Void)? = nil,
              grainFinalTransport: PreviewGrainFinalTransportV1.Request? = nil,brillianceFinalTransport:DevelopmentBrilliancePublicV1.Request? = nil) throws -> PreviewPixels {
    try DevelopmentRendererV3.validateSupport(recipe,sourceIsRAW:raw != nil)
    try validateCaptureAuthority()
    if let legacy = try DevelopmentRendererV3.legacyEquivalent(recipe) {
      return try render(recipe:legacy,maxPixel:maxPixel,rawBasePool:rawBasePool,sourceKey:sourceKey,thumbnailNativeSink:thumbnailNativeSink)
    }
    if DevelopmentBrilliancePublicV1.active(recipe) {
      guard let request=brillianceFinalTransport,maxPixel==2400,!hasRAWFilter,!artifact else{throw PreviewPresentationError.unsupported}
      try request.requireCurrent();context.clearCaches()
      weak var validationWitness:CIContext?
      let graph=try autoreleasepool { ()throws->DevelopedV3Graph in
        let validation=DevelopmentBrilliancePublicV1.makeContext();validationWitness=validation
        defer{validation.clearCaches()}
        return try DevelopmentRendererV3.develop(capture,recipe:recipe,context:validation,
          thumbnailNativeSink:thumbnailNativeSink,brillianceQARequest:request,checkCancellation:request.requireCurrent)
      }
      guard validationWitness == nil else{throw PreviewPresentationError.allocationProtocol}
      try request.requireCurrent()
      weak var displayWitness:CIContext?
      let result=try autoreleasepool {
        let display=DevelopmentBrilliancePublicV1.makeContext();displayWitness=display;defer{display.clearCaches()}
        let result=try V3PreviewMaterializer.materialize(graph,context:display,maxPixel:maxPixel,brillianceFinalTransport:request)
        try request.requireCurrent();try validateCaptureAuthority();return result
      }
      guard displayWitness == nil else{throw PreviewPresentationError.allocationProtocol}
      try request.requireCurrent();return result
    }
    context.clearCaches()
    context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:contextMemoryLimitMiB])
    defer { context.clearCaches() }
    do {
      if let rawBasePool, raw != nil, !artifact {
        if v3DecoderDefaultsFingerprint == nil {
          guard let fresh = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
          v3DecoderDefaultsFingerprint = try? DevelopmentRendererV3.decoderDefaultsFingerprint(fresh)
        }
        if let defaults = v3DecoderDefaultsFingerprint, let cached = try PreviewRawBaseRenderer.renderV3(capture:capture,sourceKey:sourceKey,recipe:recipe,maxPixel:maxPixel,
          pool:rawBasePool,memoryHint:contextMemoryLimitMiB,captureStamp:captureStamp,decoderIdentity:decoder,
          decoderDefaultsFingerprint:defaults,noiseDefaults:.init(luminance:noiseReductionFacts.raw!.defaultLuminanceNoise,
            color:noiseReductionFacts.raw!.defaultColorNoise,detail:noiseReductionFacts.raw!.defaultDetail,
            luminanceSupported:noiseReductionFacts.raw!.luminanceNoiseSupported,colorSupported:noiseReductionFacts.raw!.colorNoiseSupported,
            detailSupported:noiseReductionFacts.raw!.detailSupported),thumbnailNativeSink:thumbnailNativeSink,grainFinalTransport:grainFinalTransport) {
          try validateCaptureAuthority(); return cached
        }
      }
      if Self.usesOwnedV1DehazeContexts(recipe,sourceIsRAW:raw != nil && !artifact) {
        // The existing raw-base attempt above retains its admission/cache/pin contract.
        // Only its ordinary canonical fallback separates completed native validation
        // from final display. Both contexts use the original V3 options and graph.
        retireIdleCanonicalContextForIndependentWork()
        let graph = try Self.withOwnedV3Context(memoryLimit:contextMemoryLimitMiB) { validation in
          try DevelopmentRendererV3.develop(capture,recipe:recipe,context:validation,thumbnailNativeSink:thumbnailNativeSink)
        }
        let result = try Self.withOwnedV3Context(memoryLimit:contextMemoryLimitMiB) { display in
          try V3PreviewMaterializer.materialize(graph,context:display,maxPixel:maxPixel,grainFinalTransport:grainFinalTransport)
        }
        try validateCaptureAuthority(); return result
      }
      let graph = try DevelopmentRendererV3.develop(capture,recipe:recipe,context:context,thumbnailNativeSink:thumbnailNativeSink)
      let result = try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:maxPixel,grainFinalTransport:grainFinalTransport)
      try validateCaptureAuthority(); return result
    } catch {
      do { try validateCaptureAuthority() } catch { rawBasePool?.retire(sourceKey:sourceKey); throw error }
      throw error
    }
  }

  static func usesOwnedV1DehazeContexts(_ recipe:DevelopmentRecipe,sourceIsRAW:Bool)->Bool {
    guard sourceIsRAW,recipe.schemaVersion == 3,let p=recipe.adjustmentsV3?.advancedDetail else{return false}
    return p.dehaze.enabled && p.dehaze.amount != 0 &&
      p.preparedDehaze?.algorithmVersion == DevelopmentDehazeAlgorithm.v1.rawValue
  }
  /// The caller's synchronous body owns all actual task waits. Drain its autoreleased
  /// objects and release this context before returning a graph/compact frame. Preserve
  /// the original native/cancellation error after checking the same exit on failure.
  static func withOwnedV3Context<T>(memoryLimit:Int,_ body:(CIContext)throws->T)throws->T {
    weak var witness:CIContext?
    let outcome:Result<T,Error> = autoreleasepool {
      let owned=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryLimit])
      witness=owned
      defer{owned.clearCaches()}
      return Result{try body(owned)}
    }
    guard witness == nil else {
      if case .failure(let original)=outcome {throw original}
      throw PreviewPresentationError.allocationProtocol
    }
    return try outcome.get()
  }

  func analyze(_ request: DevelopmentAnalysisRequest, sourceContentID: String, cancellation: DevelopmentAnalysisCancellation? = nil, rawBasePool: PreviewRawBasePool? = nil, sourceKey: String = "", residentObserver: DevelopmentBWSummaryResidentV3.Observer? = nil) throws -> DevelopmentAnalysisResult {
    try validateCaptureAuthority(); retireIdleCanonicalContextForIndependentWork()
    let binding = DevelopmentLocalEditSourceBinding(sourceContentID:sourceContentID,exifOrientation:originalEXIFOrientation,
      orientedWidth:Int(nativeSize.width),orientedHeight:Int(nativeSize.height))
    do {
      let dehaze:DevelopmentDehazeContextV1?
      if case .prepareDehaze=request.operation { dehaze=try dehazeContext(source:binding,generation:request.preview.sourceGeneration) }
      else { dehaze=nil }
      if request.operation.isDisplayHistogram {
        let result = try DevelopmentDisplayHistogramEngineV1.run(capture:capture,request:request,sourceBinding:binding,
          memoryHint:contextMemoryLimitMiB,cache:&displayHistogramCache,cancellation:cancellation,
          sourceAuthority:{ try self.validateCaptureAuthority() })
        try validateCaptureAuthority();return result
      }
      if request.sampling == .blackAndWhiteSummaryResident32V3 {
        guard let rawBasePool, !sourceKey.isEmpty else { throw DevelopmentV3Error.unsupportedAnalysis }
        var pendingCache = v3AnalysisCache
        var result: DevelopmentAnalysisResult?
        try DevelopmentBWSummaryResidentV3.withResident(native:self,request:request,sourceKey:sourceKey,
          contentID:sourceContentID,pool:rawBasePool,cancellation:cancellation,observer:residentObserver) { input in
          result = try DevelopmentAnalysisEngine.run(capture:capture,request:request,sourceBinding:binding,
            memoryHint:contextMemoryLimitMiB,cache:&pendingCache,localDecoderContractFingerprint:localDecoderContractFingerprint,
            dehazeContext:dehaze,cancellation:cancellation,residentInput:input)
        }
        try validateCaptureAuthority(); try cancellation?.check(); try Task.checkCancellation()
        guard let result else { throw DevelopmentV3Error.invalidGraph }
        // Only pure scalars commit, after the real pipeline and pin release. Failed observers,
        // cancellation and stale source authority cannot install a new V3 cache entry.
        if let cancellation { try cancellation.withInputPublication(allowFrameSuperseded:false) { v3AnalysisCache = pendingCache } }
        else { v3AnalysisCache = pendingCache }
        return result
      }
      let result = try DevelopmentAnalysisEngine.run(capture:capture,request:request,sourceBinding:binding,
        memoryHint:contextMemoryLimitMiB,cache:&v3AnalysisCache,localDecoderContractFingerprint:localDecoderContractFingerprint,
        dehazeContext:dehaze,cancellation:cancellation)
      try validateCaptureAuthority(); return result
    } catch { try validateCaptureAuthority(); throw error }
  }

}


extension PreviewPixels {
  func recordingDehazeTIFF(_ observation:DevelopmentDehazeTIFFPreviewV1.Observation)->PreviewPixels{
    .init(image:image,nativeSize:nativeSize,outputSize:outputSize,bytes:bytes,approximation:approximation,
      interactiveCanonicalFallbackReason:interactiveCanonicalFallbackReason,presentationTicket:presentationTicket,
      nativePointwise:nativePointwise,actualGrainFinalTransport:actualGrainFinalTransport,
      brilliancePublicObservation:brilliancePublicObservation,dehazeTIFFObservation:observation)
  }
}
