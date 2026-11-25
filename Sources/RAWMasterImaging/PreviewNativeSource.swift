import AppKit
import CoreImage
import ImageIO
import CryptoKit
import Metal
import Darwin
import RAWMasterCore

struct PreviewFileStamp: Hashable, Sendable {
  let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
  static func read(_ url: URL, noFollow: Bool = false) throws -> Self {
    let fd = Darwin.open(url.path, noFollow ? O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK : O_RDONLY)
    guard fd >= 0 else { throw DevelopmentPreviewError.sourceInvalidated }
    defer { Darwin.close(fd) }
    return try read(descriptor: fd)
  }
  static func read(descriptor fd: Int32) throws -> Self {
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
  /// Visible window in the canvas, normalized with a top-left origin. `nil` is the whole canvas.
  let window: CGRect?
  let bytes: Int
  let settledReplayKey: String?
  let approximation:PreviewApproximationInfo?
  let interactiveCanonicalFallbackReason:String?
  let nativePointwise:PreviewNativePointwiseReceiptV1?
  let actualGrainFinalTransport:String?
  let brilliancePublicObservation:DevelopmentBrilliancePublicV1.Observation?
  let dehazeTIFFObservation:DevelopmentDehazeTIFFPreviewV1.Observation?
  let presentationTicket:PreviewPresentationReservation?
  var managedPresentation:Bool{presentationTicket != nil}
  init(image:NSImage,nativeSize:CGSize,outputSize:CGSize,window:CGRect?=nil,bytes:Int,settledReplayKey:String?=nil,approximation:PreviewApproximationInfo?=nil,interactiveCanonicalFallbackReason:String?=nil,presentationTicket:PreviewPresentationReservation?=nil,nativePointwise:PreviewNativePointwiseReceiptV1?=nil,actualGrainFinalTransport:String?=nil,brilliancePublicObservation:DevelopmentBrilliancePublicV1.Observation?=nil,dehazeTIFFObservation:DevelopmentDehazeTIFFPreviewV1.Observation?=nil) {
    self.image=image;self.nativeSize=nativeSize;self.outputSize=outputSize;self.window=window;self.bytes=bytes
    self.settledReplayKey=settledReplayKey;self.approximation=approximation;self.interactiveCanonicalFallbackReason=interactiveCanonicalFallbackReason;self.presentationTicket=presentationTicket;self.nativePointwise=nativePointwise
    self.actualGrainFinalTransport=actualGrainFinalTransport
    self.brilliancePublicObservation=brilliancePublicObservation;self.dehazeTIFFObservation=dehazeTIFFObservation
  }
}
/// Access the mutable filter and CIContext only on the service's single native worker.
final class PreviewNativeSource: @unchecked Sendable {
  let supportedGrainSamplingVersions: Set<DevelopmentGrainSamplingVersion>
  let capture: URL
  let captureID: UUID
  let captureStamp: PreviewFileStamp
  private let verifiedCapture: RenderFiles.VerifiedCapture?
  private let verifiedLocalBinding: DevelopmentLocalEditSourceBinding?
  private static let reusesLocalBinding = ProcessInfo.processInfo.environment["RAWMASTER_VERIFIED_LOCAL_SOURCE_BINDING"] != "0"
  let byteCount: Int64
  let artifact: Bool
  let decoder: String
  let nativePointwiseImageICCIdentity: String?
  let nativePointwiseImageDepth:Int?
  let nativePointwiseDeviceID:UInt64?
  let interactiveMetalDevice: MTLDevice?
  let originalNativeDefaultsFingerprint:String?
  private let photoFilterKernelAvailable:Bool
  let localDecoderContractFingerprint: String
  let dehazeDecoderContractFingerprint: String
  let orientedNativeExtent:CGRect
  let nativeSize: CGSize
  let originalEXIFOrientation: Int
  let noiseReductionFacts: DevelopmentNoiseReductionFacts
  let asShotWhiteBalance: DevelopmentAsShotWhiteBalance?
  let lensMetadata: DevelopmentLensMetadata?
  var hasRAWFilter: Bool { raw != nil }
  private var v3AnalysisCache: DevelopmentAnalysisCacheEntry?
  private var displayHistogramCache: DevelopmentDisplayHistogramEngineV1.CacheEntry?
  private var v3DecoderDefaultsFingerprint: String?
  let rawDetailsCapability: DevelopmentRawDetails?
  let aiDenoiseCapability: DevelopmentAIDenoiseV1.Model?
  private let raw: CIRAWFilter?
  private let base: CIImage?
  private let temperature: Float
  private let tint: Float
  private let contextMemoryLimitMiB: Int
  private static let retainsFullValidationCache = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_FULL_VALIDATION_CACHE"] == "1" &&
    ProcessInfo.processInfo.environment["RAWMASTER_MAXIMUM_QA_SCALARS"] != "1"
  private static let reusesCanonicalContext = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_CONTEXT_REUSE"] == "1"
  /// Opt-in candidate for the native path: cache intermediates so the validation scan and the
  /// final materialization evaluate the graph once. Default off; no production caller sets it.
  private static let nativeIntermediateCache = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_INTERMEDIATE_CACHE"] == "1"
  private static let reusesPortableHalfContext = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_HALF_CONTEXT_REUSE"] == "1"
  private static let cachesSpatialMasks = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_SPATIAL_MASK_CACHE"] == "1"
  private(set) var context: CIContext
  private weak var clearedCanonicalContext: CIContext?
  private var remainingCanonicalContextUses = 0
  private var retainedInteractiveContext: CIContext?
  private var retainedPointColorContext: CIContext?
  private var retainedMaskGrainContext: CIContext?
  private weak var pendingSharpenRetraction: CIContext?
  private var pendingSharpenMaskPreview = false
  private var flashRawCacheSourceKey: String?
  convenience init(capture: URL, byteCount: Int64, artifact: Bool, memoryLimit: Int) throws {
    try self.init(capture: capture, byteCount: byteCount, artifact: artifact, memoryLimit: memoryLimit, verified: nil)
  }

  static func openVerifiedRAW(_ capture: RenderFiles.VerifiedCapture, memoryLimit: Int) throws -> PreviewNativeSource {
    guard PhotoRenderer.rawExtensions.contains(capture.url.pathExtension.lowercased()) else { throw DevelopmentError.unreadable }
    return try capture.withCurrent(at: capture.url) {
      try PreviewNativeSource(capture: capture.url, byteCount: capture.stamp.size, artifact: false,
        memoryLimit: memoryLimit, verified: capture)
    }
  }

  private init(capture: URL, byteCount: Int64, artifact: Bool, memoryLimit: Int,
               verified: RenderFiles.VerifiedCapture?) throws {
    self.capture = capture; self.byteCount = byteCount; self.artifact = artifact
    self.verifiedCapture = verified
    self.captureID = verified?.id ?? UUID()
    // Construct/warm the lazy filter kernel only on this existing native worker. Facts later
    // query only the validated store metadata; no actor-side CI context or new worker is made.
    let filterCapabilities = artifact ? DevelopmentPhotoFilterResourceStore.Capabilities(filters:[.original],resourceVersion:nil):DevelopmentPhotoFilterEngineV3.capabilities()
    photoFilterKernelAvailable = filterCapabilities.filters.count>1 && filterCapabilities.resourceVersion != nil
    captureStamp = try verified?.stamp ?? PreviewFileStamp.read(capture)
    lensMetadata=artifact ? nil:DevelopmentLensMetadata.read(capture)
    interactiveMetalDevice=MTLCreateSystemDefaultDevice()
    nativePointwiseDeviceID=interactiveMetalDevice?.registryID
    contextMemoryLimitMiB = memoryLimit
    context = CIContext(options: [.cacheIntermediates: false,
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
      .memoryTarget: memoryLimit])
    let originalLocalDefaults: String?
    if !artifact && PhotoRenderer.rawExtensions.contains(capture.pathExtension.lowercased()) {
      guard let filter = CIRAWFilter(imageURL: capture), let output = filter.outputImage else { throw DevelopmentError.unreadable }
      // These are the unconfigured Core Image decoder facts also used by fromCapture.
      decoder = filter.decoderVersion.rawValue; nativeSize = output.extent.size; orientedNativeExtent=output.extent; originalEXIFOrientation = Int(filter.orientation.rawValue)
      originalLocalDefaults = try DevelopmentRendererV3.decoderDefaultsFingerprint(filter)
      rawDetailsCapability = DevelopmentRAWSourcePolicy.rawDetailsCapability(at: capture, nativeSize: output.extent.size, orientation: Int(filter.orientation.rawValue))
      aiDenoiseCapability = DevelopmentNeuralRaw9.capability(filter,mosaic:rawDetailsCapability) ?? DevelopmentPhotoDenoise.capability(at:capture)
      raw = filter; base = nil; temperature = filter.neutralTemperature; tint = filter.neutralTint
      noiseReductionFacts = .init(sourceCapability:.raw,raw:.init(
        luminanceNoiseSupported:filter.isLuminanceNoiseReductionSupported,
        colorNoiseSupported:filter.isColorNoiseReductionSupported,detailSupported:filter.isDetailSupported,
        defaultLuminanceNoise:filter.luminanceNoiseReductionAmount,
        defaultColorNoise:filter.colorNoiseReductionAmount,defaultDetail:filter.detailAmount))
      asShotWhiteBalance = .init(temperature:filter.neutralTemperature,tint:filter.neutralTint)
      filter.scaleFactor = 1; filter.isDraftModeEnabled = false
      // The source-bound mask, local edit and WB checks use this configured RAW output.
      // The decoder fingerprints above use the original, unconfigured filter.
      if Self.reusesLocalBinding, let verified, let size = filter.outputImage?.extent.size,
         let width = Int(exactly: size.width), let height = Int(exactly: size.height),
         (1...DevelopmentLocalEditLimits.maximumSourceDimension).contains(width),
         (1...DevelopmentLocalEditLimits.maximumSourceDimension).contains(height),
         (1...8).contains(Int(filter.orientation.rawValue)) {
        verifiedLocalBinding = .init(sourceContentID: verified.contentSHA256, exifOrientation: Int(filter.orientation.rawValue),
                                     orientedWidth: width, orientedHeight: height)
      } else {
        verifiedLocalBinding = nil
      }
    } else {
      verifiedLocalBinding = nil
      guard let image = CIImage(contentsOf: capture, options: [.applyOrientationProperty: true]) else { throw DevelopmentError.unreadable }
      rawDetailsCapability = nil
      aiDenoiseCapability = artifact ? nil : DevelopmentPhotoDenoise.capability(at: capture)
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
  deinit {
    if PreviewPortableMaskRegion.enabled { PreviewPortableMaskRegion.retire(captureID: captureID) }
    if let flashRawCacheSourceKey { FlashRawCanonicalTexturePool.shared.retire(sourceKey:flashRawCacheSourceKey) }
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

  /// Only a source opened from the verified writer can supply this context. The
  /// decoder facts belong to that capture. Filter resources and OS are live inputs.
  func verifiedDehazeContext(for capture: URL, guideStamp: PreviewFileStamp) throws -> DevelopmentDehazeContextV1 {
    guard let verifiedCapture, guideStamp == verifiedCapture.stamp, let defaults = originalNativeDefaultsFingerprint else {
      throw PreviewCaptureFault(captureID: captureID)
    }
    return try verifiedCapture.withCurrent(at: capture) {
      try Task.checkCancellation()
      let decoderContract = try DevelopmentDehazeContextFactoryV1.decoderFingerprint(decoder: decoder,
        originalDefaults: defaults, orientation: originalEXIFOrientation, size: nativeSize)
      let binding = DevelopmentLocalEditSourceBinding(sourceContentID: verifiedCapture.contentSHA256,
        exifOrientation: originalEXIFOrientation, orientedWidth: Int(nativeSize.width), orientedHeight: Int(nativeSize.height))
      let context = DevelopmentDehazeContextV1(source: binding, sourceGeneration: 1, decoderContractFingerprint: decoderContract)
      try context.validate()
      try Task.checkCancellation()
      return context
    }
  }

  /// Immutable file metadata only: safe for the actor to check without touching mutable CI state.
  func validateCaptureAuthority() throws {
    if let verifiedCapture { return try verifiedCapture.requireCurrent(at: capture) }
    guard let current = try? PreviewFileStamp.read(capture), current == captureStamp else { throw PreviewCaptureFault(captureID:captureID) }
  }

  /// Granted to one admitted preview worker. A revoked worker or replaced file fails
  /// even if the source byte count, path and recorded recipe binding still match.
  struct LocalSourceValidation {
    fileprivate let capture: RenderFiles.VerifiedCapture
    fileprivate let binding: DevelopmentLocalEditSourceBinding
    fileprivate let cancellation: DevelopmentAnalysisCancellation

    func withBinding<T>(at url: URL, _ validate: (DevelopmentLocalEditSourceBinding) throws -> T) throws -> T {
      try capture.withCurrent(at: url) {
        try cancellation.check()
        let result = Result { try validate(binding) }
        try cancellation.check()
        return try result.get()
      }
    }
  }

  func localSourceValidation(for parameters: DevelopmentAdjustmentsV3,
                             cancellation: DevelopmentAnalysisCancellation?) throws -> LocalSourceValidation? {
    guard let cancellation, let capture = verifiedCapture, let binding = verifiedLocalBinding,
          DevelopmentRendererV3.requiresLocalSource(parameters) else { return nil }
    return try capture.withCurrent(at: self.capture) {
      try cancellation.check()
      return LocalSourceValidation(capture: capture, binding: binding, cancellation: cancellation)
    }
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
      retainedPointColorContext?.clearCaches()
      retainedPointColorContext = nil
      retainedMaskGrainContext?.clearCaches()
      retainedMaskGrainContext = nil
    }
  }
  func retainContextForConsecutiveSharpen(_ context: CIContext, maskPreview: Bool) {
    pendingSharpenRetraction=context
    pendingSharpenMaskPreview=maskPreview
  }
  func interactiveContext(memoryLimit: Int, pointColor: Bool = false, maskGrain: Bool = false, sharpenMaskPreview: Bool? = nil) throws -> CIContext {
    if let pendingSharpenRetraction, sharpenMaskPreview != pendingSharpenMaskPreview || retainedInteractiveContext !== pendingSharpenRetraction {
      pendingSharpenRetraction.clearCaches()
      self.pendingSharpenRetraction=nil
    }
    if let retained = maskGrain ? retainedMaskGrainContext : (pointColor ? retainedPointColorContext : retainedInteractiveContext) { return retained }
    let made = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:memoryLimit])
    if maskGrain { retainedMaskGrainContext = made }
    else if pointColor { retainedPointColorContext = made }
    else { retainedInteractiveContext = made }
    return made
  }
  /// Warm the canonical full-resolution FlashRaw texture and the canonical graph context while the
  /// canvas is idle. The first 1:1 frame otherwise pays that decode and upload itself (about
  /// 118 ms on a 9504x6336 ARW); afterwards it is a cache hit.
  func prewarmCanonicalDetail(sourceKey: String) {
    guard hasRAWFilter, !artifact else { return }
    let parameters = DevelopmentAdjustmentsV3()
    _ = try? pinFlashRawSource(parameters, sourceKey: sourceKey)?.release()
  }
  func pinFlashRawSource(_ parameters:DevelopmentAdjustmentsV3, sourceKey:String) throws -> FlashRawCanonicalTexturePool.Pin? {
    let key = FlashRawCanonicalTextureKey(sourceKey:sourceKey,captureStamp:captureStamp,
      contract:parameters.rawDetails?.rawValue ?? "flashraw-0.3.1-bilinear-canonical-rgba16f-v2",
      width:Int(nativeSize.width),height:Int(nativeSize.height))
    let pool=FlashRawCanonicalTexturePool.shared
    guard pool.canHold(key) else { return nil }
    flashRawCacheSourceKey=sourceKey
    if FlashRawNativeFiniteCheck.enabled, verifiedCapture != nil, originalEXIFOrientation == 1,
       parameters.rawDecoder == .flashRaw031, parameters.rawDetails == nil {
      return try pool.acquireNative(key) {
        try FlashRawImageFactory.nativePreviewImage(capture:capture,rawDetails:parameters.rawDetails,retainNativeTexture:true)
      }
    }
    return try pool.acquire(key) { try FlashRawImageFactory.linearImage(capture:capture,rawDetails:parameters.rawDetails) }
  }
  func pinInteractiveDetailGuide(_ detail:PreviewInteractiveDetailGuide,descriptor:PreviewInteractiveInputDescriptor,
                                 source:CIImage,upstreamIdentity:String? = nil,context:CIContext,device:MTLDevice,
                                 check:()throws->Void) throws -> FlashRawCanonicalTexturePool.Pin? {
    let extent = source.extent
    let contract = try "proxy-detail-guide-v1/" + descriptor.fingerprint() + "/" + detail.identity
      + (upstreamIdentity.map { "/filtered-band-v1/" + $0 } ?? "")
    let key = FlashRawCanonicalTextureKey(sourceKey:descriptor.sourceKey,captureStamp:captureStamp,contract:contract,
      width:Int(extent.width),height:Int(extent.height),representation:.guideR32F)
    flashRawCacheSourceKey = descriptor.sourceKey
    do {
      return try FlashRawCanonicalTexturePool.shared.acquire(key) {
        let timing = ImagePerformanceTelemetry.shared.begin(operation:"PreviewInteractiveDetailGuide",stage:"交互细节邻域",queue:"Metal GPU",boundary:.gpuCompletion)
        var outcome = ImagePerformanceOutcome.failed
        defer { ImagePerformanceTelemetry.shared.end(timing,outcome:outcome,pixelCount:key.width*key.height,byteCount:key.byteCount) }
        let factor = try detail.factor(for:source)
        let concrete = try DevelopmentSpatialEngineV3.materializeScalar(factor,context:context,device:device,check:check)
        outcome = .succeeded
        return concrete
      }
    } catch RawBaseCacheError.capacity { return nil }
  }
  func pinInteractiveLightGuide(_ p:DevelopmentAdjustmentsV3,descriptor:PreviewInteractiveInputDescriptor,
                                input:CIImage,radius:Double,context:CIContext,device:MTLDevice,check:()throws->Void) throws -> FlashRawCanonicalTexturePool.Pin? {
    let extent=input.extent
    guard descriptor.usesFlashRaw, p.rawDecoder == .flashRaw031, extent.origin == .zero, extent==extent.integral else {return nil}
    let traceStart = PreviewInteractivePhaseProfile.enabled ? DispatchTime.now().uptimeNanoseconds : nil
    var disposition = "invalid-key"
    defer {
      if let traceStart {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - traceStart) / 1_000_000
        let message = "PROXY-LIGHT-GUIDE \(disposition) highlights=\(p.light.highlights) shadows=\(p.light.shadows) lookupMs=\(elapsed)\n"
        FileHandle.standardError.write(Data(message.utf8))
      }
    }
    // These inputs precede local light. Strength, later colour adjustments, masks and
    // output geometry do not enter the guide. The source pixel grid and decoder do.
    struct Input:Encodable {
      let proxy:String, exposure:Double, radius:Double
      let legacy:DevelopmentLegacyBasis?, whiteBalance:DevelopmentWhiteBalanceV3, noise:DevelopmentNoiseReductionV3
    }
    let identity=try EditingFingerprint.of(Input(proxy:descriptor.fingerprint(),exposure:p.light.exposure,radius:radius,
      legacy:p.legacyBasis,whiteBalance:p.whiteBalance,noise:p.noiseReduction))
    let key=FlashRawCanonicalTextureKey(sourceKey:descriptor.sourceKey,captureStamp:captureStamp,contract:"proxy-log-luma-gaussian-v1/"+identity,
      width:Int(extent.width),height:Int(extent.height),representation:.guideR32F)
    flashRawCacheSourceKey=descriptor.sourceKey
    disposition = "hit"
    do {
      return try FlashRawCanonicalTexturePool.shared.acquire(key) {
        disposition = "fill"
        let timing=ImagePerformanceTelemetry.shared.begin(operation:"DevelopmentSpatialEngineV3.meanLogLuminance",
          stage:"交互高光与阴影引导图",queue:"Metal GPU",boundary:.gpuCompletion)
        var result=ImagePerformanceOutcome.failed
        defer {ImagePerformanceTelemetry.shared.end(timing,outcome:result,pixelCount:key.width*key.height,byteCount:key.byteCount)}
        let mean=try DevelopmentSpatialEngineV3.meanLogLuminance(input,radius:radius)
        let stored=try DevelopmentSpatialEngineV3.materializeScalar(mean,context:context,device:device,check:check)
        result = .succeeded
        return stored
      }
    } catch RawBaseCacheError.capacity { disposition = "capacity-fallback"; return nil }
    catch { disposition = "failed"; throw error }
  }
  func render(recipe: DevelopmentRecipe, maxPixel: Int, window: CGRect? = nil,
              rawBasePool: PreviewRawBasePool? = nil, sourceKey: String = "",
              localMaskValidation: DevelopmentMaskEngineV3.CanonicalValidation? = nil,
              thumbnailNativeSink: ((CIImage) throws -> Void)? = nil,
              grainFinalTransport: PreviewGrainFinalTransportV1.Request? = nil,
              qaNeutralInput: PreviewNeutralOwnerBootstrapV1.Input? = nil,brillianceFinalTransport:DevelopmentBrilliancePublicV1.Request? = nil,dehazeTIFFRequest:DevelopmentDehazeTIFFPreviewV1.Request? = nil,
              spatialScan: DevelopmentCanonicalFiniteGPU.SpatialRequest? = nil, checkDehazeTexture: (() throws -> Void)? = nil,
              checkCanonicalCache: (() throws -> Void)? = nil,
              checkCanonicalHalfFIT: (() throws -> Void)? = nil,
              portableHalfFITRequest: PreviewPortableHalfFIT.Request? = nil,
              nativeFiniteCheck: FlashRawNativeFiniteCheck.Request? = nil,
              localSourceCancellation: DevelopmentAnalysisCancellation? = nil) throws -> PreviewPixels {
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
      do {
        return try renderV3(recipe:recipe,maxPixel:maxPixel,window:window,rawBasePool:legacyInput ? nil:rawBasePool,sourceKey:sourceKey,
          localMaskValidation:localMaskValidation,thumbnailNativeSink:thumbnailNativeSink,grainFinalTransport:grainFinalTransport,
          brillianceFinalTransport:brillianceFinalTransport,spatialScan:spatialScan,checkDehazeTexture:checkDehazeTexture,
          checkCanonicalCache:checkCanonicalCache,checkCanonicalHalfFIT:checkCanonicalHalfFIT,
          portableHalfFITRequest:portableHalfFITRequest,nativeFiniteCheck:nativeFiniteCheck,
          localSourceCancellation:localSourceCancellation)
      } catch {
        try verifiedCapture?.requireCurrent(at: capture)
        throw error
      }
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
  /// A window narrows only the native 1:1 materialization. Settled and interactive frames are
  /// whole-canvas proxies whose canvas already equals the display, so they ignore it.
  private func detailWindow(maxPixel: Int, window: CGRect?) -> CGRect? {
    maxPixel == 0 ? window : nil
  }
  private func hasCanonicalCacheHeadroom(for extent: CGRect) -> Bool {
    guard #available(macOS 27, *), verifiedCapture != nil, contextMemoryLimitMiB == 512,
          ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024,
          extent.origin == .zero, extent == extent.integral, extent.width >= extent.height,
          extent.width > 2400, extent.height >= 1, extent.width * extent.height <= 64 * 1024 * 1024,
          let device = interactiveMetalDevice, device.hasUnifiedMemory else { return false }
    // Check headroom for the context target and one full-size Float32 intermediate.
    let required = UInt64(contextMemoryLimitMiB * 1024 * 1024) + UInt64(extent.width * extent.height) * 16
    let used = UInt64(device.currentAllocatedSize)
    let limit = device.recommendedMaxWorkingSetSize
    return used <= limit && required <= limit - used
  }

  private var acceptsHalfFITSource: Bool {
    hasRAWFilter && !artifact && verifiedCapture != nil && originalEXIFOrientation == 1 && contextMemoryLimitMiB == 512
  }

  func qualifiesPortableHalfFITRecipe(_ adjustments: DevelopmentAdjustmentsV3) -> Bool {
    guard acceptsHalfFITSource, let device = interactiveMetalDevice else { return false }
    return PreviewPortableHalfFIT.supports(adjustments) && PreviewPortableHalfFIT.supports(nativeSize, device:device)
  }

  func qualifiesPortableMaskHalfFIT(_ adjustments: DevelopmentAdjustmentsV3) -> Bool {
    guard DevelopmentCanonicalFiniteGPU.enabled, acceptsHalfFITSource, let device = interactiveMetalDevice,
          PreviewPortableHalfFIT.supports(nativeSize, device: device) else { return false }
    return PreviewPortableMaskTone(adjustments) != nil
  }

  func qualifiesPortableGradingHalfFIT(_ adjustments: DevelopmentAdjustmentsV3) -> Bool {
    guard acceptsHalfFITSource, let device = interactiveMetalDevice,
          PreviewPortableHalfFIT.supports(nativeSize, device: device) else { return false }
    return PreviewPortableGrading(adjustments) != nil
  }

  func qualifiesHalfFITRecipe(_ adjustments: DevelopmentAdjustmentsV3) -> Bool {
    guard acceptsHalfFITSource, adjustments.rawDecoder == .flashRaw031 else { return false }
    if !adjustments.masks.isEmpty {
      return DevelopmentMaskEngineV3.CanonicalValidation.qualifies(adjustments,
        extent:CGRect(origin:.zero,size:nativeSize),transport:.pointwiseRegion)
    }
    let curves = adjustments.curves
    guard curves.algorithm == .legacyPCHIPV1, curves.parametric == nil, curves.refineSaturation == nil,
          DevelopmentColorEngineV3.curvesActive(curves) else { return false }
    var curveOnly = adjustments.neutralForSameSource
    curveOnly.curves = curves
    return adjustments == curveOnly
  }

  private func renderV3(recipe: DevelopmentRecipe, maxPixel: Int, window: CGRect?,
                        rawBasePool: PreviewRawBasePool?, sourceKey: String,
                        localMaskValidation: DevelopmentMaskEngineV3.CanonicalValidation? = nil,
                        thumbnailNativeSink: ((CIImage) throws -> Void)? = nil,
                        grainFinalTransport: PreviewGrainFinalTransportV1.Request? = nil,brillianceFinalTransport:DevelopmentBrilliancePublicV1.Request? = nil,
                        spatialScan: DevelopmentCanonicalFiniteGPU.SpatialRequest? = nil, checkDehazeTexture: (() throws -> Void)? = nil,
                        checkCanonicalCache: (() throws -> Void)? = nil,
                        checkCanonicalHalfFIT: (() throws -> Void)? = nil,
                        portableHalfFITRequest: PreviewPortableHalfFIT.Request? = nil,
                        nativeFiniteCheck: FlashRawNativeFiniteCheck.Request? = nil,
                        localSourceCancellation: DevelopmentAnalysisCancellation? = nil) throws -> PreviewPixels {
    let previousContextWasCleared = clearedCanonicalContext === context
    clearedCanonicalContext = nil
    try DevelopmentRendererV3.validateSupport(recipe,sourceIsRAW:raw != nil)
    try validateCaptureAuthority()
    if let legacy = try DevelopmentRendererV3.legacyEquivalent(recipe) {
      return try render(recipe:legacy,maxPixel:maxPixel,window:window,rawBasePool:rawBasePool,sourceKey:sourceKey,thumbnailNativeSink:thumbnailNativeSink)
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
    let bindingCheck = try recipe.adjustmentsV3.flatMap { try localSourceValidation(for: $0, cancellation: localSourceCancellation) }
    if raw != nil, !artifact, let adjustments = recipe.adjustmentsV3, DevelopmentRAWSourcePolicy.usesFlashRaw(adjustments) {
      CanonicalPreviewDiagnostic.measure("clear before render") { self.context.clearCaches() }
      var options: [CIContextOption: Any] = [.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:contextMemoryLimitMiB]
      // Candidate: the native path validates the whole graph and then materializes it again.
      // Caching intermediates lets the second evaluation reuse the first. Still off by default:
      // measured gain on the native 1:1 path is 1-3%, below the option's documented risk.
      if Self.nativeIntermediateCache { options[.cacheIntermediates] = true }
      let pointwise = DevelopmentCanonicalFiniteGPU.eligible(adjustments,maxPixel:maxPixel)
      let grading = checkCanonicalHalfFIT != nil && PreviewPortableGrading.enabled
        ? PreviewPortableGrading(adjustments) : nil
      let reusablePortableHalf = Self.reusesPortableHalfContext && portableHalfFITRequest != nil &&
        (qualifiesPortableHalfFITRecipe(adjustments) ||
         (PreviewPortableMaskTone.enabled && qualifiesPortableMaskHalfFIT(adjustments)))
      let mayReuse = Self.reusesCanonicalContext && pointwise && maxPixel == 2400 && originalEXIFOrientation == 1 &&
        nativeFiniteCheck?.mayCheckTexture == true && (checkCanonicalHalfFIT == nil || grading != nil || reusablePortableHalf) &&
        adjustments.rawDetails == nil && adjustments.geometry == .init() &&
        thumbnailNativeSink == nil && grainFinalTransport == nil && checkCanonicalCache == nil && checkDehazeTexture == nil &&
        hasCanonicalCacheHeadroom(for:orientedNativeExtent)
      let sourceContext: CIContext
      if mayReuse, remainingCanonicalContextUses > 0, previousContextWasCleared {
        sourceContext = CanonicalPreviewDiagnostic.measure("reuse cleared context") { self.context }
        remainingCanonicalContextUses -= 1
      } else {
        sourceContext = CanonicalPreviewDiagnostic.measure("create context") { CIContext(options:options) }
        remainingCanonicalContextUses = mayReuse ? 7 : 0
      }
      self.context = sourceContext
      defer { CanonicalPreviewDiagnostic.measure("clear after render") { sourceContext.clearCaches() } }

      let cacheSource = adjustments.rawDecoder != nil || adjustments.rawDetails != nil || rawBasePool != nil
      let texturePin = cacheSource ? try pinFlashRawSource(adjustments,sourceKey:sourceKey) : nil
      defer{texturePin?.release()}
      let neutral = try texturePin?.image ?? FlashRawImageFactory.linearImage(capture:capture,rawDetails:adjustments.rawDetails)
      let noiseDomain: PreviewNativeNoiseDomain?
      if PreviewNativeNoiseDomain.enabled, verifiedCapture != nil, originalEXIFOrientation == 1,
         contextMemoryLimitMiB == 512, maxPixel == 2400, ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024,
         thumbnailNativeSink == nil, grainFinalTransport == nil, brillianceFinalTransport == nil,
         checkCanonicalCache == nil, checkCanonicalHalfFIT == nil, checkDehazeTexture == nil, localMaskValidation == nil,
         let spatialScan, spatialScan.workingBudget == DevelopmentCanonicalFiniteGPU.spatialWorkingBudget,
         spatialScan.sharpenOutput == nil, let nativeFiniteCheck, nativeFiniteCheck.mayCheckTexture,
         let texturePin, neutral === texturePin.image, neutral.extent == CGRect(origin: .zero, size: nativeSize),
         let device = interactiveMetalDevice {
        noiseDomain = try PreviewNativeNoiseDomain.acquire(adjustments, pin: texturePin, asShotWhiteBalance: asShotWhiteBalance,
          device: device, checkAuthority: {
            try spatialScan.checkCancellation()
            try nativeFiniteCheck.checkAuthority()
          })
      } else {
        noiseDomain = nil
      }
      let based = try noiseDomain?.based ?? FlashRawImageFactory.applyInputAdjustments(adjustments,to:neutral,asShotWhiteBalance:asShotWhiteBalance)
      let checkCache: (() throws -> Void)?
      let spatialMaskCache: Bool
      if let checkCanonicalCache, texturePin != nil, maxPixel == 2400, pointwise,
         adjustments.rawDetails == nil, localMaskValidation == nil, spatialScan == nil,
         checkDehazeTexture == nil, grainFinalTransport == nil, thumbnailNativeSink == nil,
         hasCanonicalCacheHeadroom(for:based.extent) {
        spatialMaskCache = false
        checkCache = {
          try checkCanonicalCache()
          try self.validateCaptureAuthority()
        }
      } else if Self.cachesSpatialMasks, DevelopmentCheckedMaximumV3.groupedScalarsEnabled,
                let request = localMaskValidation, request.transport == .spatialTileRegion,
                maxPixel == 2400, originalEXIFOrientation == 1, adjustments.rawDetails == nil,
                let local = adjustments.masks.first?.adjustments, (local.clarity ?? 0) > 0 || (local.texture ?? 0) > 0,
                let nativeFiniteCheck, nativeFiniteCheck.mayCheckTexture, let texturePin, based === texturePin.image,
                let device = interactiveMetalDevice, PreviewPortableHalfFIT.supports(nativeSize, device:device),
                spatialScan == nil, checkCanonicalCache == nil, checkCanonicalHalfFIT == nil, checkDehazeTexture == nil,
                grainFinalTransport == nil, brillianceFinalTransport == nil, thumbnailNativeSink == nil,
                DevelopmentMaskEngineV3.CanonicalValidation.qualifies(adjustments, extent:based.extent, transport:.spatialTileRegion),
                hasCanonicalCacheHeadroom(for:based.extent) {
        spatialMaskCache = true
        checkCache = {
          try request.checkCancellation()
          try nativeFiniteCheck.checkAuthority()
          try self.validateCaptureAuthority()
          guard texturePin.isCurrent(for:based) else { throw PreviewPresentationError.allocationProtocol }
        }
      } else {
        spatialMaskCache = false
        checkCache = nil
      }
      let cachesIntermediates = checkCache != nil
      try checkCache?()
      let context: CIContext
      if cachesIntermediates {
        options[.cacheIntermediates] = true
        context = CanonicalPreviewDiagnostic.measure(spatialMaskCache ? "create context with spatial mask cache" : "create context with request cache") {
          CIContext(options:options)
        }
      } else {
        context = sourceContext
      }
      // This context's cached images live through validation and FIT for one joined request.
      defer {
        if cachesIntermediates {
          CanonicalPreviewDiagnostic.measure("clear after request cache") { context.clearCaches() }
        }
      }
      let halfErosion: DevelopmentNativeDehazeErosion.Request?
      if DevelopmentNativeDehazeErosion.enabled, verifiedCapture != nil, originalEXIFOrientation == 1,
         contextMemoryLimitMiB == 512, maxPixel == 2400, !cachesIntermediates,
         thumbnailNativeSink == nil, spatialScan == nil, localMaskValidation == nil, grainFinalTransport == nil,
         checkCanonicalCache == nil, checkCanonicalHalfFIT == nil, checkDehazeTexture == nil,
         let nativeFiniteCheck, nativeFiniteCheck.mayCheckTexture, let texturePin, let device = interactiveMetalDevice {
        halfErosion = .init(pin:texturePin,image:based,device:device,adjustments:adjustments,checkAuthority:nativeFiniteCheck.checkAuthority)
      } else { halfErosion = nil }
      let dehazeGuide = texturePin != nil && contextMemoryLimitMiB >= 512 && (1...2400).contains(maxPixel)
        ? try DevelopmentResidentDehazeGuide(adjustments,sourceKey:sourceKey,stamp:captureStamp,size:nativeSize,
                                             device:interactiveMetalDevice,verifiedSource:verifiedCapture == nil ? nil : self,
                                             allowsSharedTexture:checkDehazeTexture != nil,halfErosion:halfErosion) : nil
      defer { dehazeGuide?.release() }
      let usesResidentValidation = texturePin != nil && contextMemoryLimitMiB >= 512 &&
        (pointwise || dehazeGuide != nil)
      // Spatial graphs have a separate measured working set. Stay within the size
      // and host memory range admitted for this transport before reserving bands.
      let admittedScan = texturePin != nil && contextMemoryLimitMiB == 512
        && ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024
        && based.extent.width * based.extent.height <= 64 * 1024 * 1024 ? spatialScan : nil
      let sharpenOutput = admittedScan?.sharpenOutput
      let workingBudget = (sharpenOutput == nil ? admittedScan?.workingBudget : nil)
        ?? (usesResidentValidation ? DevelopmentCanonicalFiniteGPU.workingSetLimit : nil)
      let checkSpatialScan: (() throws -> Void)? = admittedScan.map { scan in
        {
          try scan.checkCancellation()
          try self.validateCaptureAuthority()
        }
      }
      // A later spatial operator may require the tiled transport. The proof for this
      // exact source image does not depend on that operator's graph or scratch budget.
      let globalSource = adjustments.rawDecoder == .flashRaw031 && (1...2400).contains(maxPixel) ? texturePin:nil
      let finalMaskValidation: DevelopmentMaskEngineV3.CanonicalValidation? = localMaskValidation.flatMap { request in
        let eligibleFiniteTransport = request.transport.checksPointwiseRegion ? usesResidentValidation : !usesResidentValidation
        guard globalSource != nil, maxPixel == 2400, contextMemoryLimitMiB >= 512,
              eligibleFiniteTransport,
              DevelopmentMaskEngineV3.CanonicalValidation.qualifies(adjustments, extent: based.extent, transport: request.transport) else { return nil }
        guard request.transport != .pairedTiles else { return request }
        guard contextMemoryLimitMiB == 512, ProcessInfo.processInfo.physicalMemory >= 32 * 1024 * 1024 * 1024 else { return nil }
        let verifiedSpatial = request.transport == .spatialTileRegion || request.transport == .groupedFull
          || request.transport == .localNoiseBands
        let compositeRegion = request.transport == .pointwiseCompositeRegion
        if verifiedSpatial || compositeRegion {
          guard verifiedCapture != nil, originalEXIFOrientation == 1, interactiveMetalDevice?.hasUnifiedMemory == true,
                based === globalSource?.image, based.extent == CGRect(origin: .zero, size: nativeSize),
                thumbnailNativeSink == nil, grainFinalTransport == nil, brillianceFinalTransport == nil,
                spatialScan == nil, dehazeGuide == nil, checkDehazeTexture == nil,
                checkCanonicalCache == nil, checkCanonicalHalfFIT == nil else { return nil }
        }
        if compositeRegion {
          guard adjustments.rawDetails == nil, nativeFiniteCheck?.mayCheckTexture == true,
                let device = interactiveMetalDevice, PreviewPortableHalfFIT.supports(nativeSize, device:device),
                hasCanonicalCacheHeadroom(for:based.extent) else { return nil }
        }
        let grouped = verifiedSpatial && adjustments.rawDetails == nil && DevelopmentCheckedMaximumV3.groupedScalarsEnabled &&
          interactiveMetalDevice?.name == "Apple M4 Max" &&
          (nativeSize == CGSize(width:9504,height:6336) || nativeSize == CGSize(width:8640,height:5760)) &&
          (spatialMaskCache || hasCanonicalCacheHeadroom(for:based.extent))
        guard request.transport != .groupedFull || grouped else { return nil }
        if request.transport == .localNoiseBands {
          guard adjustments.rawDetails == nil, let device = interactiveMetalDevice,
                PreviewPortableHalfFIT.supports(nativeSize, device: device),
                hasCanonicalCacheHeadroom(for: based.extent) else { return nil }
        }
        let batching: DevelopmentCheckedMaximumV3.ScalarBatching
        if request.transport == .groupedFull && Self.retainsFullValidationCache {
          batching = .retainForRequest
        } else {
          batching = grouped ? .clearAfterGroup : .disabled
        }
        return .init(transport:request.transport,scalarBatching:batching,checkCancellation:{
          try request.checkCancellation()
          try self.validateCaptureAuthority()
          if grouped || compositeRegion {
            guard globalSource?.isCurrent(for:based) == true else { throw PreviewPresentationError.allocationProtocol }
          }
        })
      }
      let verifiedFiniteRequest = verifiedCapture != nil && originalEXIFOrientation == 1 && maxPixel == 2400 &&
        adjustments.rawDecoder == .flashRaw031 && adjustments.rawDetails == nil && thumbnailNativeSink == nil &&
        based === globalSource?.image ? nativeFiniteCheck : nil
      let checkedHalf: PreviewCanonicalHalfFIT?
      if let checkCanonicalHalfFIT, maxPixel == 2400, !cachesIntermediates, let globalSource,
         dehazeGuide == nil, admittedScan == nil, localMaskValidation == nil,
         grainFinalTransport == nil, thumbnailNativeSink == nil, let device = interactiveMetalDevice {
        if let portableHalfFITRequest, verifiedFiniteRequest?.mayCheckTexture == true,
           (qualifiesPortableHalfFITRecipe(adjustments) ||
             (PreviewPortableMaskTone.enabled && qualifiesPortableMaskHalfFIT(adjustments)) ||
             (PreviewPortableGrading.enabled && qualifiesPortableGradingHalfFIT(adjustments))), based === globalSource.image,
           based.extent == CGRect(origin:.zero,size:nativeSize) {
          let portable = PreviewPortableHalfFIT(pin:globalSource,parameters:adjustments,device:device,request:portableHalfFITRequest,
            maskTone: PreviewPortableMaskTone.enabled ? PreviewPortableMaskTone(adjustments) : nil,
            grading: grading, captureID: verifiedCapture?.id)
          checkedHalf = .init(device:device,bounds:based.extent,portable:portable,checkCancellation:checkCanonicalHalfFIT)
        } else if portableHalfFITRequest == nil, pointwise, qualifiesHalfFITRecipe(adjustments) {
          checkedHalf = .init(device:device,bounds:based.extent,checkCancellation:checkCanonicalHalfFIT)
        } else {
          checkedHalf = nil
        }
      } else {
        checkedHalf = nil
      }
      let checkHalf = checkedHalf.map { request in { try request.requireCurrent() } }
      let checkSpatialTiles = finalMaskValidation?.transport == .spatialTileRegion ? finalMaskValidation?.checkCancellation : nil
      let checkPresentation = checkSpatialScan ?? checkCache
        ?? (finalMaskValidation?.transport == .pairedTiles ? nil : finalMaskValidation?.checkCancellation) ?? checkHalf
      if finalMaskValidation?.transport.checksPointwiseRegion == true { try finalMaskValidation?.checkCancellation() }
      try checkSpatialTiles?()
      let nativeSharpenMean: PreviewNativeSharpenMean?
      if PreviewNativeSharpenMean.enabled, contextMemoryLimitMiB == 512, !cachesIntermediates,
         localMaskValidation == nil, spatialScan == nil, checkDehazeTexture == nil,
         checkCanonicalHalfFIT == nil, grainFinalTransport == nil, dehazeGuide == nil,
         based.extent == CGRect(origin: .zero, size: nativeSize),
         let request = verifiedFiniteRequest, request.mayCheckTexture, let globalSource,
         let plan = PreviewNativeSharpenMean.plan(for: adjustments), let device = interactiveMetalDevice {
        nativeSharpenMean = try PreviewNativeSharpenMean.prepare(plan:plan,pin:globalSource,source:based,context:context,
          device:device,checkAuthority:request.checkAuthority)
      } else {
        nativeSharpenMean = nil
      }
      let renderContext: CIContext
      if finalMaskValidation?.scalarBatching == .retainForRequest {
        options[.cacheIntermediates] = true
        renderContext = CanonicalPreviewDiagnostic.measure("create context for full validation cache") { CIContext(options:options) }
      } else {
        renderContext = context
      }
      defer {
        if renderContext !== context { renderContext.clearCaches() }
      }
      let graph=try DevelopmentCanonicalFiniteGPU.$residentPhotoWorkingBudget.withValue(workingBudget) {
          try DevelopmentRendererV3.develop(capture,recipe:recipe,suppliedRawBase:based,context:renderContext,
            residentGlobalSource:globalSource,localMaskValidation:finalMaskValidation,residentDehazeGuide:dehazeGuide,
            sharpenOutput:sharpenOutput,thumbnailNativeSink:thumbnailNativeSink,
            checkCancellation:checkSpatialScan ?? checkDehazeTexture ?? checkCache ?? checkHalf ?? checkSpatialTiles,
            previewHalfFIT:checkedHalf,nativeFiniteCheck:verifiedFiniteRequest,localSourceValidation:bindingCheck,
            nativeSharpenMean:nativeSharpenMean,nativeNoiseDomain:noiseDomain)
      }
      try checkPresentation?()
      try noiseDomain?.requireCurrent()
      try nativeSharpenMean?.requireCurrent()
      if nativeSharpenMean != nil { context.clearCaches() }
      if dehazeGuide?.usesHalfErosion == true { try dehazeGuide?.check() }
      let result: PreviewPixels
      if let checkDehazeTexture, let dehazeGuide, dehazeGuide.usesSharedTexture {
        try Task.checkCancellation()
        try checkDehazeTexture()
        context.clearCaches()
        try dehazeGuide.requireSharedTextureDisplayCapacity()
        // A 512 MiB display target changes FIT sampling with a shared R32F view on large RAWs.
        // Keep the finite scan in its original context and use the qualified display target only for the joined readback.
        result = try autoreleasepool {
          let display = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
            .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,
            .memoryTarget:DevelopmentResidentDehazeGuide.sharedTextureDisplayMemoryTargetMiB])
          defer { display.clearCaches() }
          return try V3PreviewMaterializer.materialize(graph,context:display,maxPixel:maxPixel,
            window:detailWindow(maxPixel:maxPixel,window:window),grainFinalTransport:grainFinalTransport)
        }
        try Task.checkCancellation()
        try checkDehazeTexture()
      } else {
        let half = try checkedHalf?.takeHalf(for:graph.image) ?? dehazeGuide?.prepareRestoreHalf(for:graph.image,using:context)
        let ownedBitmapAuthority: (() throws -> Void)?
        if V3PreviewMaterializer.writesOwnedBitmap, maxPixel == 2400, verifiedCapture != nil,
           originalEXIFOrientation == 1, contextMemoryLimitMiB == 512, adjustments.geometry == .init(),
           let nativeFiniteCheck, nativeFiniteCheck.mayCheckTexture, let texturePin,
           let device = interactiveMetalDevice, PreviewPortableHalfFIT.supports(nativeSize, device: device) {
          ownedBitmapAuthority = {
            try nativeFiniteCheck.checkAuthority()
            guard texturePin.isCurrent(for: neutral) else { throw PreviewPresentationError.allocationProtocol }
          }
        } else {
          ownedBitmapAuthority = nil
        }
        result = try V3PreviewMaterializer.materialize(graph,context:renderContext,maxPixel:maxPixel,
          window:detailWindow(maxPixel:maxPixel,window:window),
          grainFinalTransport:grainFinalTransport,checkedLinearHalf:half,ownedBitmapAuthority:ownedBitmapAuthority)
      }
      try checkPresentation?()
      try nativeSharpenMean?.requireCurrent()
      try dehazeGuide?.check()
      try validateCaptureAuthority()
      try noiseDomain?.finish(for: graph.image)
      try checkedHalf?.finishMaskRegion()
      // The weak marker cannot prolong the context across a source/transport change.
      // Only a joined request may make this instance available for another render.
      if mayReuse, texturePin != nil {
        try nativeFiniteCheck?.checkAuthority()
        clearedCanonicalContext = sourceContext
      }
      return result
    }
    context.clearCaches()
    context = CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:contextMemoryLimitMiB])
    defer { context.clearCaches() }
    do {
      if let rawBasePool, raw != nil, !artifact, recipe.adjustmentsV3?.aiDenoise == nil {
        if v3DecoderDefaultsFingerprint == nil {
          guard let fresh = CIRAWFilter(imageURL:capture) else { throw DevelopmentError.unreadable }
          v3DecoderDefaultsFingerprint = try? DevelopmentRendererV3.decoderDefaultsFingerprint(fresh)
        }
        if let defaults = v3DecoderDefaultsFingerprint, let cached = try PreviewRawBaseRenderer.renderV3(capture:capture,sourceKey:sourceKey,recipe:recipe,maxPixel:maxPixel,
          pool:rawBasePool,memoryHint:contextMemoryLimitMiB,captureStamp:captureStamp,decoderIdentity:decoder,
          decoderDefaultsFingerprint:defaults,noiseDefaults:.init(luminance:noiseReductionFacts.raw!.defaultLuminanceNoise,
            color:noiseReductionFacts.raw!.defaultColorNoise,detail:noiseReductionFacts.raw!.defaultDetail,
            luminanceSupported:noiseReductionFacts.raw!.luminanceNoiseSupported,colorSupported:noiseReductionFacts.raw!.colorNoiseSupported,
            detailSupported:noiseReductionFacts.raw!.detailSupported),thumbnailNativeSink:thumbnailNativeSink,grainFinalTransport:grainFinalTransport,
            localSourceValidation:bindingCheck) {
          try validateCaptureAuthority(); return cached
        }
      }
      if Self.usesOwnedV1DehazeContexts(recipe,sourceIsRAW:raw != nil && !artifact) {
        // The existing raw-base attempt above retains its admission/cache/pin contract.
        // Only its ordinary canonical fallback separates completed native validation
        // from final display. Both contexts use the original V3 options and graph.
        retireIdleCanonicalContextForIndependentWork()
        let graph = try Self.withOwnedV3Context(memoryLimit:contextMemoryLimitMiB) { validation in
          try DevelopmentRendererV3.develop(capture,recipe:recipe,context:validation,thumbnailNativeSink:thumbnailNativeSink,
                                           localSourceValidation:bindingCheck)
        }
        let result = try Self.withOwnedV3Context(memoryLimit:contextMemoryLimitMiB) { display in
          try V3PreviewMaterializer.materialize(graph,context:display,maxPixel:maxPixel,
            window:detailWindow(maxPixel:maxPixel,window:window),grainFinalTransport:grainFinalTransport)
        }
        try validateCaptureAuthority(); return result
      }
      let graph = try DevelopmentRendererV3.develop(capture,recipe:recipe,context:context,thumbnailNativeSink:thumbnailNativeSink,
                                                   localSourceValidation:bindingCheck)
      let result = try V3PreviewMaterializer.materialize(graph,context:context,maxPixel:maxPixel,
        window:detailWindow(maxPixel:maxPixel,window:window),grainFinalTransport:grainFinalTransport)
      try validateCaptureAuthority(); return result
    } catch {
      if let flashRawCacheSourceKey { FlashRawCanonicalTexturePool.shared.retire(sourceKey:flashRawCacheSourceKey) }
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

  func analyze(_ request: DevelopmentAnalysisRequest, sourceContentID: String, cancellation: DevelopmentAnalysisCancellation? = nil, rawBasePool: PreviewRawBasePool? = nil, sourceKey: String = "", residentObserver: DevelopmentBWSummaryResidentV3.Observer? = nil, analysisImages: DevelopmentAnalysisImageCache? = nil) throws -> DevelopmentAnalysisResult {
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
        dehazeContext:dehaze,cancellation:cancellation,analysisImages:analysisImages,sourceAuthority:{ try self.validateCaptureAuthority() })
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
