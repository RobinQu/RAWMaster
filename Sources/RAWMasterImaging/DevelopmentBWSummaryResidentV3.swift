import Foundation
import CoreImage
import RAWMasterCore

/// QA-only, resident-only analysis. This never fills, evicts, or silently decodes a missing owner.
enum DevelopmentBWSummaryResidentV3 {
  static let version = "rawmaster-analysis-bw-summary-resident-v3/linear-source-proxy128/global-readback32/full-native-finite"
  struct Identity: Equatable, Sendable {
    let descriptorFingerprint: String
    let owner: UUID
    let certificateVersion: String
  }
  struct Observation: Sendable {
    enum Phase: Equatable, Sendable { case acquired, willPublish, released }
    let samplingVersion = DevelopmentBWSummaryResidentV3.version
    let phase: Phase
    let identity: Identity
    let cacheHit: Bool?
    let before: RawBaseStatisticsSnapshot
    let current: RawBaseStatisticsSnapshot
  }
  typealias Observer = @Sendable (Observation) throws -> Void

  /// Only this helper can create the capability. It holds no owning image reference and
  /// becomes unusable when its scoped, actually joined pin is released.
  final class Input {
    let identity: Identity
    private weak var pin: RawBasePin?
    private var current: (() throws -> Void)?
    private var publication: ((Bool) throws -> Void)?
    fileprivate init(pin: RawBasePin, identity: Identity, current: @escaping () throws -> Void,
                     publication: @escaping (Bool) throws -> Void) {
      self.pin = pin; self.identity = identity; self.current = current; self.publication = publication
    }
    func requireCurrent() throws {
      guard let pin, let certificate = pin.pointwiseInputCertificate,
        pin.ownerIncarnation == identity.owner, certificate.owner == identity.owner,
        certificate.authority == identity.descriptorFingerprint, certificate.eligible,
        let current else { throw DevelopmentPreviewError.sourceInvalidated }
      try Task.checkCancellation(); try current()
    }
    func image() throws -> CIImage { try requireCurrent(); return try pin!.image }
    func willPublish(cacheHit: Bool) throws { try requireCurrent(); try publication?(cacheHit); try requireCurrent() }
    fileprivate func invalidate() { pin = nil; current = nil; publication = nil }
  }

  static func requireRequest(_ request: DevelopmentAnalysisRequest, sourceIsRAW: Bool, artifact: Bool = false) throws {
    try request.validate()
    guard request.sampling == .blackAndWhiteSummaryResident32V3, request.preview.role == .primary,
      sourceIsRAW, !artifact, request.localInputV1 == nil, request.dehazeInputV1 == nil,
      request.cropAutoInputV1 == nil else { throw DevelopmentV3Error.unsupportedAnalysis }
    let sampling = try DevelopmentAnalysisEngine.samplingRecipe(request)
    guard let p = sampling.adjustmentsV3,
      let legacy = try DevelopmentRendererV3.legacyEquivalent(sampling), legacy == DevelopmentRecipe(),
      DevelopmentRendererV3.ownsAnalysisLegacyValidationContext(requested: true, sourceIsRAW: true,
        applyGeometry: false, parameters: p, legacy: legacy) else { throw DevelopmentV3Error.unsupportedAnalysis }
  }

  static func withResident(native: PreviewNativeSource, request: DevelopmentAnalysisRequest,
                           sourceKey: String, contentID: String, pool: PreviewRawBasePool,
                           cancellation: DevelopmentAnalysisCancellation?, observer: Observer?,
                           body: (Input) throws -> Void) throws {
    try requireRequest(request, sourceIsRAW: native.hasRAWFilter, artifact: native.artifact)
    try native.validateCaptureAuthority(); try cancellation?.check()
    let descriptor = try PreviewNativePointwiseBaseV1.descriptor(native, sourceKey: sourceKey,
      generation: request.preview.sourceGeneration, verifiedContentID: contentID)
    try withVerifiedResident(descriptor: descriptor, pool: pool, check: {
      try native.validateCaptureAuthority(); try cancellation?.check()
    }, observer: observer, body: body)
  }

  /// Also exercised by bounded real-owner tests. Descriptor construction is not replaced
  /// in the public Service path; its caller above derives every field from the live capture.
  static func withVerifiedResident(descriptor: PreviewNativePointwiseBaseDescriptorV1,
      pool: PreviewRawBasePool, check: @escaping () throws -> Void, observer: Observer? = nil,
      body: (Input) throws -> Void) throws {
    try Task.checkCancellation(); try check()
    let before = pool.statistics
    guard let pin = pool.acquirePointwiseResident(descriptor) else { throw DevelopmentV3Error.unsupportedAnalysis }
    // This defer is installed before any certificate rejection or observer callback.
    defer { pin.releaseAfterJoinedPipeline() }
    let authority = try descriptor.fingerprint()
    let (pixelCount, overflow) = descriptor.width.multipliedReportingOverflow(by: descriptor.height)
    guard let owner = pin.ownerIncarnation, let certificate = pin.pointwiseInputCertificate,
      certificate.eligible, certificate.owner == owner, certificate.authority == authority,
      descriptor.width > 0, descriptor.height > 0,
      !overflow, certificate.pixels == pixelCount,
      certificate.maximumAbsoluteRGB.isFinite, certificate.maximumAbsoluteRGB <= PreviewNativePointwiseCertificateV1.bound
      else { throw DevelopmentV3Error.unsupportedAnalysis }
    let identity = Identity(descriptorFingerprint: authority, owner: owner,
      certificateVersion: PreviewNativePointwiseCertificateV1.version)
    let input = Input(pin: pin, identity: identity, current: check, publication: { hit in
      try observer?(.init(phase: .willPublish, identity: identity, cacheHit: hit, before: before, current: pool.statistics))
    })
    let outcome = Result { try autoreleasepool {
      try input.requireCurrent()
      try observer?(.init(phase: .acquired, identity: identity, cacheHit: nil, before: before, current: pool.statistics))
      try input.requireCurrent(); try body(input); try input.requireCurrent()
    } }
    // All synchronous CI work and its autorelease pool have actually returned. Do not
    // evict the retained owner: the next interactive request must reuse the same allocation.
    input.invalidate(); pin.releaseAfterJoinedPipeline()
    let releaseObservation = Result { try observer?(.init(phase: .released, identity: identity,
      cacheHit: nil, before: before, current: pool.statistics)) }
    try outcome.get(); _ = try releaseObservation.get()
  }
}
