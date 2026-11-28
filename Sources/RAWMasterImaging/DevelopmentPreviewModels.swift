import AppKit
import RAWMasterCore

public struct DevelopmentPreviewSessionID: Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public struct PreviewConsumerID: Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
public enum DevelopmentPreviewSource: Sendable {
  case raw(EditingSourceSnapshot)
  case artifact(fileURL: URL, artifact: RenderArtifact)
}
public enum PreviewConsumerRole: String, Sendable { case primary, comparison }
public enum PreviewQuality: String, Sendable { case interactive, settled, detail }
public struct PreviewViewport: Equatable, Sendable {
  public let maxPixel: Int
  /// Visible window in the final canvas, normalized with a top-left origin.
  /// `nil` renders and materializes the whole canvas. A window only narrows the
  /// materialized region; the canonical identity stays the full canvas so overlays,
  /// pickers and geometry mapping keep their existing coordinates.
  public let window: CGRect?
  /// For detail requests only: physical display pixels per canonical pixel, capped at one.
  /// `nil` retains the existing native-pixel materialization contract.
  public let detailScale: CGFloat?
  public init(maxPixel: Int = 2400, window: CGRect? = nil, detailScale: CGFloat? = nil) {
    self.maxPixel = maxPixel
    self.window = window
    self.detailScale = detailScale
  }
}
public enum PreviewInteractiveEvaluation:String,Equatable,Sendable { case canonical,proxyV1,nativePointwiseCertificateV1 }
/// Where a settled (post-gesture) canvas frame is evaluated.
///
/// `canonical` renders the always-native graph and downscales at the last step, so a
/// fit-to-window frame costs the full sensor pixel count. `viewport` evaluates the same
/// operator sequence at the requested viewport resolution and validates those pixels:
/// the frame reports its scale, native pixel identity stays with `detail` and export.
/// See `docs/research/gpu-pipeline-references.md` for the LightFlow/Alcedo precedent.
public enum PreviewSettledTransport: String, Equatable, Sendable { case canonical, viewport }
public struct PreviewApproximationInfo:Equatable,Sendable {
  public let version:String
  public let nativeInputSize,proxyInputSize,canonicalCanvasSize,outputPixelSize:CGSize
  public let nativeToProxyScale:Double
  public init(version:String,nativeInputSize:CGSize,proxyInputSize:CGSize,canonicalCanvasSize:CGSize,outputPixelSize:CGSize,nativeToProxyScale:Double) {
    self.version=version;self.nativeInputSize=nativeInputSize;self.proxyInputSize=proxyInputSize
    self.canonicalCanvasSize=canonicalCanvasSize;self.outputPixelSize=outputPixelSize;self.nativeToProxyScale=nativeToProxyScale
  }
}
public struct PreviewResourcePolicy: Equatable, Sendable {
  /// Transient QA022-only admission; public/default configuration remains disabled.
  public let nativeCanonicalFiniteProof:Bool
  public let nativePointwiseProfile:Bool
  public let interactiveEvaluation:PreviewInteractiveEvaluation
  public let maximumSessions: Int
  public let maximumPendingRequests: Int
  public let bitmapCacheBytes: Int
  public let sourceSnapshotDiskBytes: Int64
  public let contextMemoryLimitMiB: Int
  public let interactiveMaxPixel: Int
  public let comparisonQuiescenceMilliseconds: Int
  public let rawBaseCacheBytes: Int
  /// Default stays `canonical`: every settled frame keeps full native evaluation.
  public let settledTransport: PreviewSettledTransport
  public static let `default` = PreviewResourcePolicy()
  public init(maximumSessions: Int = 2, maximumPendingRequests: Int = 2,
              bitmapCacheBytes: Int = 134_217_728, sourceSnapshotDiskBytes: Int64 = 536_870_912,
              contextMemoryLimitMiB: Int = 512, interactiveMaxPixel: Int = 2400,
              comparisonQuiescenceMilliseconds: Int = 150, rawBaseCacheBytes: Int = 0, interactiveEvaluation:PreviewInteractiveEvaluation = .canonical,nativePointwiseProfile:Bool = false,nativeCanonicalFiniteProof:Bool = false,
              settledTransport: PreviewSettledTransport = .canonical) {
    self.settledTransport=settledTransport
    self.nativeCanonicalFiniteProof=nativeCanonicalFiniteProof
    self.nativePointwiseProfile=nativePointwiseProfile
    self.interactiveEvaluation=interactiveEvaluation
    self.maximumSessions = maximumSessions; self.maximumPendingRequests = maximumPendingRequests
    self.bitmapCacheBytes = bitmapCacheBytes; self.sourceSnapshotDiskBytes = sourceSnapshotDiskBytes
    self.contextMemoryLimitMiB = contextMemoryLimitMiB; self.interactiveMaxPixel = interactiveMaxPixel
    self.comparisonQuiescenceMilliseconds = comparisonQuiescenceMilliseconds
    self.rawBaseCacheBytes = rawBaseCacheBytes
  }
}
public struct PreviewSessionInfo: Sendable {
  /// Independently closeable per-open lease, even when source pixels are shared.
  public let id: DevelopmentPreviewSessionID
  public let sourceIdentity: String
  public let sourceGeneration: UInt64
  public let decoderVersion: String
  public let orientedNativeSize: CGSize
  public let canonicalGesture: PreviewCanonicalGestureCapability?
  /// Bitmap capacity for planning native detail windows. The service checks reuse at render time.
  public let detailBitmapCacheBytes: Int?
  init(id:DevelopmentPreviewSessionID,sourceIdentity:String,sourceGeneration:UInt64,decoderVersion:String,
       orientedNativeSize:CGSize,canonicalGesture:PreviewCanonicalGestureCapability? = nil,detailBitmapCacheBytes:Int? = nil) {
    self.id=id;self.sourceIdentity=sourceIdentity;self.sourceGeneration=sourceGeneration
    self.decoderVersion=decoderVersion;self.orientedNativeSize=orientedNativeSize;self.canonicalGesture=canonicalGesture
    self.detailBitmapCacheBytes=detailBitmapCacheBytes
  }
}
public struct DevelopmentPreviewRequest: Sendable {
  public let sessionID: DevelopmentPreviewSessionID
  public let sourceGeneration: UInt64
  public let consumerID: PreviewConsumerID
  public let role: PreviewConsumerRole
  public let revision: UInt64
  public let recipe: DevelopmentRecipe
  public let quality: PreviewQuality
  public let viewport: PreviewViewport
  public let deliveryPolicy: PreviewDeliveryPolicy
  public let clientCorrelation: Data?
  public init(sessionID: DevelopmentPreviewSessionID, sourceGeneration: UInt64,
              consumerID: PreviewConsumerID, role: PreviewConsumerRole, revision: UInt64,
              recipe: DevelopmentRecipe, quality: PreviewQuality, viewport: PreviewViewport = .init(),
              deliveryPolicy: PreviewDeliveryPolicy = .latestOnly, clientCorrelation: Data? = nil) {
    self.sessionID = sessionID; self.sourceGeneration = sourceGeneration; self.consumerID = consumerID
    self.role = role; self.revision = revision; self.recipe = recipe; self.quality = quality; self.viewport = viewport
    self.deliveryPolicy = deliveryPolicy; self.clientCorrelation = clientCorrelation
  }
}
public struct DevelopmentPreviewFrame: @unchecked Sendable {
  public let frameID: UUID
  public let image: NSImage
  /// Full display pixels for white-box comparisons. The caller owns tightly packed,
  /// top-to-bottom, premultiplied sRGB RGBA8 storage and may reuse it between frames.
  public func copyDisplayRGBA8(into target: UnsafeMutableRawBufferPointer) throws {
    if try PreviewSharedImageBridge.copyRGBA8(from:image,into:target) { return }
    guard let raster = PreviewSharedImageBridge.canvasRaster(for:image) ?? image.cgImage(forProposedRect:nil,context:nil,hints:nil),
          target.count == raster.width*raster.height*4, let bytes = target.baseAddress,
          let bitmap = CGContext(data:bytes,width:raster.width,height:raster.height,bitsPerComponent:8,bytesPerRow:raster.width*4,
              space:PhotoRenderer.sRGB,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DevelopmentError.invalidEncoding }
    bitmap.setBlendMode(.copy)
    bitmap.draw(raster,in:CGRect(x:0,y:0,width:raster.width,height:raster.height))
    bitmap.flush()
  }
  public let sessionID: DevelopmentPreviewSessionID
  public let sourceGeneration: UInt64
  public let consumerID: PreviewConsumerID
  public let revision: UInt64
  public let quality: PreviewQuality
  public let canonicalPixelSize: CGSize
  public let outputPixelSize: CGSize
  public let outputKey: String
  /// Visible window in the canvas, normalized with a top-left origin. `nil` is the whole canvas.
  /// `canonicalPixelSize` always describes the whole canvas, so overlays and pickers keep their
  /// existing normalized coordinates.
  public let window: CGRect?
  public let approximate: Bool
  public let approximation:PreviewApproximationInfo?
  public let brillianceTransportVersion:String?
  public let brillianceMapSHA256:String?
  public let dehazePreviewContract:String?
  public let dehazePreviewFallback:String?
  public let dehazePlaneSHA256:String?
  public init(frameID:UUID,image:NSImage,sessionID:DevelopmentPreviewSessionID,sourceGeneration:UInt64,consumerID:PreviewConsumerID,revision:UInt64,quality:PreviewQuality,canonicalPixelSize:CGSize,outputPixelSize:CGSize,outputKey:String,window:CGRect?=nil,approximate:Bool,approximation:PreviewApproximationInfo?=nil,brillianceTransportVersion:String?=nil,brillianceMapSHA256:String?=nil,dehazePreviewContract:String?=nil,dehazePreviewFallback:String?=nil,dehazePlaneSHA256:String?=nil) {
    self.brillianceTransportVersion=brillianceTransportVersion;self.brillianceMapSHA256=brillianceMapSHA256
    self.dehazePreviewContract=dehazePreviewContract;self.dehazePreviewFallback=dehazePreviewFallback;self.dehazePlaneSHA256=dehazePlaneSHA256
    self.frameID=frameID;self.image=image;self.sessionID=sessionID;self.sourceGeneration=sourceGeneration
    self.consumerID=consumerID;self.revision=revision;self.quality=quality;self.canonicalPixelSize=canonicalPixelSize
    self.outputPixelSize=outputPixelSize;self.outputKey=outputKey;self.window=window;self.approximation=approximation
    self.approximate=approximation != nil
  }
}
public enum DevelopmentPreviewError: Error, Sendable {
  case superseded, closed, sourceInvalidated, capacityExceeded, memoryBudgetExceeded, invalidRequest
}
public struct PreviewStatistics: Sendable {
  /// Fixed scalar diagnostics for the separately opted-in QA profile; no keys/paths/pixels.
  public internal(set) var nativeProfileInteractiveJobs:UInt64=0
  public internal(set) var nativeProfileCanonicalJobs:UInt64=0
  public internal(set) var nativeProfileCanonicalValidatedOutputs:UInt64=0
  public internal(set) var nativeNaturalProvenGlobalOutputs:UInt64=0
  public internal(set) var nativeNaturalProvenBitmapHits:UInt64=0
  public internal(set) var nativeProfileCanonicalProvenGlobalOutputs:UInt64=0
  public internal(set) var nativeProfileCanonicalProvenBitmapHits:UInt64=0
  public internal(set) var nativeProfileSemanticBitmapHits:UInt64=0
  public internal(set) var nativeProfilePreservedInputs:UInt64=0
  public internal(set) var nativeProfileCancelledFrames:UInt64=0
  public internal(set) var nativeProfileLastRoute:Int=0 // 0none/1interactive/2canonical/3semantic-hit/6scanned-bitmap-hit/7proven-canonical/8proven-bitmap-hit/9natural-proof/10natural-replay
  public internal(set) var nativeProfileLastSlotWaitNanoseconds:UInt64=0
  public internal(set) var interactiveProxyCanonicalFallbacks:UInt64=0
  public internal(set) var interactiveProxyLastFallbackReason:String?
  public internal(set) var submittedRequests: UInt64 = 0
  public internal(set) var completedRenders: UInt64 = 0
  public internal(set) var supersededRequests: UInt64 = 0
  public internal(set) var cacheHits: UInt64 = 0
  public internal(set) var sourceCaptures: UInt64 = 0
  public internal(set) var sourceFullHashPasses: UInt64 = 0
  public internal(set) var sourceHashBytes: UInt64 = 0
  public internal(set) var sourceStatChecks: UInt64 = 0
  public internal(set) var activeNativeRenders: Int = 0
  public internal(set) var maximumObservedNativeRenders: Int = 0
  public internal(set) var pendingRequests: Int = 0
  public internal(set) var maximumObservedPendingRequests: Int = 0
  public internal(set) var cachedBitmapBytes: Int = 0
  public internal(set) var rawBaseResidentBytes = 0
  public internal(set) var rawBaseReservedBytes = 0
  public internal(set) var rawBaseBuildingBytes = 0
  public internal(set) var rawBasePinnedBytes = 0
  public internal(set) var rawBaseRetiredBytes = 0
  public internal(set) var rawBaseHits: UInt64 = 0
  public internal(set) var rawBaseFills: UInt64 = 0
  public internal(set) var rawBaseMisses: UInt64 = 0
  public internal(set) var rawBaseEvictions: UInt64 = 0
  public internal(set) var sourceSnapshotDiskBytes: Int64 = 0
  public internal(set) var invalidations: UInt64 = 0
  public internal(set) var evictions: UInt64 = 0
}
