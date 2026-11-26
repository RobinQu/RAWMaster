import AppKit
import CryptoKit
import CoreImage
import Metal
import Darwin
import RAWMasterCore
import RAWMasterLibrary

/// Process-wide preview coordinator. Native GPU work shares admission with export and library work.
public actor DevelopmentPreviewService: ImageEngineMonitoring {
  public static let shared = DevelopmentPreviewService()
  private struct Lease {
    var key: String
    var source: DevelopmentPreviewSource
    var stamp: PreviewFileStamp
    var generation: UInt64
    var valid: Bool
    var watcher: DispatchSourceFileSystemObject?
  }
  private struct SourceRecord { let native: PreviewNativeSource; var leases: Set<DevelopmentPreviewSessionID> }
  private struct Pending {
    let token: UUID
    let request: DevelopmentPreviewRequest
    let key: String
    let outputKey: String
    var continuation: CheckedContinuation<DevelopmentPreviewFrame, Error>?
    var channelID: PreviewProgressChannelID? = nil
    var deliveryEnabled = true
    var sequence: UInt64 = 0
    var queuedAt:UInt64 = 0
    var nativePointwisePlan:PreviewNativePointwisePlanV1? = nil
    var interactivePlan:PreviewInteractivePlan? = nil
    let interactiveCancellation=DevelopmentAnalysisCancellation()
    var work: PreviewSubmittedWork { .init(id: .init(rawValue: token), request: request) }
  }
  private struct PendingAnalysis: Sendable {
    let cancellation=DevelopmentAnalysisCancellation()
    let token: UUID
    let request: DevelopmentAnalysisRequest
    let key: String
    let sourceContentID: String
    let sequence: UInt64
    let queuedAt: UInt64 // Background-histogram quiet window; user analysis never consults this value.
    var continuation: CheckedContinuation<DevelopmentAnalysisResult,Error>?
    var deliveryEnabled = true
  }
  private var thumbnailWanted:Set<DevelopmentThumbnailRegistration>=[]
  private let thumbnailLedger=ThumbnailLedger()
  private let thumbnailContextOwner=ThumbnailWorkerContextV1()
  private var thumbnailContextRetirementRequested=false
  private var thumbnailContextMaintenance:Task<Void,Never>?
  /// Only scalar state; no CI wrapper or borrowed graph escapes the native owner.
  func thumbnailContextSnapshotForTesting()->ThumbnailWorkerContextV1.Snapshot {thumbnailContextOwner.snapshot}
  func joinThumbnailContextRetirementForTesting()async {await joinThumbnailContextRetirement()}
  private func requestThumbnailContextRetirement(){thumbnailContextRetirementRequested=true;pump()}
  /// Admission fence is shared by primary render (including its settled hook), analysis and tiles.
  private func startThumbnailContextMaintenanceIfNeeded()->Bool {
    if thumbnailContextMaintenance != nil{return true}
    guard thumbnailContextRetirementRequested else{return false}
    guard worker==nil else{return true}
    thumbnailContextRetirementRequested=false
    let owner=thumbnailContextOwner
    thumbnailContextMaintenance=Task {
      await Task.detached(priority:.utility){owner.retire()}.value
      self.thumbnailContextMaintenance=nil
      self.pump()
    }
    return true
  }
  private func joinThumbnailContextRetirement()async {
    thumbnailContextRetirementRequested=true
    while true {
      if let running=worker{await running.value;continue}
      _=startThumbnailContextMaintenanceIfNeeded()
      if let maintenance=thumbnailContextMaintenance{await maintenance.value;continue}
      if !thumbnailContextRetirementRequested{return}
    }
  }
  private var thumbnailPending:ThumbnailBatch?
  private var thumbnailActive:ThumbnailBatch?
  private var thumbnailStepRegistration:DevelopmentThumbnailRegistration?
  private var thumbnailProxy:(key:String,value:ThumbnailProxy)?
  private var thumbnailProxyScope:(session:DevelopmentPreviewSessionID,consumer:PreviewConsumerID)?
  private var thumbnailRetirements:[UUID:(request:DevelopmentThumbnailRequest,token:UUID,task:Task<Void,Never>)]=[:]
  private var thumbnailSets:[UUID:(owner:ThumbnailSetOwner,request:DevelopmentThumbnailRequest)]=[:]
  private var thumbnailStats=DevelopmentThumbnailStatistics()
  private var thumbnailSettled:[PreviewConsumerID:DevelopmentPreviewRequest]=[:]
  private var userAnalysis: PendingAnalysis?
  private var backgroundHistogram: PendingAnalysis?
  private var activeAnalysis: PendingAnalysis?
  private var analysisStats = DevelopmentAnalysisStatistics()
  private var schedulingSequence: UInt64 = 0
  private var consecutiveInteractive = 0
  private var latestRecipeFingerprint: [PreviewConsumerID:String] = [:]
  private struct Cached { let pixels: PreviewPixels; let sourceKey: String; let settledRecipeFingerprint: String?; var use: UInt64;var nativeProfileSemantic=false }
  private let ioQueue = DispatchQueue(label: "RAWMaster.preview.capture", qos: .userInitiated)
  private static let qaCanonicalRequestCache = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_REQUEST_CACHE"] == "1"
  private static let qaCanonicalHalfFIT = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_HALF_FIT"] == "1"
  private enum CanonicalHalfFIT: String {
    case coreImage = "qa-native-half-fit-v1"
    case portable = "qa-portable-point-half-fit-v1"
    case frozenMask = "qa-portable-frozen-mask-half-fit-v1"
    case grading = "qa-portable-grading-half-fit-v1"
  }
  private var policy = PreviewResourcePolicy.default
  private var rawBasePool: PreviewRawBasePool?
  private let analysisImages = DevelopmentAnalysisImageCache()
  private var rawBaseRetiring: Set<String> = []
  private var rawBaseClearRequested = false
  private var rawBaseStatsVersion: UInt64 = 0
  private var rawBasePumpWaiting = false
  private var rawBaseInvalidationFlush: Task<Void, Never>?
  private var rawBaseMaintenance: (id: UUID, task: Task<RawBaseStatisticsSnapshot, Never>)?
  private var sources: [String: SourceRecord] = [:]
  private var opening: [String: Task<(PreviewNativeSource, PreviewFileStamp), Error>] = [:]
  private var openingIDs: [String: UUID] = [:]
  private var openingReusableCaptureIDs: [String: UUID] = [:]
  private struct CaptureRetirement {
    let captureID: UUID
    let leases: Set<DevelopmentPreviewSessionID>
    let task: Task<Void, Never>
  }
  private var captureRetirements: [String: CaptureRetirement] = [:]
  private var leases: [DevelopmentPreviewSessionID: Lease] = [:]
  private var generation: UInt64 = 0
  private var pending: [Pending] = []
  /// One idle warm-up of the canonical 1:1 texture per source generation.
  private var detailPrewarmDone: [String: UInt64] = [:]
  private var active: Pending?
  private var worker: Task<Void, Never>?
  // Keep exact analysis identity through finishAnalysis's flushing tail, after activeAnalysis is cleared.
  private var analysisWorkerIdentity: (token: UUID, request: DevelopmentAnalysisRequest)?
  private var cache: [String: Cached] = [:]
  private static let replaysExactDisplay = ProcessInfo.processInfo.environment["RAWMASTER_INTERACTIVE_EXACT_REPLAY"] != "0"
  private var tick: UInt64 = 0
  private var stats = PreviewStatistics()
  private var latest: [PreviewConsumerID: (DevelopmentPreviewSessionID, UInt64, UInt64)] = [:]
  private var primaryInteractiveAt: UInt64 = 0
  private var comparisonOwed = false
  private var owedScope: (PreviewConsumerID, UInt64, UInt64)?
  private var channels: [PreviewProgressChannelID: PreviewProgressMailbox] = [:]
  private var draining: [PreviewConsumerID: Task<Void, Never>] = [:]
  private var quietWake: Task<Void, Never>?
  private var quietWakeID: UUID?
  private var pressure: DispatchSourceMemoryPressure?
  private let interactiveProxyPool=PreviewInteractiveProxyPool()
  private let portableMetalPrograms = PreviewPortableMetalPrograms()
  private func qaLifecycle(_ kind:PreviewQALifecycleTrace.Kind,_ phase:PreviewQALifecycleTrace.Phase,id:UUID,
                           request:DevelopmentPreviewRequest?,sourceID:UUID?,raw:RawBaseStatisticsSnapshot?=nil,
                           receipt:PreviewNativePointwiseReceiptV1?=nil,frameID:UUID?=nil,ipEmitNS:UInt64?=nil,
                           sharedFITRequested:Bool?=nil,bitmapReplay:Bool=false,grainFinalTransport:String?=nil,presentationTicketID:UUID?=nil,thumbnailStep:PreviewQALifecycleTrace.ThumbnailStep?=nil) {
    guard PreviewQALifecycleTrace.isEnabled else{return}
    PreviewQALifecycleTrace.record(kind,phase,id:id,request:request,sourceID:sourceID,raw:raw,
      stats:statistics(),thumbnails:thumbnailStatistics(),receipt:receipt,frameID:frameID,ipEmitNS:ipEmitNS,sharedFITRequested:sharedFITRequested,bitmapReplay:bitmapReplay,grainFinalTransport:grainFinalTransport,presentationTicketID:presentationTicketID,thumbnailStep:thumbnailStep)
  }
  private var nativePointwiseLastReceipt:PreviewNativePointwiseReceiptV1?
  private var interactivePresentation:PreviewPresentationScope?
  private var clearAfterJoin = false
  private var criticalPressure = false
  private let now: @Sendable () -> UInt64
  private let revalidationLeaseOpened: @Sendable () async -> Void
  private let qaNaturalCurveFiniteProof:Bool
  private let qaSharedFITIntermediate: Bool
  private let qaCanonicalGesture: Bool
  private let qaNeutralOwnerBootstrap: Bool
  private let qaNeutralPretransportObserverForTesting:(@Sendable(PreviewPixels)throws->Void)?
  private let qaBWSummaryResident: Bool
  private let qaBWSummaryObserverForTesting: DevelopmentBWSummaryResidentV3.Observer?
  private let qaBrilliancePublicV1:Bool
  private let qaDehazeTIFFPreview:Bool
  private let qaDehazeTIFFObserverForTesting:((DevelopmentDehazeTIFFPreviewV1.Phase)throws->Void)?
  private let grainFinalTransportEnabled: Bool
  private let captureAuthorityForTesting: Bool
  private let filterResourcesForTesting:DevelopmentPhotoFilterResourceStore?
  private let thumbnailStepWillBeginForTesting:(@Sendable()throws->Void)?
  enum ThumbnailCancellationPhaseForTesting: Sendable { case gateRevoked, actorRevocationReturned }
  private let thumbnailCancellationGateRevokedForTesting:(@Sendable(ThumbnailCancellationPhaseForTesting)async->Void)?
  private let analysisOverride: (@Sendable (DevelopmentAnalysisRequest,DevelopmentLocalEditSourceBinding) throws -> DevelopmentAnalysisResult)?
  private let renderOverride: (@Sendable (DevelopmentRecipe, Int) throws -> PreviewPixels)?
  private init() {
    qaBWSummaryResident=false;qaBWSummaryObserverForTesting=nil
    qaDehazeTIFFPreview=DevelopmentDehazeTIFFPreviewV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    qaDehazeTIFFObserverForTesting=nil
    qaBrilliancePublicV1=DevelopmentBrilliancePublicV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    qaCanonicalGesture=PreviewCanonicalGestureCapability.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    qaNeutralPretransportObserverForTesting=nil
    qaNeutralOwnerBootstrap=PreviewNeutralOwnerBootstrapV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    grainFinalTransportEnabled=PreviewGrainFinalTransportV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    qaNaturalCurveFiniteProof=PreviewNaturalCurveFiniteEvidenceV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    qaSharedFITIntermediate = PreviewNativeInputProfileV1.sharedFITBootstrap(
      bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)
    captureAuthorityForTesting = false
    interactivePresentation=nil
    filterResourcesForTesting = nil
    renderOverride = nil; analysisOverride = nil; thumbnailStepWillBeginForTesting=nil
    thumbnailCancellationGateRevokedForTesting=nil
    now = { DispatchTime.now().uptimeNanoseconds }
    revalidationLeaseOpened = {}
    let qa=PreviewNativeInputProfileV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,
      environment:ProcessInfo.processInfo.environment)
    let bytes = qa ? 1_073_741_824:DevelopmentPreviewApplicationCacheProfile.currentSharedBytes()
    policy = PreviewResourcePolicy(rawBaseCacheBytes:bytes,
      interactiveEvaluation:qa ? .nativePointwiseCertificateV1:.proxyV1,nativePointwiseProfile:qa,
      nativeCanonicalFiniteProof:PreviewCanonicalFiniteEvidenceV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment),
      settledTransport:.viewport)
    // Interactive gestures and the settled canvas frame both use the viewport-resolution
    // graph; only `detail` (1:1), save and export evaluate at native resolution.
    // Unsupported operators still fail closed to the canonical native renderer.
    interactivePresentation = PreviewPresentationScope()
    rawBasePool = bytes > 0 ? PreviewRawBasePool(byteBudget: bytes, nativeFillMode: .whole) : nil
  }
  /// Isolated deterministic backend for scheduler tests; unavailable to product callers.
  init(policy: PreviewResourcePolicy = .default, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, revalidationLeaseOpened: @escaping @Sendable () async -> Void = {}, rawBasePoolForTesting: PreviewRawBasePool? = nil, captureAuthorityForTesting: Bool = false, analysisOverride: (@Sendable (DevelopmentAnalysisRequest,DevelopmentLocalEditSourceBinding) throws -> DevelopmentAnalysisResult)? = nil, renderOverride: (@Sendable (DevelopmentRecipe, Int) throws -> PreviewPixels)? = nil, thumbnailStepWillBeginForTesting:(@Sendable()throws->Void)? = nil, thumbnailCancellationGateRevokedForTesting:(@Sendable(ThumbnailCancellationPhaseForTesting)async->Void)? = nil, filterResourcesForTesting:DevelopmentPhotoFilterResourceStore? = nil, qaSharedFITIntermediate:Bool = false,qaNaturalCurveFiniteProof:Bool = false,qaGrainFinalTransport:Bool = false,qaNeutralOwnerBootstrap:Bool = false,qaBrilliancePublicV1:Bool = false,qaCanonicalGesture:Bool = false,qaNeutralPretransportObserverForTesting:(@Sendable(PreviewPixels)throws->Void)? = nil,qaBWSummaryResident:Bool = false,qaBWSummaryObserverForTesting:DevelopmentBWSummaryResidentV3.Observer? = nil,qaDehazeTIFFPreview:Bool=false,qaDehazeTIFFObserverForTesting:((DevelopmentDehazeTIFFPreviewV1.Phase)throws->Void)?=nil) {
    self.qaBWSummaryResident=qaBWSummaryResident;self.qaBWSummaryObserverForTesting=qaBWSummaryObserverForTesting
    self.qaBrilliancePublicV1=qaBrilliancePublicV1
    self.qaDehazeTIFFPreview=qaDehazeTIFFPreview;self.qaDehazeTIFFObserverForTesting=qaDehazeTIFFObserverForTesting
    self.qaCanonicalGesture=qaCanonicalGesture
    self.qaNeutralOwnerBootstrap=qaNeutralOwnerBootstrap
    self.qaNeutralPretransportObserverForTesting=qaNeutralPretransportObserverForTesting
    self.grainFinalTransportEnabled=qaGrainFinalTransport
    self.qaNaturalCurveFiniteProof=qaNaturalCurveFiniteProof
    self.qaSharedFITIntermediate=qaSharedFITIntermediate
    self.interactivePresentation=(policy.interactiveEvaluation != .canonical || grainFinalTransportEnabled || qaBrilliancePublicV1 || qaDehazeTIFFPreview) ? PreviewPresentationScope():nil
    self.filterResourcesForTesting = filterResourcesForTesting
    self.captureAuthorityForTesting = captureAuthorityForTesting; self.analysisOverride = analysisOverride; self.thumbnailStepWillBeginForTesting=thumbnailStepWillBeginForTesting
    self.thumbnailCancellationGateRevokedForTesting=thumbnailCancellationGateRevokedForTesting
    self.rawBasePool = rawBasePoolForTesting ?? (policy.rawBaseCacheBytes > 0 ? PreviewRawBasePool(byteBudget:policy.rawBaseCacheBytes):nil)
    self.policy = policy; self.renderOverride = renderOverride; self.now = now; self.revalidationLeaseOpened = revalidationLeaseOpened
  }
  public func configure(policy: PreviewResourcePolicy) async throws {
    guard leases.isEmpty, sources.isEmpty, opening.isEmpty, captureRetirements.isEmpty, worker == nil, thumbnailContextMaintenance == nil, !thumbnailContextRetirementRequested, thumbnailContextOwner.snapshot.reservedBytes==0, thumbnailActive == nil, thumbnailPending == nil, thumbnailSets.isEmpty, rawBaseMaintenance == nil, userAnalysis == nil, backgroundHistogram == nil, activeAnalysis == nil else { throw DevelopmentPreviewError.capacityExceeded }
    guard policy.maximumSessions > 0, policy.maximumSessions <= 2, (1...2).contains(policy.maximumPendingRequests),
      policy.bitmapCacheBytes >= 0, policy.sourceSnapshotDiskBytes > 0, policy.contextMemoryLimitMiB > 0,
      policy.interactiveMaxPixel == 2400, policy.comparisonQuiescenceMilliseconds >= 0,
      (0...1_073_741_824).contains(policy.rawBaseCacheBytes) else { throw DevelopmentPreviewError.invalidRequest }
    guard !policy.nativePointwiseProfile || (policy.interactiveEvaluation == .nativePointwiseCertificateV1 &&
      policy.rawBaseCacheBytes==1_073_741_824 && policy.contextMemoryLimitMiB==512) else { throw DevelopmentPreviewError.invalidRequest }
    guard !policy.nativeCanonicalFiniteProof || (policy.nativePointwiseProfile &&
      PreviewCanonicalFiniteEvidenceV1.bootstrap(bundleIdentifier:Bundle.main.bundleIdentifier,environment:ProcessInfo.processInfo.environment)) else {throw DevelopmentPreviewError.invalidRequest}
    self.rawBasePool = policy.rawBaseCacheBytes > 0 ? PreviewRawBasePool(byteBudget:policy.rawBaseCacheBytes):nil
    self.rawBaseStatsVersion = 0
    interactiveProxyPool.retire();interactivePresentation?.closeAndRetire()
    portableMetalPrograms.removeAll()
    interactivePresentation=(policy.interactiveEvaluation != .canonical || grainFinalTransportEnabled || qaBrilliancePublicV1 || qaDehazeTIFFPreview) ? PreviewPresentationScope():nil
    self.policy = policy
  }
  public func open(source: DevelopmentPreviewSource) async throws -> PreviewSessionInfo {
    try Task.checkCancellation(); guard !terminated else { throw DevelopmentPreviewError.closed }; installPressureMonitor()
    guard !criticalPressure else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let description = try describe(source), key = description.key
    if let retirement = captureRetirements[key] {
      await retirement.task.value
      return try await open(source: source)
    }
    if sources[key] != nil {
      do { try checkCaptureAuthority(key) }
      catch {
        if let retirement = captureRetirements[key] { await retirement.task.value; return try await open(source: source) }
        throw error
      }
    }
    let stamp = try PreviewFileStamp.read(description.snapshot.sourceLocation)
    if let record = sources[key], leases.values.contains(where: { $0.key == key && $0.valid && $0.stamp == stamp && location($0.source) == description.snapshot.sourceLocation }) {
      return addLease(source: source, key: key, stamp: stamp, native: record.native)
    }
    let task: Task<(PreviewNativeSource, PreviewFileStamp), Error>
    let operationID: UUID
    let reusableCaptureID: UUID?
    if let existing = opening[key] {
      if openingLocations[key] != description.snapshot.sourceLocation {
        _ = try await existing.value
        return try await open(source: source)
      }
      task = existing
      guard let id = openingIDs[key] else { throw DevelopmentPreviewError.sourceInvalidated }
      operationID = id; reusableCaptureID = openingReusableCaptureIDs[key]
    }
    else {
      guard sources[key] != nil || sources.count + opening.keys.filter({ sources[$0] == nil }).count < policy.maximumSessions else { throw DevelopmentPreviewError.capacityExceeded }
      let reserved = stats.sourceSnapshotDiskBytes + opening.keys.filter({ sources[$0] == nil }).reduce(Int64(0)) { $0 + (openingSizes[$1] ?? 0) }
      guard sources[key] != nil || description.snapshot.byteCount <= policy.sourceSnapshotDiskBytes - reserved else { throw DevelopmentPreviewError.memoryBudgetExceeded }
      let queue = ioQueue, snapshot = description.snapshot, isArtifact = description.artifact, memory = policy.contextMemoryLimitMiB
      let reusable = sources[key]?.native
      operationID = UUID(); reusableCaptureID = reusable?.captureID
      task = Task {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            let telemetry = ImagePerformanceTelemetry.shared
            let token = telemetry.begin(operation: "打开原片", stage: "校验与捕获", queue: "原片读取")
            var outcome = ImagePerformanceOutcome.failed
            defer { telemetry.end(token, outcome: outcome, byteCount: Int(clamping: snapshot.byteCount)) }
            do {
              let result = try autoreleasepool { () throws -> (PreviewNativeSource, PreviewFileStamp) in
                let before = try PreviewFileStamp.read(snapshot.sourceLocation)
                if let reusable {
                  try RenderFiles.verify(snapshot)
                  let after = try PreviewFileStamp.read(snapshot.sourceLocation)
                  guard before == after else { throw DevelopmentPreviewError.sourceInvalidated }
                  return (reusable, after)
                }
                // capture hashes the complete copied bytes once, with bounded autorelease chunks.
                let verifyRAW = !isArtifact && PhotoRenderer.rawExtensions.contains(snapshot.sourceLocation.pathExtension.lowercased())
                  && DevelopmentResidentDehazeGuide.canVerifyCapture(memoryLimit: memory)
                let verified = verifyRAW ? try RenderFiles.verifiedPreviewCapture(snapshot) : nil
                let captured = try verified?.url ?? RenderFiles.capture(snapshot)
                do {
                  let after = try PreviewFileStamp.read(snapshot.sourceLocation)
                  guard before == after else { throw DevelopmentPreviewError.sourceInvalidated }
                  if let verified { return (try PreviewNativeSource.openVerifiedRAW(verified, memoryLimit: memory), after) }
                  try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: captured.path)
                  return (try PreviewNativeSource(capture: captured, byteCount: snapshot.byteCount, artifact: isArtifact, memoryLimit: memory), after)
                } catch { try? FileManager.default.removeItem(at: captured.deletingLastPathComponent()); throw error }
              }
              outcome = .succeeded
              continuation.resume(returning: result)
            } catch { continuation.resume(throwing: error) }
          }
        }
      }
      opening[key] = task; openingIDs[key] = operationID; openingReusableCaptureIDs[key] = reusableCaptureID
      openingSizes[key] = snapshot.byteCount; openingLocations[key] = snapshot.sourceLocation
    }
    openingWaiters[key, default: 0] += 1
    defer { openingWaiters[key, default: 1] -= 1; cleanupSource(key) }
    let result: (PreviewNativeSource, PreviewFileStamp)
    do { result = try await task.value }
    catch {
      if openingIDs[key] == operationID { removeOpening(key) }
      throw error
    }
    // A faulted/replaced reusable result must never install itself as a new source record.
    if let reusableCaptureID {
      guard captureRetirements[key] == nil, sources[key]?.native.captureID == reusableCaptureID else { throw DevelopmentPreviewError.sourceInvalidated }
    }
    if let currentID = openingIDs[key], currentID != operationID { throw DevelopmentPreviewError.sourceInvalidated }
    if openingIDs[key] == operationID {
      removeOpening(key)
      if sources[key] == nil { stats.sourceCaptures += 1 }; stats.sourceFullHashPasses += 1; stats.sourceHashBytes += UInt64(description.snapshot.byteCount)
      if sources[key] == nil {
        sources[key] = SourceRecord(native: result.0, leases: [])
        stats.sourceSnapshotDiskBytes += result.0.byteCount
      } else if sources[key]?.native.capture != result.0.capture { try? FileManager.default.removeItem(at: result.0.capture.deletingLastPathComponent()) }
    }
    guard let record = sources[key] else { throw DevelopmentPreviewError.closed }
    guard record.native.captureID == result.0.captureID, captureRetirements[key] == nil else { throw DevelopmentPreviewError.sourceInvalidated }
    try checkCaptureAuthority(key)
    // A cancelled open still owns no lease; discard an otherwise unleased capture.
    if terminated { throw DevelopmentPreviewError.closed }
    if Task.isCancelled { throw CancellationError() }
    return addLease(source: source, key: key, stamp: result.1, native: record.native)
  }
  private var terminated = false
  private var openingLocations: [String: URL] = [:]
  private var openingWaiters: [String: Int] = [:]
  private var openingSizes: [String: Int64] = [:]
  private func addLease(source: DevelopmentPreviewSource, key: String, stamp: PreviewFileStamp, native: PreviewNativeSource,
                        id: DevelopmentPreviewSessionID = .init()) -> PreviewSessionInfo {
    generation &+= 1
    leases[id] = Lease(key: key, source: source, stamp: stamp, generation: generation, valid: true, watcher: nil)
    sources[key]?.leases.insert(id)
    attachWatcher(id)
    // Metadata-only policy at the existing lease boundary. Reconfiguration requires all leases closed.
    let gesture:PreviewCanonicalGestureCapability?
    if qaCanonicalGesture,policy.nativePointwiseProfile,policy.nativeCanonicalFiniteProof,
      policy.interactiveEvaluation == .nativePointwiseCertificateV1,policy.contextMemoryLimitMiB == 512,
      renderOverride == nil,case .raw(let snapshot)=source {
      gesture=try? PreviewCanonicalGestureCapability.admitted(native:native,sessionID:id,generation:generation,
        sourceKey:key,verifiedContentID:snapshot.contentSHA256)
    }else{gesture=nil}
    return PreviewSessionInfo(id: id, sourceIdentity: key, sourceGeneration: generation, decoderVersion: native.decoder,
      orientedNativeSize: native.nativeSize,canonicalGesture:gesture)
  }
  /// Immutable construction-time metadata from this already admitted lease. No decode, analysis,
  /// new capture, or native worker is started, and no mutable CIRAWFilter getter is read here.
  public func sourceFacts(sessionID: DevelopmentPreviewSessionID, sourceGeneration: UInt64) throws -> DevelopmentSourceFacts {
    try Task.checkCancellation()
    guard !terminated, let lease = leases[sessionID] else { throw DevelopmentPreviewError.closed }
    guard lease.valid, lease.generation == sourceGeneration, let record = sources[lease.key],
      captureRetirements[lease.key] == nil else { throw DevelopmentPreviewError.sourceInvalidated }
    try checkStamp(sessionID)
    do { try record.native.validateCaptureAuthority() }
    catch {
      beginCaptureFault(key:lease.key,captureID:record.native.captureID)
      throw DevelopmentPreviewError.sourceInvalidated
    }
    let native = record.native
    let description = try describe(lease.source)
    guard native.nativeSize.width.isFinite, native.nativeSize.height.isFinite,
      native.nativeSize.width >= 1, native.nativeSize.height >= 1,
      native.nativeSize.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension),
      native.nativeSize.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentV3Error.invalidGraph }
    let binding = DevelopmentLocalEditSourceBinding(sourceContentID:description.snapshot.contentSHA256,
      exifOrientation:native.originalEXIFOrientation,orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height))
    try binding.validate()
    if let raw = native.noiseReductionFacts.raw {
      guard [raw.defaultLuminanceNoise,raw.defaultColorNoise,raw.defaultDetail].allSatisfy(\.isFinite) else {
        throw DevelopmentV3Error.unsupportedNativeParameters
      }
    }
    if let wb = native.asShotWhiteBalance {
      guard wb.temperature.isFinite, wb.tint.isFinite else { throw DevelopmentV3Error.unsupportedNativeParameters }
    }
    var implemented: Set<DevelopmentAdjustmentID> = [.light,.color,.blackAndWhite,.curves,.levels,.whiteBalance,.definition,.selectiveColor,.noiseReduction,.sharpen,.vignette,.retouch,.redEye,.texture,.clarity,.dehaze,.optics]
    var automatic: Set<DevelopmentAdjustmentID> = [.light,.color,.blackAndWhite,.curves,.levels,.whiteBalance,.definition,.noiseReduction,.sharpen,.vignette]
    if let raw = native.noiseReductionFacts.raw, !raw.luminanceNoiseSupported && !raw.colorNoiseSupported && !raw.detailSupported {
      implemented.remove(.noiseReduction); automatic.remove(.noiseReduction)
    }
    let photoFilters = native.photoFilterCapabilities
    if photoFilters.filters.count>1 { implemented.insert(.filter) }
    let wb = native.artifact ? nil:try DevelopmentWhiteBalanceEngineV3.initialState(source:binding,rawDefault:native.asShotWhiteBalance)
    return DevelopmentSourceFacts(sourceBinding:binding,sourceGeneration:lease.generation,
      sourceKind:native.artifact ? .generatedArtifact:(native.hasRAWFilter ? .raw:.image),decoderVersion:native.decoder,
      noiseReduction:native.noiseReductionFacts,asShotWhiteBalance:native.asShotWhiteBalance,
      implementedAdjustments:native.artifact ? []:implemented,automaticAdjustments:native.artifact ? []:automatic,
      initialWhiteBalanceState:wb,supportedGeometryVersions:native.artifact ? []:[.legacyV1,.legacyV2,.adjustV3,.projectiveV3_1],
      localDecoderContractFingerprint:native.artifact ? nil:native.localDecoderContractFingerprint,
      localCapabilities:native.artifact ? []:[.manualRetouch,.automaticDonor,.manualRedEye,.automaticRedEye],
      dehazeContextV1:native.artifact ? nil:try admittedDehazeContext(native,key:lease.key,source:binding,generation:lease.generation),
      supportedPhotoFilters:photoFilters.filters,photoFilterResourceVersion:photoFilters.resourceVersion,
      supportsCropAutomatic:!native.artifact && min(binding.orientedWidth,binding.orientedHeight)>=256 && DevelopmentCropAutoV1.available,
      supportedGrainSamplingVersions:native.supportedGrainSamplingVersions,lensMetadata:native.lensMetadata,
      deviceDepthAvailable:!native.artifact && DevelopmentDeviceDepthV1.probe(native.capture), rawDetailsCapability:native.rawDetailsCapability, aiDenoiseCapability:native.aiDenoiseCapability)
  }
  public func makeProgressChannel(sessionID: DevelopmentPreviewSessionID, sourceGeneration: UInt64,
                                  consumerID: PreviewConsumerID) async throws -> PreviewProgressChannel {
    try Task.checkCancellation()
    guard !terminated, let lease = leases[sessionID] else { throw DevelopmentPreviewError.closed }
    guard lease.valid, lease.generation == sourceGeneration else { throw DevelopmentPreviewError.sourceInvalidated }
    guard draining[consumerID] == nil, !channels.values.contains(where: { $0.consumerID == consumerID }),
      active?.request.consumerID != consumerID, !pending.contains(where: { $0.request.consumerID == consumerID }) else { throw DevelopmentPreviewError.invalidRequest }
    guard case .raw = lease.source, sources[lease.key]?.native.hasRAWFilter == true || renderOverride != nil else { throw DevelopmentPreviewError.invalidRequest }
    try checkStamp(sessionID)
    let mailbox = PreviewProgressMailbox(sessionID: sessionID, generation: sourceGeneration, consumerID: consumerID, now: now,
      wake: { [weak self] id in Task { await self?.driveChannel(id) } },
      terminate: { [weak self] id in Task { await self?.closeProgressChannel(id) } })
    latest.removeValue(forKey: consumerID)
    channels[mailbox.id] = mailbox
    do { try Task.checkCancellation() }
    catch { mailbox.revoke(.closed); channels.removeValue(forKey: mailbox.id); throw error }
    return PreviewProgressChannel(mailbox: mailbox)
  }
  public func closeProgressChannel(_ id: PreviewProgressChannelID) async {
    guard let mailbox = channels[id] else { return }
    mailbox.revoke(.closing)
    cancelMatching({ $0.channelID == id }, error: .closed)
    // The synchronous actor-isolated driver has no suspension/native work of its own.
    // Any queued driver sees a revoked mailbox; the actual detached worker still joins here.
    if active?.channelID == id, let running = worker { await running.value }
    mailbox.revoke(.closed); channels.removeValue(forKey: id)
    refreshChannels(); pump()
  }
  public func cancelAndJoin(consumerID: PreviewConsumerID) async {
    if let retirement = draining[consumerID] { await retirement.value; return }
    let running = (active?.request.consumerID == consumerID || activeAnalysis?.request.preview.consumerID == consumerID || (thumbnailStepRegistration != nil && thumbnailActive?.request.preview.consumerID==consumerID)) ? worker : nil
    let retirement = Task {
      if let running { await running.value }
      self.finishDraining(consumerID)
    }
    draining[consumerID] = retirement
    if thumbnailProxyScope?.consumer == consumerID { thumbnailProxyScope=nil }
    for mailbox in channels.values where mailbox.consumerID == consumerID { mailbox.revoke(.closing) }
    cancelMatching({ $0.request.consumerID == consumerID }, error: .superseded, cancellation: true,cause:.consumerClosing)
    cancelAnalysisMatching({ $0.request.preview.consumerID == consumerID },error:.superseded)
    cancelThumbnailMatching({$0.request.preview.consumerID==consumerID},error:DevelopmentThumbnailError.cancelled)
    await retirement.value
  }
  private func finishDraining(_ consumerID: PreviewConsumerID) {
    for (id, mailbox) in channels where mailbox.consumerID == consumerID { mailbox.revoke(.closed); channels.removeValue(forKey: id) }
    draining.removeValue(forKey: consumerID); refreshChannels(); pump()
  }
  private func driveChannel(_ id: PreviewProgressChannelID) {
    guard let mailbox = channels[id] else { return }
    repeat {
      while let work = mailbox.peek() {
        do {
          let lease = try validate(work.request)
          guard mailbox.take(work.id) else { continue }
          do { try admitChannel(work, mailbox: mailbox, lease: lease) }
          catch { mailbox.complete(work, result: .failure(error)) }
        } catch {
          if mailbox.take(work.id) { mailbox.complete(work, result: .failure(error)) }
        }
      }
    } while !mailbox.stopDriverIfEmpty()
    refreshChannels(); pump()
  }
  private func validate(_ request: DevelopmentPreviewRequest, supportRecipe: DevelopmentRecipe? = nil) throws -> Lease {
    try request.recipe.validate()
    guard !terminated, draining[request.consumerID] == nil else { throw DevelopmentPreviewError.closed }
    guard request.viewport.maxPixel >= 0, request.viewport.maxPixel <= 4096,
      (request.quality == .detail ? request.viewport.maxPixel == 0 : request.viewport.maxPixel != 0),
      (request.clientCorrelation?.count ?? 0) <= 4096 else { throw DevelopmentPreviewError.invalidRequest }
    try Self.validateWindow(request.viewport.window, quality: request.quality)
    guard let lease = leases[request.sessionID] else { throw DevelopmentPreviewError.closed }
    if let scene = request.recipe.adjustmentsV3?.effects?.lensBlur?.sceneDepth {
      let hash: String
      switch lease.source {
      case .raw(let snapshot): hash = snapshot.contentSHA256
      case .artifact(_,let artifact): hash = artifact.sha256
      }
      guard hash == scene.sourceSHA256 else { throw EditingError.staleSource }
    }
    guard lease.valid, request.sourceGeneration == lease.generation else { throw DevelopmentPreviewError.sourceInvalidated }
    try checkStamp(request.sessionID)
    if usesInteractiveEvaluation(request) || usesNativeProfile(request),let native=sources[lease.key]?.native {
      guard policy.contextMemoryLimitMiB==512 else{throw DevelopmentPreviewError.invalidRequest}
      do{try native.validateCaptureAuthority()}
      catch{beginCaptureFault(key:lease.key,captureID:native.captureID);throw DevelopmentPreviewError.sourceInvalidated}
    }
    if DevelopmentBrilliancePublicV1.active(request.recipe) {
      guard qaBrilliancePublicV1,policy.contextMemoryLimitMiB==512,request.role == .primary,request.quality != .detail,request.viewport.maxPixel == 2400,
        let native=sources[lease.key]?.native,!native.hasRAWFilter,!native.artifact else{throw PreviewPresentationError.unsupported}
      try DevelopmentBrilliancePublicV1.requireDomain(request.recipe.adjustmentsV3!,sourceIsRAW:native.hasRAWFilter)
    }
    if case .artifact = lease.source, request.recipe != DevelopmentRecipe() { throw DevelopmentPreviewError.invalidRequest }
    if request.recipe.schemaVersion == 3 {
      try DevelopmentRendererV3.validateSupport(supportRecipe ?? request.recipe,sourceIsRAW:sources[lease.key]?.native.hasRAWFilter == true)
      if let resources=filterResourcesForTesting {
        // Isolated tests may revoke their own copied resource authority after seeding a bitmap.
        // Product construction has no override and always uses the installed shared catalog.
        _ = try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(supportRecipe ?? request.recipe,resources:resources)
      }
      if case .raw(let snapshot) = lease.source, let native = sources[lease.key]?.native {
        let binding = DevelopmentLocalEditSourceBinding(sourceContentID:snapshot.contentSHA256,exifOrientation:native.originalEXIFOrientation,
          orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height))
        if supportRecipe == nil, request.recipe.adjustmentsV3!.advancedDetail.dehaze.enabled,
          request.recipe.adjustmentsV3!.advancedDetail.dehaze.amount != 0 {
          try DevelopmentDehazeContextFactoryV1.requirePrepared(request.recipe,context:admittedDehazeContext(native,key:lease.key,source:binding,generation:lease.generation))
        }
        try DevelopmentMaskLayerV3.validateSource(request.recipe.adjustmentsV3!.masks, expected:binding)
        try request.recipe.adjustmentsV3!.localEdits.validate(expectedSource:binding)
        try request.recipe.adjustmentsV3!.whiteBalance.resolvedState?.validate(expectedSource:binding)
        _ = try request.recipe.adjustmentsV3!.geometry.mapping(sourceSize:binding.sourceSize)
      }
    }
    if request.deliveryPolicy == .inFlightProgress {
      guard request.role == .primary, request.quality != .detail, case .raw = lease.source,
        sources[lease.key]?.native.hasRAWFilter == true || renderOverride != nil else { throw DevelopmentPreviewError.invalidRequest }
    }
    if let old = latest[request.consumerID], old.0 == request.sessionID, old.1 == request.sourceGeneration,
      request.revision < old.2 { throw DevelopmentPreviewError.superseded }
    return lease
  }
  private func submitted(_ request: DevelopmentPreviewRequest) {
    latest[request.consumerID] = (request.sessionID, request.sourceGeneration, request.revision)
    latestRecipeFingerprint[request.consumerID] = try? EditingFingerprint.of(request.recipe)
    if request.role == .primary{thumbnailSettled.removeValue(forKey:request.consumerID)}
    cancelAnalysisMatching({ item in
      let old = item.request.preview
      return old.consumerID == request.consumerID && (old.sessionID != request.sessionID || old.sourceGeneration != request.sourceGeneration ||
        old.revision < request.revision || (old.revision == request.revision && item.request.presentedRecipeFingerprint != self.latestRecipeFingerprint[request.consumerID]))
    },error:.superseded)
    cancelThumbnailMatching({ item in
      let old=item.request.preview
      return old.consumerID==request.consumerID && (old.sessionID != request.sessionID || old.sourceGeneration != request.sourceGeneration || old.revision<request.revision || item.request.presentedRecipeFingerprint != self.latestRecipeFingerprint[request.consumerID] ||
        (request.role == .primary && request.quality == .interactive) || (item.request.basis == .currentCanonical && old.quality != request.quality))
    },error:DevelopmentThumbnailError.superseded)
    stats.submittedRequests += 1
    if request.role == .primary && request.quality == .interactive { primaryInteractiveAt = now(); comparisonOwed = false }
    cancelMatching({ $0.request.consumerID == request.consumerID }, error: .superseded, includeActive: false)
    if let old = active, old.request.consumerID == request.consumerID {
      let compatible = old.request.deliveryPolicy == .inFlightProgress && request.deliveryPolicy == .inFlightProgress &&
        old.request.sessionID == request.sessionID && old.request.sourceGeneration == request.sourceGeneration
      if !compatible { cancelMatching({ $0.token == old.token }, error: .superseded) }
    }
  }
  private func admitChannel(_ work: PreviewSubmittedWork, mailbox: PreviewProgressMailbox, lease: Lease) throws {
    let request = work.request
    submitted(request)
    let interactivePlan=try prepareInteractivePlan(request,sourceKey:lease.key)
    let nativePointwisePlan=try prepareNativePointwisePlan(request,sourceKey:lease.key)
    let outputKey = try pixelKey(request, sourceKey: lease.key,interactivePlan:interactivePlan,nativePointwisePlan:nativePointwisePlan)
    if let hit = replayBitmap(request, sourceKey: lease.key, outputKey: outputKey,
      interactivePlan: interactivePlan, nativePointwisePlan: nativePointwisePlan) {
      mailbox.complete(work, result: .success(frame(request, key: hit.key, pixels: hit.pixels,sharedFITRequested:requestsSharedFIT(nativePointwisePlan),bitmapReplay:true)))
      markComparisonOwed(request, channelID: mailbox.id)
      return
    }
    guard !criticalPressure else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    guard pending.count < policy.maximumPendingRequests else { throw DevelopmentPreviewError.capacityExceeded }
    pending.append(Pending(token: work.id.rawValue, request: request, key: lease.key, outputKey: outputKey,
                           continuation: nil, channelID: mailbox.id, sequence:nextSchedulingSequence(),queuedAt:now(),nativePointwisePlan:nativePointwisePlan,interactivePlan:interactivePlan))
    stats.maximumObservedPendingRequests = max(stats.maximumObservedPendingRequests, pending.count)
  }
  public func render(_ request: DevelopmentPreviewRequest) async throws -> DevelopmentPreviewFrame {
    try Task.checkCancellation()
    guard !channels.values.contains(where: { $0.consumerID == request.consumerID }), draining[request.consumerID] == nil else { throw DevelopmentPreviewError.invalidRequest }
    let lease = try validate(request)
    submitted(request)
    let interactivePlan=try prepareInteractivePlan(request,sourceKey:lease.key)
    let nativePointwisePlan=try prepareNativePointwisePlan(request,sourceKey:lease.key)
    let outputKey = try pixelKey(request, sourceKey: lease.key,interactivePlan:interactivePlan,nativePointwisePlan:nativePointwisePlan)
    if let hit = replayBitmap(request, sourceKey: lease.key, outputKey: outputKey,
      interactivePlan: interactivePlan, nativePointwisePlan: nativePointwisePlan) {
      markComparisonOwed(request)
      return frame(request, key: hit.key, pixels: hit.pixels,sharedFITRequested:requestsSharedFIT(nativePointwisePlan),bitmapReplay:true)
    }
    guard !criticalPressure else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let token = UUID()
    return try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        guard pending.count < policy.maximumPendingRequests else { continuation.resume(throwing: DevelopmentPreviewError.capacityExceeded); return }
        pending.append(Pending(token: token, request: request, key: lease.key, outputKey: outputKey, continuation: continuation, sequence:nextSchedulingSequence(),queuedAt:now(),nativePointwisePlan:nativePointwisePlan,interactivePlan:interactivePlan))
        stats.maximumObservedPendingRequests = max(stats.maximumObservedPendingRequests, pending.count)
        refreshChannels(); pump()
      }
    }, onCancel: { Task { await self.cancelToken(token) } })
  }
  public func cancel(consumerID: PreviewConsumerID) async {
    if thumbnailProxyScope?.consumer == consumerID { thumbnailProxyScope=nil }
    for mailbox in channels.values where mailbox.consumerID == consumerID { mailbox.cancelBuffered() }
    cancelMatching({ $0.request.consumerID == consumerID }, error: .superseded, cancellation: true)
    cancelAnalysisMatching({ $0.request.preview.consumerID == consumerID },error:.superseded)
    cancelThumbnailMatching({$0.request.preview.consumerID==consumerID},error:DevelopmentThumbnailError.cancelled)
    refreshChannels()
  }
  private func cancelToken(_ token: UUID) { cancelMatching({ $0.token == token }, error: .superseded, cancellation: true) }
  private func deliver(_ item: Pending, _ result: Result<DevelopmentPreviewFrame, Error>, cancellation: Bool = false) {
    guard item.deliveryEnabled else { return }
    if let id = item.channelID { channels[id]?.complete(item.work, result: result, cancellation: cancellation) }
    else { item.continuation?.resume(with: result) }
  }
  private func cancelMatching(_ matches: (Pending) -> Bool, error: DevelopmentPreviewError,
                              includeActive: Bool = true, cancellation: Bool = false,
                              cause:PreviewNativeCancellationCauseV1? = nil) {
    for item in pending where matches(item) {
      deliver(item,.failure(error),cancellation:cancellation);stats.supersededRequests+=1
      if item.request.quality == .settled{cancelThumbnailsWaitingFor(item.request)}
    }
    pending.removeAll(where: matches)
    if includeActive, let current = active, matches(current) {
      // A later source/pressure/close must upgrade authority even if an earlier frame-only
      // supersession already disabled delivery. Cancellation does not release the worker.
      current.interactiveCancellation.cancel(cause:cause ?? PreviewNativeInputProfileV1.cause(error))
      if current.deliveryEnabled {
        if current.nativePointwisePlan?.preserveVerifiedInput==true { stats.nativeProfileCancelledFrames &+= 1 }
        deliver(current, .failure(error), cancellation: cancellation)
        active?.continuation = nil; active?.deliveryEnabled = false; stats.supersededRequests += 1
        if current.request.quality == .settled{cancelThumbnailsWaitingFor(current.request)}
      }
      // Synchronous CoreImage cannot be cancelled; its worker keeps the native slot until finish().
    }
    refreshChannels()
  }
  private func refreshChannels() {
    for (id, mailbox) in channels {
      mailbox.update(active: active.flatMap { $0.channelID == id ? $0.work : nil },
                     pending: pending.first(where: { $0.channelID == id })?.work)
    }
  }
  private func activityInstant() -> UInt64 { channels.values.reduce(primaryInteractiveAt) { max($0, $1.activityAt) } }
  private func markComparisonOwed(_ request: DevelopmentPreviewRequest, channelID: PreviewProgressChannelID? = nil,
                                  deliveryEnabled: Bool = true) {
    recordThumbnailCanonicalHead(request,channelID:channelID,deliveryEnabled:deliveryEnabled)
    guard deliveryEnabled, request.role == .primary, request.quality == .settled,
      let current = latest[request.consumerID], current.0 == request.sessionID,
      current.1 == request.sourceGeneration, current.2 == request.revision else { return }
    if let channelID, channels[channelID]?.latestRevision != request.revision { return }
    comparisonOwed = true; owedScope = (request.consumerID, request.revision, activityInstant())
  }
  private func recordThumbnailCanonicalHead(_ request:DevelopmentPreviewRequest,channelID:PreviewProgressChannelID?,deliveryEnabled:Bool) {
    guard deliveryEnabled,request.role == .primary,request.quality == .settled || request.quality == .detail,
      let current=latest[request.consumerID],current.0==request.sessionID,current.1==request.sourceGeneration,current.2==request.revision else{return}
    if let channelID,channels[channelID]?.latestRevision != request.revision{return}
    thumbnailSettled[request.consumerID]=request
  }
  private func owedIsCurrent() -> Bool {
    guard comparisonOwed, let scope = owedScope, activityInstant() <= scope.2,
      latest[scope.0]?.2 == scope.1 else { return false }
    return !channels.values.contains { $0.consumerID == scope.0 && $0.latestRevision != scope.1 }
  }
  private func scheduleQuietWake(after nanoseconds: UInt64) {
    guard quietWake == nil else { return }
    let id = UUID(); quietWakeID = id
    quietWake = Task { [weak self] in
      try? await Task.sleep(nanoseconds: max(1_000_000, nanoseconds))
      guard !Task.isCancelled else { return }
      await self?.quietDeadline(id)
    }
  }
  private func quietDeadline(_ id: UUID) {
    guard quietWakeID == id else { return }; quietWake = nil; quietWakeID = nil; pump()
  }
  private func pump() {
    if startThumbnailContextMaintenanceIfNeeded(){return}
    let prewarmOwed = idlePrewarmCandidate() != nil
    guard !terminated, worker == nil, (!pending.isEmpty || userAnalysis != nil || backgroundHistogram != nil || thumbnailPending != nil || thumbnailActive != nil || prewarmOwed) else { return }
    if rawBasePool != nil && (!rawBaseRetiring.isEmpty || rawBaseClearRequested || rawBaseMaintenance != nil) {
      guard !rawBasePumpWaiting else { return }; rawBasePumpWaiting = true
      Task { await self.flushRawBaseCommands(); self.rawBasePumpWaiting = false; self.pump() }
      return
    }
    let instant = now(), activity = activityInstant(), interval = UInt64(policy.comparisonQuiescenceMilliseconds) * 1_000_000
    let quiet = instant >= activity && instant - activity >= interval
    let comparison = pending.firstIndex { $0.request.role == .comparison }
    let primary = pending.firstIndex { $0.request.role == .primary }
    let interactive = pending.firstIndex { $0.request.role == .primary && $0.request.quality == .interactive }
    let eligibleComparison = comparison.flatMap { (owedIsCurrent() || quiet) ? $0:nil }
    if let user = userAnalysis, interactive == nil || consecutiveInteractive >= 2 {
      if eligibleComparison == nil || user.sequence <= pending[eligibleComparison!].sequence {
        userAnalysis = nil; startAnalysis(user); return
      }
    }
    if primary == nil, eligibleComparison == nil {
      if let user = userAnalysis { userAnalysis = nil; startAnalysis(user); return }
      if let histogram = backgroundHistogram {
        // A final frame can arrive long after its input; coalesce from this latest histogram's enqueue.
        let histogramActivity = max(activity, histogram.queuedAt)
        let histogramQuiet = interval == 0 || (instant >= histogramActivity && instant - histogramActivity >= interval)
        if histogramQuiet { backgroundHistogram = nil; startAnalysis(histogram); return }
        scheduleQuietWake(after: instant >= histogramActivity ? interval - min(interval, instant - histogramActivity) : interval)
        return // Preserve histogram-before-thumbnail ordering without occupying the native worker.
      }
      if quiet, prewarmOwed,
         instant - activity >= UInt64(Self.detailPrewarmIdleMilliseconds) * 1_000_000 {
        if startDetailPrewarm() { return }
      }
      if quiet { if startThumbnailStep(){return} }
      else if thumbnailPending != nil || thumbnailActive != nil || prewarmOwed {
        scheduleQuietWake(after:instant >= activity ? interval-min(interval,instant-activity):interval)
      }
    }
    guard !pending.isEmpty else { return }
    let index: Int
    if let comparison, owedIsCurrent() || quiet { index = comparison; comparisonOwed = false }
    else if let detail = pending.firstIndex(where: { $0.request.role == .primary && $0.request.quality == .detail }) { index = detail }
    else if let primary { index = primary }
    else { scheduleQuietWake(after: instant >= activity ? interval - min(interval, instant - activity) : interval); return }
    quietWake?.cancel(); quietWake = nil; quietWakeID = nil
    let item = pending.remove(at: index)
    guard let record = sources[item.key], let lease = leases[item.request.sessionID], lease.valid, lease.generation == item.request.sourceGeneration else {
      deliver(item, .failure(DevelopmentPreviewError.sourceInvalidated)); refreshChannels(); pump(); return
    }
    do { try checkStamp(item.request.sessionID) }
    catch { deliver(item, .failure(error)); refreshChannels(); pump(); return }
    if let hit = replayBitmap(item.request, sourceKey: item.key, outputKey: item.outputKey,
      interactivePlan: item.interactivePlan, nativePointwisePlan: item.nativePointwisePlan) {
      deliver(item, .success(frame(item.request, key: hit.key, pixels: hit.pixels,sharedFITRequested:requestsSharedFIT(item.nativePointwisePlan),bitmapReplay:true)))
      markComparisonOwed(item.request, channelID: item.channelID, deliveryEnabled: item.deliveryEnabled)
      refreshChannels(); pump(); return
    }
    if item.interactivePlan != nil || item.nativePointwisePlan != nil || requestsGrainFinalTransport(item.request,sourceKey:item.key) {
      // A managed miss must not retain evictable old display-cache owners until AFTER output
      // allocation. UI-held providers still remain charged and can legitimately reject capacity.
      // Keep at most ONE same-source authoritative semantic bitmap. It is an existing
      // bounded cache entry/ticket, not a new cache/history, and saves the legacy-zero
      // round trip without evicting the shared native input on its later actual hit.
      let keepSemantic:String?
      if item.nativePointwisePlan?.preserveVerifiedInput==true {
        keepSemantic=cache.filter{$0.value.sourceKey==item.key && $0.value.nativeProfileSemantic &&
          $0.value.pixels.managedPresentation && $0.value.pixels.approximation==nil &&
          nativeProfileCacheTicketOpen($0.value.pixels)}.max{$0.value.use<$1.value.use}?.key
      } else { keepSemantic=nil }
      for (key,value) in Array(cache) where value.pixels.managedPresentation && key != keepSemantic {
        value.pixels.presentationTicket?.markRetired();stats.cachedBitmapBytes-=value.pixels.bytes
        cache.removeValue(forKey:key);stats.evictions &+= 1
      }
    }
    consecutiveInteractive = item.request.role == .primary && item.request.quality == .interactive ? consecutiveInteractive+1:0
    if item.nativePointwisePlan?.preserveVerifiedInput==true {
      if item.nativePointwisePlan?.canonicalFullChecks==true { stats.nativeProfileCanonicalJobs &+= 1;stats.nativeProfileLastRoute=2 }
      else { stats.nativeProfileInteractiveJobs &+= 1;stats.nativeProfileLastRoute=1 }
      let instant=now();stats.nativeProfileLastSlotWaitNanoseconds=instant>=item.queuedAt ? instant-item.queuedAt:0
    }
    active = item; stats.activeNativeRenders = 1; stats.maximumObservedNativeRenders = max(1, stats.maximumObservedNativeRenders)
    refreshChannels()
    if rawBasePool != nil && item.request.quality == .detail {
      for value in cache.values{value.pixels.presentationTicket?.markRetired()}
      stats.evictions += UInt64(cache.count); cache.removeAll(); stats.cachedBitmapBytes = 0
    }
    let native = record.native, override = renderOverride, request = item.request, pool = rawBasePool
    qaLifecycle(.render,.admitted,id:item.token,request:request,sourceID:native.captureID)
    let thumbnailHook=makeThumbnailSettledHook(item,native:native)
    let proxyPool=interactiveProxyPool,scope=interactivePresentation,memoryLimit=policy.contextMemoryLimitMiB
    let metalPrograms = portableMetalPrograms
    // One canonical operation preserves this admitted source owner/key, pool policy and thumbnail hook.
    // Managed fallback and ordinary canonical rendering invoke the same operation exactly once.
    let grainTransportRequested=requestsGrainFinalTransport(request,sourceKey:item.key)
    let newBrilliance=DevelopmentBrilliancePublicV1.active(request.recipe)
    let dehazeRequested=requestsDehazeTIFF(request,sourceKey:item.key)
    let halfFIT = request.quality == .settled ? canonicalHalfFIT(request,sourceKey:item.key) : nil
    let dehazeObserver=qaDehazeTIFFObserverForTesting
    let canonicalRender:()throws->PreviewPixels = {
      let brillianceRequest:DevelopmentBrilliancePublicV1.Request?
      if newBrilliance {
        guard let scope else{throw PreviewPresentationError.allocationProtocol}
        brillianceRequest = .init(scope:scope,check:{try item.interactiveCancellation.check();try native.validateCaptureAuthority()})
      }else{brillianceRequest=nil}
      let grainTransport:PreviewGrainFinalTransportV1.Request?
      if grainTransportRequested {
        guard let scope else{throw PreviewPresentationError.allocationProtocol}
        grainTransport = .init(maxPixel:request.viewport.maxPixel,scope:scope,check:{
          try item.interactiveCancellation.check();try native.validateCaptureAuthority()
        })
      }else{grainTransport=nil}
      let dehazeRequest:DevelopmentDehazeTIFFPreviewV1.Request?
      if dehazeRequested{
        guard let scope else{throw PreviewPresentationError.allocationProtocol}
        dehazeRequest = .init(scope:scope,check:{try item.interactiveCancellation.check();try native.validateCaptureAuthority()},observer:dehazeObserver)
      }else{dehazeRequest=nil}
      let localMaskValidation: DevelopmentMaskEngineV3.CanonicalValidation?
      if request.role == .primary, request.quality == .settled, request.viewport.maxPixel == 2400,
         let transport = DevelopmentMaskEngineV3.CanonicalValidation.requestedTransport(for: request.recipe.adjustmentsV3) {
        localMaskValidation = .init(transport: transport, checkCancellation: { try item.interactiveCancellation.check() })
      } else {
        localMaskValidation = nil
      }
      let spatialScan: DevelopmentCanonicalFiniteGPU.SpatialRequest?
      if request.role == .primary, request.quality == .settled, request.viewport.maxPixel == 2400,
         let adjustments = request.recipe.adjustmentsV3 {
        spatialScan = DevelopmentCanonicalFiniteGPU.spatialRequest(adjustments) { try item.interactiveCancellation.check() }
      } else {
        spatialScan = nil
      }
      let checkDehazeTexture: (() throws -> Void)?
      if DevelopmentResidentDehazeGuide.sharedTextureRequested || DevelopmentResidentDehazeGuide.directTextureRequested, memoryLimit == 512,
         request.role == .primary, request.quality == .settled, request.viewport.maxPixel == 2400,
         DevelopmentDehazeEngineV3.usesPositiveV2(request.recipe.adjustmentsV3?.advancedDetail) {
        checkDehazeTexture = { try item.interactiveCancellation.check(); try native.validateCaptureAuthority() }
      } else {
        checkDehazeTexture = nil
      }
      let checkCanonicalCache: (() throws -> Void)?
      let primaryFIT = request.role == .primary && request.quality == .settled && request.viewport.maxPixel == 2400
      if Self.qaCanonicalRequestCache && primaryFIT {
        checkCanonicalCache = { try item.interactiveCancellation.check() }
      } else {
        checkCanonicalCache = nil
      }
      let checkCanonicalHalfFIT: (() throws -> Void)?
      let portableHalfFITRequest: PreviewPortableHalfFIT.Request?
      if let halfFIT {
        checkCanonicalHalfFIT = { try item.interactiveCancellation.check(); try native.validateCaptureAuthority() }
        portableHalfFITRequest = halfFIT != .coreImage ? checkCanonicalHalfFIT.map {
          .init(programs:metalPrograms,revision:request.revision,checkAuthority:$0)
        } : nil
      } else {
        checkCanonicalHalfFIT = nil
        portableHalfFITRequest = nil
      }
      let nativeFiniteCheck: FlashRawNativeFiniteCheck.Request?
      let comparisonFIT = request.role == .comparison && request.quality == .settled && request.viewport.maxPixel == 2400
      if FlashRawNativeFiniteCheck.enabled, native.hasRAWFilter, primaryFIT || comparisonFIT {
        nativeFiniteCheck = .init(mayCheckTexture: primaryFIT, checkAuthority: {
          try item.interactiveCancellation.check()
          try native.validateCaptureAuthority()
        })
      } else {
        nativeFiniteCheck = nil
      }
      return try native.render(recipe:request.recipe,maxPixel:request.viewport.maxPixel,window:request.viewport.window,rawBasePool:pool,sourceKey:item.key,
        localMaskValidation:localMaskValidation,thumbnailNativeSink:thumbnailHook.map{$0.consume},grainFinalTransport:grainTransport,
        brillianceFinalTransport:brillianceRequest,dehazeTIFFRequest:dehazeRequest,spatialScan:spatialScan,
        checkDehazeTexture:checkDehazeTexture,checkCanonicalCache:checkCanonicalCache,
        checkCanonicalHalfFIT:checkCanonicalHalfFIT,portableHalfFITRequest:portableHalfFITRequest,nativeFiniteCheck:nativeFiniteCheck,
        localSourceCancellation:item.interactiveCancellation)
    }
    // Look up the full canonical key, including source, viewport, recipe and active filter resources.
    // Only a settled primary result can supply a revisited value. The reverse lookup never occurs.
    let settledDisplay: (key:String, pixels:PreviewPixels)?
    // A settled pure sharpening-mask recipe already contains the native-resolution
    // grayscale visualization. Reopening it can use the exact fitted display raster.
    if Self.replaysExactDisplay, let plan = item.interactivePlan, plan.isProxy,
       (plan.sourceOverlayVersion == nil ||
        request.recipe.adjustmentsV3.map({ PreviewInteractiveDetailGuide.isPureSharpen($0,maskPreview:true) }) == true),
       item.nativePointwisePlan == nil, let fingerprint = latestRecipeFingerprint[request.consumerID],
       cache.values.contains(where: { $0.sourceKey == item.key && $0.settledRecipeFingerprint == fingerprint }),
       let exactKey = try? pixelKey(request,sourceKey:item.key,settledHalfFITReplay:true), let exact = cache[exactKey], exact.settledRecipeFingerprint == fingerprint,
       !exact.pixels.managedPresentation, exact.pixels.approximation == nil {
      settledDisplay = (exactKey,exact.pixels)
    } else { settledDisplay = nil }
    let sharedFITRequested=requestsSharedFIT(item.nativePointwisePlan)
    let neutralPretransportObserver=item.nativePointwisePlan?.neutralOwnerBootstrap == true ? qaNeutralPretransportObserverForTesting:nil
    let renderNative:(PreviewQALifecycleTrace.IPTiming?)throws->PreviewPixels = { qaIPTiming in
      if let override{return try override(request.recipe,request.viewport.maxPixel)}
      if let plan=item.nativePointwisePlan,let scope {
        return try native.renderNativePointwise(recipe:request.recipe,maxPixel:request.viewport.maxPixel,plan:plan,pool:pool,scope:scope,memoryLimit:memoryLimit,cancellation:item.interactiveCancellation,thumbnailNativeSink:thumbnailHook.map{$0.consume},qaIPTiming:qaIPTiming,qaSharedFITIntermediate:sharedFITRequested,qaNeutralPretransportObserver:neutralPretransportObserver,canonicalRender:canonicalRender)
      }
      if let plan=item.interactivePlan,let scope {
        if let settledDisplay, let replay = try PreviewSettledDisplayReplay.make(settledDisplay.pixels,key:settledDisplay.key,size:plan.outputLayout,scope:scope,check:{
          try native.validateCaptureAuthority()
          try item.interactiveCancellation.check()
        }) { return replay }
        return try native.renderInteractiveProxy(recipe:request.recipe,maxPixel:request.viewport.maxPixel,plan:plan,pool:proxyPool,programs:metalPrograms,scope:scope,rawBasePool:pool,memoryLimit:memoryLimit,cancellation:item.interactiveCancellation)
      }
      return try canonicalRender()
    }
    worker = Task {
      let telemetry = ImagePerformanceTelemetry.shared
      let backend = native.hasRAWFilter ? "RAW" : "图像"
      let token = telemetry.begin(operation: "生成预览", stage: backend + " · " + request.quality.rawValue, queue: Self.queueName(request))
      let result: (Result<PreviewPixels, Error>, RawBaseStatisticsSnapshot?, PreviewQALifecycleTrace.IPPacket?)
      do {
        result = try await ProcessingAdmission.shared.withPermit(.editing, resources: .init(cpu: 1, gpu: 1), presentation: true) {
          try item.interactiveCancellation.check()
          return await Task.detached(priority: .userInitiated) {
            PreviewQALifecycleTrace.record(.render,.entered,id:item.token,request:request,sourceID:native.captureID)
            defer { PreviewQALifecycleTrace.record(.render,.returned,id:item.token,request:request,sourceID:native.captureID) }
            let qaIPTiming=PreviewQALifecycleTrace.makeIPTiming(id:item.token,eligible:request.quality == .interactive && item.nativePointwisePlan?.fallback == nil && item.nativePointwisePlan?.canonicalFullChecks == false && pool != nil)
            func packet(_ result:Result<PreviewPixels,Error>)->PreviewQALifecycleTrace.IPPacket? {
              let succeeded:Bool;if case .success=result{succeeded=true}else{succeeded=false}
              return qaIPTiming?.finish(successful:succeeded)
            }
            if let pool {
              return pool.withWorker {
                let v2Eligible = request.recipe.schemaVersion == 2 && request.recipe.color?.isNeutral == false && native.hasRAWFilter
                let v3Eligible = PreviewRawBaseRenderer.v3CacheEligible(request.recipe,sourceIsRAW:native.hasRAWFilter)
                if request.quality == .detail && !v2Eligible && !v3Eligible { pool.evictUnpinned() }
                let rendered = Result { try DevelopmentRenderStack.run {
                  try DevelopmentDehazeNativeResources.run { try renderNative(qaIPTiming) }
                } }
                return (rendered,pool.statistics,packet(rendered))
              }
            }
            let rendered=Result { try DevelopmentRenderStack.run { try DevelopmentDehazeNativeResources.run { try renderNative(qaIPTiming) } } };return (rendered,nil,packet(rendered))
          }.value
        }
      } catch {
        result = (.failure(error), nil, nil)
      }
      telemetry.end(token, result: result.0) { Int($0.outputSize.width * $0.outputSize.height) }
      await self.finish(token:item.token,result:result.0,rawStatistics:result.1,thumbnailHook:thumbnailHook,qaIPPacket:result.2)
    }
  }
  private func finish(token: UUID, result: Result<PreviewPixels, Error>, rawStatistics: RawBaseStatisticsSnapshot?,thumbnailHook:ThumbnailSettledHook? = nil,qaIPPacket:PreviewQALifecycleTrace.IPPacket? = nil) async {
    guard active?.token == token else { thumbnailHook?.take()?.surface.retire(); return }
    if let rawStatistics { applyRawBaseStatistics(rawStatistics) }
    if active?.interactiveCancellation.didPreserveInput==true { stats.nativeProfilePreservedInputs &+= 1 }
    if case let .failure(error) = result, let fault = DevelopmentDehazeNativeResources.captureFault(error), let item = active {
      beginCaptureFault(key:item.key,captureID:fault.captureID)
    }
    if let failure=thumbnailHook?.takeFailure(),let registration=thumbnailHook?.batch.request.registration {
      cancelThumbnailMatching({$0.request.registration==registration},error:failure)
    }
    // Keep worker/active ownership while queued retirement commands join. Cancellation can
    // still revoke active delivery while this actor suspends; re-read it after the await.
    await flushRawBaseCommands()
    guard let item = active, item.token == token else { return }
    // Native has actually joined. No earlier cancellation/terminal releases capacity.
    active = nil; stats.activeNativeRenders = 0; stats.completedRenders += 1
    let qaEmitNS=PreviewQALifecycleTrace.emitIPTiming(qaIPPacket)
    qaLifecycle(.render,.joined,id:item.token,request:item.request,sourceID:sources[item.key]?.native.captureID,raw:rawStatistics,ipEmitNS:qaEmitNS)
    do {
      guard let lease = leases[item.request.sessionID], lease.valid, lease.generation == item.request.sourceGeneration else { throw DevelopmentPreviewError.sourceInvalidated }
      try checkStamp(item.request.sessionID)
      let pixels = try result.get()
      if pixels.nativePointwise?.canonicalFullChecks==true { stats.nativeProfileCanonicalValidatedOutputs &+= 1 }
      if pixels.nativePointwise?.canonicalGlobalFiniteProofID==PreviewNaturalCurveFiniteEvidenceV1.version {
        stats.nativeNaturalProvenGlobalOutputs &+= 1;stats.nativeProfileLastRoute=9
      }
      if pixels.nativePointwise?.canonicalGlobalFiniteProofID==PreviewCanonicalFiniteEvidenceV1.version {
        stats.nativeProfileCanonicalProvenGlobalOutputs &+= 1;stats.nativeProfileLastRoute=7
      }
      var actualOutputKey=pixels.settledReplayKey ?? item.outputKey
      if pixels.settledReplayKey != nil { stats.cacheHits &+= 1 }
      if var plan=item.nativePointwisePlan,plan.canonicalNaturalFiniteProofEnabled,
        pixels.nativePointwise?.canonicalGlobalFiniteProofID != PreviewNaturalCurveFiniteEvidenceV1.version {
        plan.canonicalNaturalFiniteProofEnabled=false
        actualOutputKey=try pixelKey(item.request,sourceKey:item.key,interactivePlan:item.interactivePlan,nativePointwisePlan:plan)
      }
      if let plan=item.nativePointwisePlan,plan.canonicalNaturalFiniteProofEnabled,requestsSharedFIT(plan),
        pixels.nativePointwise?.canonicalGlobalFiniteProofID==PreviewNaturalCurveFiniteEvidenceV1.version,
        pixels.nativePointwise?.sharedFITIntermediateInserted != true {
        // Cold/proven output did not insert the shared node; do not publish it under the requested ON key.
        actualOutputKey=try pixelKey(item.request,sourceKey:item.key,interactivePlan:item.interactivePlan,
          nativePointwisePlan:plan,naturalSharedFITOverride:false)
      }
      if var plan=item.nativePointwisePlan,plan.canonicalGlobalFiniteProofEnabled,
        pixels.nativePointwise?.canonicalGlobalFiniteProofID==nil {
        // A missing/cold witness produced a genuinely scanned canonical frame, whose old
        // namespace remains separate from successful proof-backed bitmap entries.
        plan.canonicalGlobalFiniteProofEnabled=false
        actualOutputKey=try pixelKey(item.request,sourceKey:item.key,interactivePlan:item.interactivePlan,nativePointwisePlan:plan)
      }
      if let plan=item.nativePointwisePlan,plan.canonicalGlobalFiniteProofEnabled,
        !plan.canonicalNaturalFiniteProofEnabled,requestsSharedFIT(plan),
        pixels.nativePointwise?.canonicalGlobalFiniteProofID==PreviewCanonicalFiniteEvidenceV1.version,
        pixels.nativePointwise?.sharedFITIntermediateInserted != true {
        // A cold same-owner proof is valid but did not insert the warm transport.
        // Publish it only under its actual OFF namespace, never the requested ON key.
        actualOutputKey=try pixelKey(item.request,sourceKey:item.key,interactivePlan:item.interactivePlan,
          nativePointwisePlan:plan,canonicalSharedFITOverride:false)
      }
      if !clearAfterJoin && pixels.settledReplayKey == nil {
        let settled = item.request.quality == .settled && item.request.role == .primary
        insert(pixels,key:actualOutputKey,sourceKey:item.key,settledRecipe:settled ? item.request.recipe:nil,
               nativeProfileSemantic:item.nativePointwisePlan?.semanticLegacy==true)
        if settled, !pixels.managedPresentation, pixels.approximation == nil, cache[actualOutputKey]?.settledRecipeFingerprint != nil {
          retireEarlierSharpenMaskProxy(item.request,sourceKey:item.key)
        }
      }
      deliver(item, .success(frame(item.request, key: actualOutputKey, pixels: pixels,sharedFITRequested:requestsSharedFIT(item.nativePointwisePlan))))
      markComparisonOwed(item.request, channelID: item.channelID, deliveryEnabled: item.deliveryEnabled)
      if let proxy=thumbnailHook?.take(){
        if thumbnailHook?.batch.gate.isOpen==true,item.deliveryEnabled,thumbnailProxy==nil{
          thumbnailProxy=(item.key,proxy)
          thumbnailProxyScope=(item.request.sessionID,item.request.consumerID)
        }else{proxy.surface.retire()}
      }
    } catch {
      deliver(item,.failure(error))
      cancelThumbnailMatching({scope in let r=scope.request.preview;return r.sessionID==item.request.sessionID && r.sourceGeneration==item.request.sourceGeneration && r.consumerID==item.request.consumerID && r.revision==item.request.revision},error:DevelopmentThumbnailError.awaitingSource)
    }
    thumbnailHook?.take()?.surface.retire()
    if clearAfterJoin { clearCaches(); clearAfterJoin = false }
    for key in Array(sources.keys) { cleanupSource(key) }
    await flushRawBaseCommands()
    worker = nil
    refreshChannels(); pump()
  }
  private func frame(_ request: DevelopmentPreviewRequest, key: String, pixels: PreviewPixels,sharedFITRequested:Bool=false,bitmapReplay:Bool=false) -> DevelopmentPreviewFrame {
    if let receipt=pixels.nativePointwise { nativePointwiseLastReceipt=receipt }
    if usesInteractiveEvaluation(request),let reason=pixels.interactiveCanonicalFallbackReason {
      stats.interactiveProxyCanonicalFallbacks &+= 1;stats.interactiveProxyLastFallbackReason=reason
    }
    let value = DevelopmentPreviewFrame(frameID: UUID(), image: pixels.image, sessionID: request.sessionID,
      sourceGeneration: request.sourceGeneration, consumerID: request.consumerID, revision: request.revision,
      quality: request.quality, canonicalPixelSize: pixels.nativeSize, outputPixelSize: pixels.outputSize, outputKey: key, window: pixels.window, approximate: pixels.approximation != nil,approximation:pixels.approximation,brillianceTransportVersion:pixels.brilliancePublicObservation?.transport,brillianceMapSHA256:pixels.brilliancePublicObservation?.mapSHA256,dehazePreviewContract:pixels.dehazeTIFFObservation?.version,dehazePreviewFallback:pixels.dehazeTIFFObservation?.fallbackReason,dehazePlaneSHA256:pixels.dehazeTIFFObservation?.planeSHA256)
    qaLifecycle(.render,.frame,id:value.frameID,request:request,sourceID:leases[request.sessionID].flatMap { sources[$0.key]?.native.captureID },receipt:pixels.nativePointwise,frameID:value.frameID,sharedFITRequested:sharedFITRequested,bitmapReplay:bitmapReplay,grainFinalTransport:pixels.actualGrainFinalTransport,presentationTicketID:PreviewQAMainPresentationWitness.registeredTicketID(pixels.presentationTicket?.id))
    return value
  }
  private func insert(_ pixels: PreviewPixels, key: String, sourceKey: String,settledRecipe:DevelopmentRecipe?,nativeProfileSemantic:Bool = false) {
    guard pixels.bytes <= policy.bitmapCacheBytes else { return }
    if let old = cache.removeValue(forKey: key) { old.pixels.presentationTicket?.markRetired();stats.cachedBitmapBytes -= old.pixels.bytes }
    while stats.cachedBitmapBytes + pixels.bytes > policy.bitmapCacheBytes, let oldest = cache.min(by: { $0.value.use < $1.value.use }) {
      oldest.value.pixels.presentationTicket?.markRetired();stats.cachedBitmapBytes -= oldest.value.pixels.bytes; cache.removeValue(forKey: oldest.key); stats.evictions += 1
    }
    tick &+= 1; cache[key] = Cached(pixels: pixels, sourceKey: sourceKey, settledRecipeFingerprint: settledRecipe.flatMap { try? EditingFingerprint.of($0) }, use: tick,nativeProfileSemantic:nativeProfileSemantic); stats.cachedBitmapBytes += pixels.bytes
  }
  public func invalidate(_ id: DevelopmentPreviewSessionID) async {
    let thumbnailRunning=(thumbnailStepRegistration != nil && thumbnailActive?.request.preview.sessionID==id) ? worker:nil
    invalidateLease(id)
    if let thumbnailRunning{await thumbnailRunning.value}
    if !leases.values.contains(where:{$0.valid}){await joinThumbnailContextRetirement()}
    await flushRawBaseCommands()
  }
  private func invalidateLease(_ id: DevelopmentPreviewSessionID) {
    guard leases[id]?.valid == true else { return }
    leases[id]?.valid = false; stats.invalidations += 1
    if !leases.values.contains(where:{$0.valid}){requestThumbnailContextRetirement()}
    if let key = leases[id]?.key, !leases.values.contains(where:{$0.key == key && $0.valid}) {
      rawBaseRetiring.insert(key)
      scheduleIdleRawBaseInvalidation()
    }
    if let lease=leases[id]{interactiveProxyPool.retire(sourceKey:lease.key,generation:lease.generation)}
    for mailbox in channels.values where mailbox.sessionID == id { mailbox.revoke(.sourceInvalidated) }
    cancelMatching({ $0.request.sessionID == id }, error: .sourceInvalidated)
    cancelAnalysisMatching({ $0.request.preview.sessionID == id },error:.sourceInvalidated)
    cancelThumbnailMatching({$0.request.preview.sessionID==id},error:DevelopmentThumbnailError.staleSource)
  }
  private func invalidatePhysical(_ url: URL) {
    for id in Array(leases.keys) where location(leases[id]!.source) == url { invalidateLease(id) }
  }
  public func revalidate(_ id: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> PreviewSessionInfo {
    guard let original = leases[id] else { throw DevelopmentPreviewError.closed }
    invalidateLease(id)
    // Strict verification is mandatory even when a matching immutable capture already exists.
    let description = try describe(source), queue = ioQueue
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { do { try RenderFiles.verify(description.snapshot); continuation.resume() } catch { continuation.resume(throwing: error) } }
    }
    stats.sourceFullHashPasses += 1; stats.sourceHashBytes += UInt64(description.snapshot.byteCount)
    // An exclusive old source may surrender its slot after strict new-source verification.
    // The public lease remains invalid and closeable while the replacement opens.
    if original.key != description.key, sources[original.key]?.leases == Set([id]) {
      if active?.key == original.key || activeAnalysis?.key == original.key || (thumbnailStepRegistration != nil && thumbnailActive?.key==original.key), let worker { await worker.value }
      guard let current = leases[id], current.generation == original.generation else { throw DevelopmentPreviewError.closed }
      if sources[original.key]?.leases == Set([id]) {
        sources[original.key]?.leases.remove(id); cleanupSource(original.key)
      }
    }
    let temporary = try await open(source: source)
    await revalidationLeaseOpened()
    do { try checkStamp(temporary.id) }
    catch { await close(temporary.id); throw error }
    // Closing the old lease while verification/open suspends must also close the new temporary lease.
    // Do not remove the temporary before the guard: close() needs its ownership record to release it.
    guard let previous = leases[id] else { await close(temporary.id); throw DevelopmentPreviewError.closed }
    guard previous.generation == original.generation else { await close(temporary.id); throw DevelopmentPreviewError.superseded }
    guard let next = leases.removeValue(forKey: temporary.id) else { throw DevelopmentPreviewError.closed }
    next.watcher?.cancel(); previous.watcher?.cancel()
    sources[previous.key]?.leases.remove(id); sources[next.key]?.leases.remove(temporary.id)
    let info = addLease(source: source, key: next.key, stamp: next.stamp, native: sources[next.key]!.native, id: id)
    cleanupSource(previous.key)
    return info
  }
  public func close(_ id: DevelopmentPreviewSessionID) async {
    // Revoke admission synchronously before any channel/native join can suspend this actor.
    let lease = leases.removeValue(forKey: id)
    if let lease {
      lease.watcher?.cancel(); sources[lease.key]?.leases.remove(id)
      interactiveProxyPool.retire(sourceKey:lease.key,generation:lease.generation)
      if sources[lease.key]?.leases.isEmpty == true { rawBaseRetiring.insert(lease.key) }
    }
    if !leases.values.contains(where:{$0.valid}){requestThumbnailContextRetirement()}
    let channelIDs = channels.filter { $0.value.sessionID == id }.map(\.key)
    for channelID in channelIDs { channels[channelID]?.revoke(.closing) }
    cancelMatching({ $0.request.sessionID == id }, error: .closed)
    cancelAnalysisMatching({ $0.request.preview.sessionID == id },error:.closed)
    cancelThumbnailMatching({$0.request.preview.sessionID==id},error:DevelopmentThumbnailError.closed)
    for channelID in channelIDs { await closeProgressChannel(channelID) }
    // Repeated closes also join a first close that already removed the lease.
    if active?.request.sessionID == id || activeAnalysis?.request.preview.sessionID == id || (thumbnailStepRegistration != nil && thumbnailActive?.request.preview.sessionID==id), let running = worker { await running.value }
    if let lease { cleanupSource(lease.key) }
    await retireThumbnailSets(where:{$0.preview.sessionID==id})
    if thumbnailProxy?.key==lease?.key,thumbnailProxy?.value.sourceGeneration==lease?.generation {thumbnailProxy?.value.surface.retire();thumbnailProxy=nil;thumbnailProxyScope=nil}
    await flushRawBaseCommands()
    // A repeated close still joins a capture retirement that retained this removed lease ID.
    for retirement in Array(captureRetirements.values) where retirement.leases.contains(id) { await retirement.task.value }
    if !leases.values.contains(where:{$0.valid}){await joinThumbnailContextRetirement()}
  }
  public func closeAll() async {
    terminated = true
    requestThumbnailContextRetirement()
    for mailbox in channels.values { mailbox.revoke(.closing) }
    cancelMatching({ _ in true }, error: .closed)
    cancelAnalysisMatching({ _ in true },error:.closed)
    cancelThumbnailMatching({_ in true},error:DevelopmentThumbnailError.closed)
    quietWake?.cancel(); quietWake = nil; quietWakeID = nil
    for id in Array(channels.keys) { await closeProgressChannel(id) }
    for id in Array(leases.keys) { await close(id) }
    // Another close may already have removed its lease while its native task is still running.
    // Join globally before clearing any CI context; lease dictionary emptiness is insufficient.
    while let running = worker { await running.value }
    // In-flight opens are owned until their I/O task returns as well.
    for task in opening.values { _ = try? await task.value }
    for retirement in Array(captureRetirements.values) { await retirement.task.value }
    await retireThumbnailSets(where:{_ in true})
    for retirement in Array(thumbnailRetirements.values){await retirement.task.value}
    thumbnailProxy?.value.surface.retire();thumbnailProxy=nil;thumbnailProxyScope=nil;thumbnailSettled.removeAll();thumbnailWanted.removeAll()
    interactiveProxyPool.retire();interactivePresentation?.closeAndRetire();interactivePresentation=nil
    clearCaches()
    await flushRawBaseCommands()
    await joinThumbnailContextRetirement()
    if PreviewQALifecycleTrace.isEnabled {
      qaLifecycle(.lifecycle,.closedAll,id:UUID(),request:nil,sourceID:nil)
      PreviewQALifecycleTrace.flush()
    }
  }
  private static func queueName(_ request: DevelopmentPreviewRequest) -> String {
    if request.role == .comparison { return "比较预览" }
    switch request.quality {
    case .interactive: return "交互预览"
    case .settled: return "稳定预览"
    case .detail: return "原尺寸预览"
    }
  }

  public func performanceSnapshot() -> ImagePerformanceSnapshot {
    var waiting = ["交互预览": 0, "稳定预览": 0, "原尺寸预览": 0, "比较预览": 0,
      "分析": userAnalysis == nil ? 0 : 1, "直方图": backgroundHistogram == nil ? 0 : 1,
      "缩略图": (thumbnailPending == nil ? 0 : 1) + (thumbnailActive != nil && thumbnailStepRegistration == nil ? 1 : 0),
      "导出": 0, "画布": 0, "显影引擎": 0, "Shader 预热": 0, "Metal GPU": 0, "FlashRaw 解码": 0]
    for item in pending { waiting[Self.queueName(item.request), default: 0] += 1 }
    return ImagePerformanceTelemetry.shared.snapshot(pending: waiting, outstanding: ["原片读取": opening.count])
  }

  public func clearPerformanceSamples() { ImagePerformanceTelemetry.shared.reset() }

  public func statistics() -> PreviewStatistics { var value = stats; value.pendingRequests = pending.count; return value }
  private func cleanupSource(_ key: String) {
    guard captureRetirements[key] == nil, let record = sources[key], record.leases.isEmpty, active?.key != key, activeAnalysis?.key != key, thumbnailActive?.key != key, opening[key] == nil, openingWaiters[key, default: 0] == 0 else { return }
    interactiveProxyPool.retire(sourceKey:key)
    for (name, value) in cache where value.sourceKey == key { value.pixels.presentationTicket?.markRetired();stats.cachedBitmapBytes -= value.pixels.bytes; cache.removeValue(forKey: name) }
    rawBaseRetiring.insert(key)
    if thumbnailProxy?.key==key{thumbnailProxy?.value.surface.retire();thumbnailProxy=nil;thumbnailProxyScope=nil}
    record.native.context.clearCaches(); try? FileManager.default.removeItem(at: record.native.capture.deletingLastPathComponent())
    analysisImages.clear(capture: record.native.capture)
    stats.sourceSnapshotDiskBytes -= record.native.byteCount; sources.removeValue(forKey: key)
  }
  private func checkStamp(_ id: DevelopmentPreviewSessionID) throws {
    guard let lease = leases[id], lease.valid else { throw DevelopmentPreviewError.sourceInvalidated }
    stats.sourceStatChecks += 1
    let url = location(lease.source)
    guard let stamp = try? PreviewFileStamp.read(url), stamp == lease.stamp else {
      invalidatePhysical(url); throw DevelopmentPreviewError.sourceInvalidated
    }
    try checkCaptureAuthority(lease.key)
  }
  private func removeOpening(_ key: String) {
    opening.removeValue(forKey:key); openingIDs.removeValue(forKey:key)
    openingReusableCaptureIDs.removeValue(forKey:key); openingSizes.removeValue(forKey:key); openingLocations.removeValue(forKey:key)
  }
  private func checkCaptureAuthority(_ key: String) throws {
    guard captureRetirements[key] == nil else { throw DevelopmentPreviewError.sourceInvalidated }
    guard let record = sources[key], rawBasePool != nil,
      record.native.hasRAWFilter || captureAuthorityForTesting else { return }
    do { try record.native.validateCaptureAuthority() }
    catch {
      beginCaptureFault(key:key,captureID:record.native.captureID)
      throw DevelopmentPreviewError.sourceInvalidated
    }
  }
  private func beginCaptureFault(key: String, captureID: UUID) {
    guard captureRetirements[key] == nil, let record = sources[key], record.native.captureID == captureID else { return }
    let revoked = record.leases
    // Actor-synchronous fence: no cache replay/new lease can cross this point before suspension.
    for id in revoked { invalidateLease(id) }
    for (name,value) in cache where value.sourceKey == key {
      stats.cachedBitmapBytes -= value.pixels.bytes; cache.removeValue(forKey:name); stats.evictions += 1
    }
    rawBaseRetiring.insert(key)
    let running = (active?.key == key || activeAnalysis?.key == key || (thumbnailStepRegistration != nil && thumbnailActive?.key==key)) ? worker : nil
    let oldOpening = opening[key], oldOperationID = openingIDs[key]
    let task = Task {
      // This independent task may wait for finish(); finish itself never waits for this barrier.
      if let running { await running.value }
      if let oldOpening { _ = try? await oldOpening.value }
      await self.flushRawBaseCommands()
      self.completeCaptureFault(key:key,captureID:captureID,openingID:oldOperationID)
    }
    captureRetirements[key] = CaptureRetirement(captureID:captureID,leases:revoked,task:task)
    refreshChannels()
  }
  private func completeCaptureFault(key: String, captureID: UUID, openingID: UUID?) {
    guard captureRetirements[key]?.captureID == captureID else { return }
    if let openingID, openingIDs[key] == openingID { removeOpening(key) }
    if let record = sources[key], record.native.captureID == captureID {
      analysisImages.clear(capture: record.native.capture)
      record.native.context.clearCaches()
      try? FileManager.default.removeItem(at:record.native.capture.deletingLastPathComponent())
      stats.sourceSnapshotDiskBytes -= record.native.byteCount
      sources.removeValue(forKey:key)
    }
    captureRetirements.removeValue(forKey:key)
    pump()
  }
  /// Internal fixture seam; does not expose mutable CI state or widen product RAW eligibility.
  func capturedFileForTesting(_ id: DevelopmentPreviewSessionID) -> (id: UUID, url: URL)? {
    guard let lease = leases[id], let native = sources[lease.key]?.native else { return nil }
    return (native.captureID,native.capture)
  }
  private func attachWatcher(_ id: DevelopmentPreviewSessionID) {
    guard let lease = leases[id] else { return }
    let url = location(lease.source), fd = Darwin.open(url.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .revoke], queue: .global(qos: .utility))
    let generation = lease.generation, stamp = lease.stamp
    source.setEventHandler { [weak self, weak source] in
      // Snapshot bits at handler time; a weak source avoids a source→handler→source cycle.
      guard let source else { return }; let bits = source.data.rawValue
      Task { await self?.receiveSourceWatcherEvent(id, generation:generation, url:url, stamp:stamp, rawBits:bits) }
    }
    source.setCancelHandler { Darwin.close(fd) }; leases[id]?.watcher = source; source.resume()
  }
  /// Internal registration-only seam; product callbacks and deterministic tests use the same guard.
  func receiveSourceWatcherEvent(_ id: DevelopmentPreviewSessionID, generation: UInt64,
                                 url: URL, stamp: PreviewFileStamp, rawBits: UInt) {
    guard let lease = leases[id], lease.valid, lease.generation == generation,
      location(lease.source) == url, lease.stamp == stamp else { return }
    let event = DispatchSource.FileSystemEvent(rawValue:rawBits)
    if !event.isEmpty && event.subtracting(.attrib).isEmpty,
       let current = try? PreviewFileStamp.read(url), current == stamp {
      // atime is deliberately outside the existing verified identity. ImageIO may emit
      // NOTE_ATTRIB for access-time changes; do not revoke an otherwise identical source.
      return
    }
    // Changed/unreadable identity, dangerous/mixed/unknown or empty events remain fail-closed.
    invalidatePhysical(url)
  }
  private func installPressureMonitor() {
    guard pressure == nil else { return }
    let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    monitor.setEventHandler { [weak self] in Task { await self?.receiveMemoryPressure() } }
    pressure = monitor; monitor.resume()
  }
  private func receiveMemoryPressure() {
    guard let event = pressure?.data else { return }
    handleMemoryPressure(critical: event.contains(.critical), normal: event.contains(.normal))
  }
  func handleMemoryPressure(critical: Bool = false, normal: Bool = false) {
    criticalPressure = critical
    if normal { return }
    FlashRawCanonicalTexturePool.shared.retire()
    cancelThumbnailMatching({_ in true},error:DevelopmentThumbnailError.budgetUnavailable)
    if policy.interactiveEvaluation != .canonical {
      cancelMatching({$0.interactivePlan != nil || $0.nativePointwisePlan != nil},error:.memoryBudgetExceeded)
      interactiveProxyPool.retire();interactivePresentation?.retireOutstanding()
    }
    if critical { requestThumbnailContextRetirement(); cancelMatching({ _ in true }, error: .memoryBudgetExceeded); cancelAnalysisMatching({ _ in true },error:.memoryBudgetExceeded) }
    if worker != nil { clearAfterJoin = true } else {
      clearCaches()
      Task { await self.flushRawBaseCommands() }
    }
  }
  private func clearCaches() {
    analysisImages.clear()
    interactiveProxyPool.retire()
    portableMetalPrograms.removeAll()
    thumbnailProxy?.value.surface.retire();thumbnailProxy=nil;thumbnailProxyScope=nil
    rawBaseClearRequested = true
    for value in cache.values{value.pixels.presentationTicket?.markRetired()}
      stats.evictions += UInt64(cache.count); cache.removeAll(); stats.cachedBitmapBytes = 0
    for source in sources.values { source.native.context.clearCaches() }
    // clearCaches is reached after this Service's actual native join. Other export/AI graph
    // aliases keep their backing charged; clearing ready ownership never forges global union0.
    DevelopmentPhotoFilterResourceStore.shared.trimReady()
  }
  private func scheduleIdleRawBaseInvalidation() {
    guard worker == nil, rawBasePool != nil, rawBaseInvalidationFlush == nil else { return }
    rawBaseInvalidationFlush = Task {
      await self.flushRawBaseCommands()
      self.rawBaseInvalidationFlush = nil
    }
  }
  private func applyRawBaseStatistics(_ value: RawBaseStatisticsSnapshot) {
    guard value.version >= rawBaseStatsVersion else { return }; rawBaseStatsVersion = value.version
    stats.rawBaseResidentBytes = value.residentBytes; stats.rawBaseReservedBytes = value.reservedBytes
    stats.rawBaseBuildingBytes = value.buildingBytes; stats.rawBasePinnedBytes = value.pinnedBytes
    stats.rawBaseRetiredBytes = value.retiredBytes; stats.rawBaseHits = value.hits
    stats.rawBaseFills = value.fills; stats.rawBaseMisses = value.misses; stats.rawBaseEvictions = value.evictions
  }
  private func flushRawBaseCommands() async {
    guard let pool = rawBasePool else { rawBaseRetiring.removeAll(); rawBaseClearRequested = false; return }
    while true {
      if let running = rawBaseMaintenance {
        let snapshot = await running.task.value
        if rawBaseMaintenance?.id == running.id { rawBaseMaintenance = nil }
        applyRawBaseStatistics(snapshot)
        continue
      }
      guard !rawBaseRetiring.isEmpty || rawBaseClearRequested else { return }
      let keys = rawBaseRetiring, clear = rawBaseClearRequested
      rawBaseRetiring.removeAll(); rawBaseClearRequested = false
      let command = Task { await pool.maintain(retiring:keys,clear:clear) }
      rawBaseMaintenance = (UUID(),command)
    }
  }
  private func location(_ source: DevelopmentPreviewSource) -> URL {
    switch source { case .raw(let value): return value.sourceLocation; case .artifact(let url, _): return url.standardizedFileURL }
  }
  private func describe(_ source: DevelopmentPreviewSource) throws -> (key: String, snapshot: EditingSourceSnapshot, artifact: Bool) {
    switch source {
    case .raw(let value):
      let identity = [value.projectID, value.assetID, value.contentSHA256, String(value.byteCount), value.admissionFingerprint]
      let data = try JSONEncoder().encode(identity)
      return (digest(data), value, false)
    case .artifact(let url, let value):
      try value.validate()
      let identity = try JSONEncoder().encode([value.sha256, String(value.byteCount), value.encoding, String(value.bitDepth), value.iccProfileSHA256 ?? ""])
      let key = digest(identity)
      return (key, EditingSourceSnapshot(projectID: "preview-artifact", assetID: key, contentSHA256: value.sha256, byteCount: value.byteCount, admissionFingerprint: key, sourceLocation: url), true)
    }
  }
  private func requestsSharedFIT(_ plan:PreviewNativePointwisePlanV1?) -> Bool {
    guard qaSharedFITIntermediate,policy.nativePointwiseProfile,let plan else { return false }
    if plan.canonicalFullChecks {
      return plan.preserveVerifiedInput && plan.fallback == nil && !plan.semanticLegacy &&
        ((plan.canonicalNaturalFiniteProofEnabled && plan.naturalCurveBinding != nil) ||
         (plan.canonicalGlobalFiniteProofEnabled && plan.canonicalGlobalRecipeBinding != nil && plan.naturalCurveBinding == nil))
    }
    return plan.preserveVerifiedInput && plan.fallback == nil && !plan.semanticLegacy && !plan.canonicalFullChecks
  }
  private func requestsGrainFinalTransport(_ request:DevelopmentPreviewRequest,sourceKey:String)->Bool {
    guard grainFinalTransportEnabled,
      renderOverride==nil,request.role == .primary,request.quality == .interactive || request.quality == .settled,
      let native=sources[sourceKey]?.native,let lease=leases[request.sessionID],case .raw=lease.source else{return false}
    return PreviewGrainFinalTransportV1.eligible(recipe:request.recipe,sourceIsRAW:native.hasRAWFilter,artifact:native.artifact,maxPixel:request.viewport.maxPixel)
  }
  private func canonicalHalfFIT(_ request: DevelopmentPreviewRequest, sourceKey: String) -> CanonicalHalfFIT? {
    if settledUsesViewport(request) { return nil }
    guard Self.qaCanonicalHalfFIT || PreviewPortableHalfFIT.enabled || PreviewPortableMaskTone.enabled || PreviewPortableGrading.enabled,
          renderOverride == nil, request.role == .primary,
          request.viewport.maxPixel == 2400, let adjustments = request.recipe.adjustmentsV3,
          let native = sources[sourceKey]?.native else { return nil }
    if PreviewPortableHalfFIT.enabled, native.qualifiesPortableHalfFITRecipe(adjustments) { return .portable }
    if PreviewPortableMaskTone.enabled, native.qualifiesPortableMaskHalfFIT(adjustments) { return .frozenMask }
    if PreviewPortableGrading.enabled, native.qualifiesPortableGradingHalfFIT(adjustments) { return .grading }
    return Self.qaCanonicalHalfFIT && native.qualifiesHalfFITRecipe(adjustments) ? .coreImage : nil
  }
  private func pixelKey(_ request: DevelopmentPreviewRequest, sourceKey: String,interactivePlan:PreviewInteractivePlan?=nil,nativePointwisePlan:PreviewNativePointwisePlanV1?=nil,naturalSharedFITOverride:Bool?=nil,canonicalSharedFITOverride:Bool?=nil,settledHalfFITReplay:Bool=false) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    // Interactive and settled are both the same canonical P1 pixels, so share cache.
    var pixelRecipe=request.recipe
    if nativePointwisePlan?.semanticLegacy==true {
      guard let legacy=try DevelopmentRendererV3.legacyEquivalent(request.recipe) else { throw DevelopmentPreviewError.invalidRequest }
      pixelRecipe=legacy // Actual request/full FP and frame metadata remain untouched.
    }
    let data = try encoder.encode(canonicalPixelRepresentation(pixelRecipe))
    let filterIdentity = try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(pixelRecipe,resources:filterResourcesForTesting ?? .shared)
    let suffix = filterIdentity.map { ":photo-filter:"+$0+":" } ?? ""
    let nativeSuffix = nativePointwisePlan?.semanticLegacy==true ? "":(try nativePointwisePlan?.keySuffix() ?? "")
    let fitSuffix:String
    if nativePointwisePlan?.naturalCurveBinding != nil {
      fitSuffix=PreviewNativePointwiseV1.naturalSharedFITKeySuffix(requested:naturalSharedFITOverride ?? requestsSharedFIT(nativePointwisePlan))
    }else if nativePointwisePlan?.canonicalFullChecks==true && nativePointwisePlan?.canonicalGlobalFiniteProofEnabled==true {
      fitSuffix=PreviewNativePointwiseV1.canonicalSharedFITKeySuffix(requested:canonicalSharedFITOverride ?? requestsSharedFIT(nativePointwisePlan))
    }else{fitSuffix=requestsSharedFIT(nativePointwisePlan) ? "/qa-shared-fit:"+PreviewNativePointwiseV1.sharedFITIntermediateVersion : ""}
    let proxySuffix=(try interactivePlan?.keySuffix() ?? "")+nativeSuffix+fitSuffix
    let legacyGrain = sources[sourceKey]?.native.hasRAWFilter == true && request.recipe.adjustmentsV3?.blackAndWhite.requiresLegacyGrainCanonicalInput == true
    let grainInputSuffix = legacyGrain ? ":"+DevelopmentGrainSamplingEngineV1.legacyInputIdentity:""
    let grainTransportSuffix=PreviewGrainFinalTransportV1.keySuffix(requested:requestsGrainFinalTransport(request,sourceKey:sourceKey))
    let brillianceSuffix=DevelopmentBrilliancePublicV1.active(request.recipe) ? "/"+DevelopmentBrilliancePublicV1.version+"/"+DevelopmentBrilliancePublicV1.transportVersion:""
    let brillianceNativeSuffix=DevelopmentBrillianceNativeRGV1.keySuffix(request.recipe.adjustmentsV3?.light,
      sourceIsRAW:sources[sourceKey]?.native.hasRAWFilter == true)
    let dehazeTIFFSuffix=requestsDehazeTIFF(request,sourceKey:sourceKey) ? "/"+DevelopmentDehazeTIFFPreviewV1.version:""
    let dehazeCoverageSuffix=DevelopmentDehazeEngineV3.rawPositiveV2CoverageSuffix(request.recipe.adjustmentsV3?.advancedDetail,
      sourceIsRAW:sources[sourceKey]?.native.hasRAWFilter == true) +
      (requestsDehazeTIFF(request,sourceKey:sourceKey) ? "":DevelopmentDehazeNativeRfV1.keySuffix(request.recipe.adjustmentsV3?.advancedDetail))
    let halfFITQuality = request.quality == .settled || (settledHalfFITReplay && request.quality == .interactive)
    let halfFITSuffix = halfFITQuality ? canonicalHalfFIT(request,sourceKey:sourceKey).map { "/" + $0.rawValue } ?? "" : ""
    return digest(Data((sourceKey + ":canonical-v1:" + String(request.viewport.maxPixel) + ":"+windowSuffix(request.viewport.window)+suffix+proxySuffix+grainInputSuffix+grainTransportSuffix+dehazeCoverageSuffix+brillianceSuffix+brillianceNativeSuffix+dehazeTIFFSuffix+halfFITSuffix).utf8) + data)
  }
  /// A window changes which pixels a native frame contains, so it belongs in the identity.
  /// Settled and interactive frames ignore the window, and so does their key.
  /// A window is meaningful only for the native 1:1 frame. Everything else is a whole-canvas
  /// render, so a window there would silently change the meaning of the request.
  static func validateWindow(_ window:CGRect?, quality:PreviewQuality) throws {
    guard let window else { return }
    guard quality == .detail else { throw DevelopmentPreviewError.invalidRequest }
    let values = [window.minX,window.minY,window.width,window.height]
    guard values.allSatisfy({ $0.isFinite }),
          window.minX >= 0, window.minY >= 0, window.width > 0, window.height > 0,
          window.maxX <= 1.0000001, window.maxY <= 1.0000001 else {
      throw DevelopmentPreviewError.invalidRequest
    }
  }
  private func windowSuffix(_ window:CGRect?)->String{
    guard let window, window != CGRect(x:0,y:0,width:1,height:1) else { return "" }
    return ":window:"+String(format:"%.6f,%.6f,%.6f,%.6f",window.minX,window.minY,window.width,window.height)
  }
  private func requestsDehazeTIFF(_ request:DevelopmentPreviewRequest,sourceKey:String)->Bool{
    guard qaDehazeTIFFPreview,policy.contextMemoryLimitMiB==512,renderOverride==nil,
      request.role == .primary,request.quality != .detail,request.viewport.maxPixel==2400,
      DevelopmentDehazeTIFFPreviewV1.recipeDomain(request.recipe),let native=sources[sourceKey]?.native else{return false}
    return DevelopmentDehazeTIFFPreviewV1.sourceDomain(native)
  }
  private func settledUsesViewport(_ request:DevelopmentPreviewRequest)->Bool {
    guard policy.settledTransport == .viewport, request.quality == .settled,
          request.recipe.schemaVersion == 3, request.role == .primary,
          request.viewport.maxPixel > 0, request.viewport.maxPixel <= 2400 else { return false }
    return true
  }
  private func usesInteractiveEvaluation(_ request:DevelopmentPreviewRequest)->Bool {
    guard policy.interactiveEvaluation != .canonical, request.recipe.schemaVersion==3, request.role == .primary,
          request.viewport.maxPixel>0, request.viewport.maxPixel<=2400 else { return false }
    if request.quality == .interactive { return true }
    return settledUsesViewport(request) && policy.interactiveEvaluation == .proxyV1
  }
  private func prepareInteractivePlan(_ request:DevelopmentPreviewRequest,sourceKey:String)throws->PreviewInteractivePlan? {
    if DevelopmentBrilliancePublicV1.active(request.recipe) || requestsDehazeTIFF(request,sourceKey:sourceKey){return nil}
    guard policy.interactiveEvaluation == .proxyV1,usesInteractiveEvaluation(request),renderOverride==nil,let native=sources[sourceKey]?.native,
      let lease=leases[request.sessionID],case let .raw(snapshot)=lease.source else{return nil}
    return try native.interactivePlan(recipe:request.recipe,sourceKey:sourceKey,generation:request.sourceGeneration,verifiedContentID:snapshot.contentSHA256,maxPixel:request.viewport.maxPixel)
  }
  private func usesNativeProfile(_ request:DevelopmentPreviewRequest)->Bool {
    policy.nativePointwiseProfile && policy.interactiveEvaluation == .nativePointwiseCertificateV1 &&
      request.recipe.schemaVersion==3 && request.role == .primary && request.viewport.maxPixel==2400 &&
      (request.quality == .interactive || request.quality == .settled)
  }
  private func prepareNativePointwisePlan(_ request:DevelopmentPreviewRequest,sourceKey:String)throws->PreviewNativePointwisePlanV1? {
    if DevelopmentBrilliancePublicV1.active(request.recipe) || requestsDehazeTIFF(request,sourceKey:sourceKey){return nil}
    if qaNeutralOwnerBootstrap,policy.nativePointwiseProfile,policy.nativeCanonicalFiniteProof,
      policy.interactiveEvaluation == .nativePointwiseCertificateV1,policy.contextMemoryLimitMiB == 512,
      renderOverride == nil,request.role == .primary,request.quality == .settled,request.viewport.maxPixel == 2400,
      let native=sources[sourceKey]?.native,let lease=leases[request.sessionID],case let .raw(snapshot)=lease.source,
      let plan=try PreviewNeutralOwnerBootstrapV1.plan(native:native,recipe:request.recipe,sourceKey:sourceKey,
        generation:request.sourceGeneration,verifiedContentID:snapshot.contentSHA256,maxPixel:request.viewport.maxPixel) {
      return plan
    }
    guard policy.interactiveEvaluation == .nativePointwiseCertificateV1,
      usesInteractiveEvaluation(request) || usesNativeProfile(request),renderOverride==nil,
      let native=sources[sourceKey]?.native,let lease=leases[request.sessionID],case let .raw(snapshot)=lease.source else { return nil }
    if qaNaturalCurveFiniteProof,usesNativeProfile(request),native.hasRAWFilter,
      try PreviewNaturalCurveFiniteEvidenceV1.domain(request.recipe,size:native.nativeSize) {
      return try native.nativeNaturalCurvePlan(recipe:request.recipe,sourceKey:sourceKey,generation:request.sourceGeneration,
        verifiedContentID:snapshot.contentSHA256,maxPixel:request.viewport.maxPixel,proofEnabled:true)
    }
    let profileDomain:Bool
    if usesNativeProfile(request) { profileDomain=try PreviewNativeInputProfileV1.domain(request.recipe,size:native.nativeSize) }
    else { profileDomain=false }
    if request.quality == .settled && !profileDomain { return nil }
    var plan=try native.nativePointwisePlan(recipe:request.recipe,sourceKey:sourceKey,generation:request.sourceGeneration,
      verifiedContentID:snapshot.contentSHA256,maxPixel:request.viewport.maxPixel)
    plan.preserveVerifiedInput=profileDomain
    plan.canonicalFullChecks=profileDomain && request.quality == .settled
    plan.canonicalGlobalFiniteProofEnabled=policy.nativeCanonicalFiniteProof && plan.canonicalFullChecks && plan.fallback==nil
    if plan.canonicalGlobalFiniteProofEnabled {plan.canonicalGlobalRecipeBinding=try PreviewNativePointwiseCertificateV2.Binding(request.recipe)}
    plan.semanticLegacy=profileDomain && plan.fallback == .legacyDelegate
    return plan
  }
  private func recordNativeProfileCacheHit(_ plan:PreviewNativePointwisePlanV1?) {
    guard let plan,plan.preserveVerifiedInput else { return }
    if plan.canonicalNaturalFiniteProofEnabled {stats.nativeNaturalProvenBitmapHits &+= 1;stats.nativeProfileLastRoute=10}
    else if plan.semanticLegacy { stats.nativeProfileSemanticBitmapHits &+= 1;stats.nativeProfileLastRoute=3 }
    else if plan.canonicalGlobalFiniteProofEnabled {
      stats.nativeProfileCanonicalProvenBitmapHits &+= 1;stats.nativeProfileLastRoute=8
    } else {stats.nativeProfileLastRoute=6} // Actual replay, never a new consumed proof/full scan.
  }
  func nativePointwiseReceiptForTesting()->PreviewNativePointwiseReceiptV1? { nativePointwiseLastReceipt }
  private func nativeProfileCacheTicketOpen(_ pixels:PreviewPixels)->Bool {
    guard let scope=interactivePresentation,let ticket=pixels.presentationTicket else { return false }
    do { try scope.requireOpenAdmission();try ticket.requireOpenAdmission();return true }
    catch { return false }
  }
  /// A subsequent request for this exact overlay must not return its older approximate
  /// bitmap ahead of the native mask that was just accepted at the same display size.
  private func retireEarlierSharpenMaskProxy(_ request:DevelopmentPreviewRequest,sourceKey:String) {
    guard Self.replaysExactDisplay, policy.interactiveEvaluation == .proxyV1,
          let p=request.recipe.adjustmentsV3, PreviewInteractiveDetailGuide.isPureSharpen(p,maskPreview:true) else { return }
    let earlier = DevelopmentPreviewRequest(sessionID:request.sessionID,sourceGeneration:request.sourceGeneration,
      consumerID:request.consumerID,role:request.role,revision:request.revision,recipe:request.recipe,
      quality:.interactive,viewport:request.viewport)
    guard let plan=try? prepareInteractivePlan(earlier,sourceKey:sourceKey), plan.isProxy,
          let key=try? pixelKey(earlier,sourceKey:sourceKey,interactivePlan:plan),
          let old=cache[key], old.pixels.approximation != nil else { return }
    old.pixels.presentationTicket?.markRetired()
    cache.removeValue(forKey:key)
    stats.cachedBitmapBytes -= old.pixels.bytes
    stats.evictions &+= 1
  }

  private func canReplayInteractive(_ plan:PreviewInteractivePlan?,nativePointwisePlan:PreviewNativePointwisePlanV1?=nil,pixels:PreviewPixels)->Bool {
    // Canonical grain also owns managed storage, independently of experimental plans.
    if pixels.actualGrainFinalTransport != nil && !nativeProfileCacheTicketOpen(pixels) { return false }
    // No uncharged settled bitmap is adopted into an opt-in request. Managed canonical
    // fallback keys may be reused; proxy keys can never satisfy settled/detail/analysis.
    if let nativePointwisePlan {
      if nativePointwisePlan.neutralOwnerBootstrap {
        return nativeProfileCacheTicketOpen(pixels) && pixels.approximation == nil &&
          pixels.nativePointwise?.reason == PreviewNeutralOwnerBootstrapV1.version &&
          pixels.nativePointwise?.owner != nil
      }
      guard pixels.managedPresentation else { return false }
      if nativePointwisePlan.preserveVerifiedInput && !nativeProfileCacheTicketOpen(pixels) { return false }
      if nativePointwisePlan.semanticLegacy { return pixels.approximation==nil }
      if nativePointwisePlan.canonicalFullChecks {
        if nativePointwisePlan.canonicalNaturalFiniteProofEnabled {
          guard qaNaturalCurveFiniteProof,let receipt=pixels.nativePointwise,
            receipt.canonicalGlobalFiniteProofID==PreviewNaturalCurveFiniteEvidenceV1.version,
            receipt.canonicalGlobalFiniteStage==PreviewNaturalCurveFiniteEvidenceV1.stage,
            receipt.canonicalProofFITChecked,!receipt.canonicalFullChecks,!receipt.canonicalNaturalSynthetic,
            receipt.canonicalNaturalProofConsumptions==1,receipt.canonicalNaturalGlobalScans==0,
            receipt.canonicalNaturalLUTSHA256==nativePointwisePlan.naturalCurveBinding?.lutSHA256,
            let binding=receipt.canonicalGlobalFiniteBinding,EditingFingerprint.isSHA256(binding),
            PreviewNativePointwiseV1.naturalSharedFITReplayMatches(receipt,requested:requestsSharedFIT(nativePointwisePlan)) else{return false}
          return pixels.approximation==nil
        }
        if nativePointwisePlan.canonicalGlobalFiniteProofEnabled {
          guard policy.nativeCanonicalFiniteProof,let receipt=pixels.nativePointwise,
            receipt.canonicalGlobalFiniteProofID==PreviewCanonicalFiniteEvidenceV1.version,
            receipt.canonicalGlobalFiniteStage==PreviewCanonicalFiniteEvidenceV1.stage,
            receipt.canonicalProofFITChecked,!receipt.canonicalFullChecks,
            let binding=receipt.canonicalGlobalFiniteBinding,EditingFingerprint.isSHA256(binding),
            PreviewNativePointwiseV1.canonicalSharedFITReplayMatches(receipt,requested:requestsSharedFIT(nativePointwisePlan)) else{return false}
          return pixels.approximation==nil
        }
        return pixels.approximation==nil && pixels.nativePointwise?.canonicalFullChecks==true
      }
      return true
    }
    return plan==nil || pixels.managedPresentation
  }

  private func replayBitmap(_ request: DevelopmentPreviewRequest, sourceKey: String, outputKey: String,
                            interactivePlan: PreviewInteractivePlan?, nativePointwisePlan: PreviewNativePointwisePlanV1?)
      -> (key: String, pixels: PreviewPixels)? {
    var key = outputKey
    // A canonical interactive request can read an existing exact primary frame.
    // Its normal admission key remains the destination for any new render.
    if Self.qaCanonicalHalfFIT || PreviewPortableHalfFIT.enabled, request.quality == .interactive, request.role == .primary,
       interactivePlan == nil, nativePointwisePlan == nil,
       let exact = try? pixelKey(request,sourceKey:sourceKey,settledHalfFITReplay:true), exact != outputKey,
       let existing = cache[exact], let fingerprint = existing.settledRecipeFingerprint,
       fingerprint == latestRecipeFingerprint[request.consumerID], existing.pixels.approximation == nil {
      key = exact
    }
    guard var hit = cache[key], canReplayInteractive(interactivePlan,nativePointwisePlan:nativePointwisePlan,pixels:hit.pixels)
      else { return nil }
    tick &+= 1
    hit.use = tick
    cache[key] = hit
    stats.cacheHits += 1
    recordNativeProfileCacheHit(nativePointwisePlan)
    return (key, hit.pixels)
  }

  /// Read-only access to the actual service scope; tests exercise real reservation retirement.
  func presentationScopeForTesting()->PreviewPresentationScope? { interactivePresentation }
  func interactiveProxyStatisticsForTesting()->PreviewInteractiveProxyPool.Statistics {
    interactiveProxyPool.statistics(ledger:interactivePresentation?.ledger ?? .shared)
  }
  func interactiveKnownOwnedForTesting()->[String:Int] {
    let ledger=(interactivePresentation?.ledger ?? .shared).statistics
    // Managed cached images ALIAS presentation tickets. Only unmanaged canonical cache bytes
    // are added separately. GPU is a subset of shared CPU, not another physical union summand.
    let ordinaryCache=cache.values.filter{!$0.pixels.managedPresentation}.reduce(0){$0+$1.pixels.bytes}
    return ["presentationCPU":ledger.chargedCPUBytes,"presentationGPUAliasSubset":ledger.chargedGPUBytes,
      "presentationRetiredCPU":ledger.retiredCPUBytes,"ordinaryCanonicalCachedCPU":ordinaryCache,
      "rawBaseResidentCPU":stats.rawBaseResidentBytes,"rawBaseRetiredCPU":stats.rawBaseRetiredBytes,
      "rawBaseReservedCPU":stats.rawBaseReservedBytes,"rawBaseBuildingCPU":stats.rawBaseBuildingBytes,
      // A native CV/IOSurface is GPU-accessible too. This is the SAME allocation subset,
      // outside presentation's allowance, never an extra physical summand or a claimed GPU0.
      "rawBaseGPUAccessibleAliasSubset":stats.rawBaseResidentBytes+stats.rawBaseRetiredBytes+stats.rawBaseBuildingBytes]
  }
  func bitmapCacheKeyForTesting(_ request:DevelopmentPreviewRequest,sourceKey:String)throws->String {
    try pixelKey(request,sourceKey:sourceKey,interactivePlan:prepareInteractivePlan(request,sourceKey:sourceKey),nativePointwisePlan:prepareNativePointwisePlan(request,sourceKey:sourceKey))
  }
  private func canonicalPixelRepresentation(_ actual: DevelopmentRecipe) throws -> DevelopmentRecipe {
    // Validate the actual request before removing any fields, including pixel-neutral memory values.
    try actual.validate()
    guard actual.schemaVersion == 2, actual.engineVersion == "rawmaster-color-v2", actual.color?.isNeutral == true else { return actual }
    // The v2 renderer delegates this exact case to v1. Only bitmap identity uses this copy.
    var pixels = actual
    pixels.schemaVersion = 1; pixels.engineVersion = "core-image-v1"; pixels.color = nil
    return pixels
  }
  private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private func nextSchedulingSequence() -> UInt64 { schedulingSequence &+= 1; return schedulingSequence }
  private func admittedDehazeContext(_ native:PreviewNativeSource,key:String,source:DevelopmentLocalEditSourceBinding,
                                     generation:UInt64)throws->DevelopmentDehazeContextV1 {
    do { return try native.dehazeContext(source:source,generation:generation) }
    catch let fault as PreviewCaptureFault {
      beginCaptureFault(key:key,captureID:fault.captureID);throw DevelopmentPreviewError.sourceInvalidated
    }
  }
  private func validateAnalysisInput(_ request: DevelopmentAnalysisRequest) throws -> Lease {
    try request.validate()
    let support:DevelopmentRecipe?
    if case .prepareDehaze=request.operation { support=try DevelopmentDehazeAnalysisV3.projection(request).samplingRecipe }
    else if case .cropAutomatic=request.operation { support=try DevelopmentAnalysisEngine.samplingRecipe(request) }
    else { support=nil }
    let lease = try validate(request.preview,supportRecipe:support)
    if request.sampling == .blackAndWhiteSummaryStripes32V2 {
      guard sources[lease.key]?.native.hasRAWFilter == true else { throw DevelopmentPreviewError.invalidRequest }
    }
    if request.sampling == .blackAndWhiteSummaryResident32V3 {
      guard qaBWSummaryResident,let native=sources[lease.key]?.native else { throw DevelopmentV3Error.unsupportedAnalysis }
      try DevelopmentBWSummaryResidentV3.requireRequest(request,sourceIsRAW:native.hasRAWFilter,artifact:native.artifact)
    }
    if DevelopmentNaturalCurvePickerV1.isNatural(request) {
      guard let native=sources[lease.key]?.native else { throw DevelopmentPreviewError.invalidRequest }
      try DevelopmentNaturalCurvePickerV1.validateAdmission(request.preview.recipe.adjustmentsV3!,sourceIsRAW:native.hasRAWFilter)
    }
    if case .prepareDehaze=request.operation {
      guard let native=sources[lease.key]?.native,case .raw(let source)=lease.source else { throw DevelopmentPreviewError.invalidRequest }
      let binding=DevelopmentLocalEditSourceBinding(sourceContentID:source.contentSHA256,exifOrientation:native.originalEXIFOrientation,
        orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height))
      guard request.dehazeInputV1?.context == (try admittedDehazeContext(native,key:lease.key,source:binding,generation:lease.generation)) else { throw DevelopmentDehazePreparationError.staleInput }
    }
    guard case .raw = lease.source else { throw DevelopmentPreviewError.invalidRequest }
    if !request.operation.isHistogram, request.preview.role != .primary { throw DevelopmentPreviewError.invalidRequest }
    if let visible = latest[request.preview.consumerID], visible.0 == request.preview.sessionID,
      visible.1 == request.preview.sourceGeneration {
      guard visible.2 <= request.preview.revision else { throw DevelopmentPreviewError.superseded }
      if visible.2 == request.preview.revision {
        guard latestRecipeFingerprint[request.preview.consumerID] == request.presentedRecipeFingerprint else { throw DevelopmentPreviewError.superseded }
      }
    }
    return lease
  }
  /// Two independent bounded pending slots: user analysis latest1 and background histogram latest1.
  /// A histogram cannot replace a user command. Neither slot creates a second native worker.
  public func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult {
    if request.sampling == .blackAndWhiteSummaryResident32V3 {
      guard qaBWSummaryResident,rawBasePool != nil,analysisOverride == nil else { throw DevelopmentV3Error.unsupportedAnalysis }
    }
    try Task.checkCancellation(); let lease = try validateAnalysisInput(request)
    guard !criticalPressure else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    guard activeAnalysis?.request.operationID != request.operationID, userAnalysis?.request.operationID != request.operationID,
      backgroundHistogram?.request.operationID != request.operationID else { throw DevelopmentPreviewError.invalidRequest }
    guard case .raw(let snapshot) = lease.source else { throw DevelopmentPreviewError.invalidRequest }
    let old = request.operation.isHistogram ? backgroundHistogram:userAnalysis
    if let old {
      let previous = old.request.preview, next = request.preview
      guard previous.consumerID == next.consumerID, previous.sessionID == next.sessionID,
        previous.sourceGeneration == next.sourceGeneration else { throw DevelopmentPreviewError.capacityExceeded }
    }
    let token = UUID()
    if !request.operation.isHistogram{cancelThumbnailMatching({_ in true},error:DevelopmentThumbnailError.superseded)}
    return try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if let old { deliverAnalysis(old,.failure(DevelopmentPreviewError.superseded)); analysisStats.superseded += 1 }
        let item = PendingAnalysis(token:token,request:request,key:lease.key,sourceContentID:snapshot.contentSHA256,
          sequence:nextSchedulingSequence(),queuedAt:request.operation.isHistogram ? now():0,continuation:continuation)
        if request.operation.isHistogram { backgroundHistogram = item } else { userAnalysis = item }
        if let active = activeAnalysis,
          active.request.preview.consumerID == request.preview.consumerID,
          active.request.preview.sessionID == request.preview.sessionID,
          active.request.preview.sourceGeneration == request.preview.sourceGeneration,
          (!request.operation.isHistogram || active.request.operation.isHistogram) {
          cancelAnalysisMatching({ $0.token == active.token },error:.superseded)
        }
        analysisStats.submitted += 1; pump()
      }
    },onCancel:{ Task { await self.cancelAnalysisToken(token) } })
  }
  public func analysisStatistics() -> DevelopmentAnalysisStatistics {
    var value = analysisStats; value.pendingUser = userAnalysis == nil ? 0:1
    analysisImages.fillStatistics(&value)
    value.pendingHistogram = backgroundHistogram == nil ? 0:1; value.active = activeAnalysis == nil ? 0:1; return value
  }
  public func cancelAnalysis(consumerID: PreviewConsumerID) {
    cancelAnalysisMatching({ $0.request.preview.consumerID == consumerID },error:.superseded); pump()
  }
  /// Revoke only this captured operation and await its actual native worker, even if analyze already failed early.
  /// This never performs consumer-wide cancellation or waits for a newer preview/analysis worker.
  public func cancelAnalysisAndJoin(_ request: DevelopmentAnalysisRequest) async {
    func sameOperation(_ old: DevelopmentAnalysisRequest) -> Bool {
      old.operationID == request.operationID && old.preview.sessionID == request.preview.sessionID &&
        old.preview.sourceGeneration == request.preview.sourceGeneration && old.preview.consumerID == request.preview.consumerID &&
        old.preview.revision == request.preview.revision && old.expectedRecipeFingerprint == request.expectedRecipeFingerprint &&
        old.presentedRecipeFingerprint == request.presentedRecipeFingerprint && old.stage == request.stage &&
        old.operation == request.operation && old.sampling == request.sampling && old.dehazeInputV1 == request.dehazeInputV1
    }
    // Capture BEFORE cancellation/pump. finishAnalysis may subsequently admit a different worker.
    let oldWorker: Task<Void, Never>?
    if let identity = analysisWorkerIdentity, sameOperation(identity.request) { oldWorker = worker }
    else { oldWorker = nil }
    cancelAnalysisMatching({ sameOperation($0.request) },error:.superseded)
    pump()
    if let oldWorker { await oldWorker.value }
  }
  private func cancelAnalysisToken(_ token: UUID) { cancelAnalysisMatching({ $0.token == token },error:.superseded); pump() }
  private func deliverAnalysis(_ item: PendingAnalysis, _ result: Result<DevelopmentAnalysisResult,Error>) {
    guard item.deliveryEnabled else { return }; item.continuation?.resume(with:result)
  }
  private func cancelAnalysisMatching(_ matches: (PendingAnalysis)->Bool, error: DevelopmentPreviewError) {
    if let item = userAnalysis, matches(item) { deliverAnalysis(item,.failure(error)); userAnalysis = nil; analysisStats.superseded += 1 }
    if let item = backgroundHistogram, matches(item) { deliverAnalysis(item,.failure(error)); backgroundHistogram = nil; analysisStats.superseded += 1 }
    if let item = activeAnalysis, item.deliveryEnabled, matches(item) {
      item.cancellation.cancel()
      qaLifecycle(item.request.operation.isHistogram ? .histogram:.userAnalysis,.cancelled,id:item.token,
        request:item.request.preview,sourceID:sources[item.key]?.native.captureID)
      deliverAnalysis(item,.failure(error)); activeAnalysis?.continuation = nil; activeAnalysis?.deliveryEnabled = false; analysisStats.superseded += 1
      // No early native-slot release: synchronous CI/reduction/readback still joins in finishAnalysis.
    }
  }
  private func startAnalysis(_ item: PendingAnalysis) {
    guard let native = sources[item.key]?.native else { deliverAnalysis(item,.failure(DevelopmentPreviewError.sourceInvalidated)); pump(); return }
    do { _ = try validateAnalysisInput(item.request) }
    catch { deliverAnalysis(item,.failure(error)); pump(); return }
    activeAnalysis = item; consecutiveInteractive = 0
    stats.activeNativeRenders = 1; stats.maximumObservedNativeRenders = max(1,stats.maximumObservedNativeRenders)
    analysisStats.maximumActive = max(1,analysisStats.maximumActive)
    analysisWorkerIdentity = (item.token,item.request)
    let pool = rawBasePool, override = analysisOverride, residentObserver = qaBWSummaryObserverForTesting, images = analysisImages
    let qaKind:PreviewQALifecycleTrace.Kind = item.request.operation.isHistogram ? .histogram:.userAnalysis
    qaLifecycle(qaKind,.admitted,id:item.token,request:item.request.preview,sourceID:native.captureID)
    let binding = DevelopmentLocalEditSourceBinding(sourceContentID:item.sourceContentID,exifOrientation:native.originalEXIFOrientation,
      orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height))
    worker = Task {
      let telemetry = ImagePerformanceTelemetry.shared
      let queue = item.request.operation.isHistogram ? "直方图" : "分析"
      let token = telemetry.begin(operation: queue, stage: "读取与归约", queue: queue)
      let result = await Task.detached(priority:.userInitiated) { () -> (Result<DevelopmentAnalysisResult,Error>,RawBaseStatisticsSnapshot?) in
        PreviewQALifecycleTrace.record(qaKind,.entered,id:item.token,request:item.request.preview,sourceID:native.captureID)
        defer { PreviewQALifecycleTrace.record(qaKind,.returned,id:item.token,request:item.request.preview,sourceID:native.captureID) }
        func operation() -> Result<DevelopmentAnalysisResult,Error> {
          Result { try DevelopmentRenderStack.run { try DevelopmentDehazeNativeResources.run {
            try native.validateCaptureAuthority()
            let result = try override?(item.request,binding) ?? native.analyze(item.request,sourceContentID:item.sourceContentID,cancellation:item.cancellation,rawBasePool:pool,sourceKey:item.key,residentObserver:residentObserver,analysisImages:images)
            try native.validateCaptureAuthority(); return result
          } } }
        }
        if let pool { return pool.withWorker { (operation(),pool.statistics) } }
        return (operation(),nil)
      }.value
      telemetry.end(token, result: result.0)
      await self.finishAnalysis(token:item.token,result:result.0,rawStatistics:result.1)
    }
  }
  private func finishAnalysis(token: UUID, result: Result<DevelopmentAnalysisResult,Error>, rawStatistics: RawBaseStatisticsSnapshot?) async {
    guard activeAnalysis?.token == token else { return }
    if let rawStatistics { applyRawBaseStatistics(rawStatistics) }
    if case .failure(let error) = result, let fault = DevelopmentDehazeNativeResources.captureFault(error), let item = activeAnalysis { beginCaptureFault(key:item.key,captureID:fault.captureID) }
    await flushRawBaseCommands()
    guard let item = activeAnalysis, item.token == token else { return }
    activeAnalysis = nil; stats.activeNativeRenders = 0; analysisStats.completed += 1
    qaLifecycle(item.request.operation.isHistogram ? .histogram:.userAnalysis,.joined,id:item.token,
      request:item.request.preview,sourceID:sources[item.key]?.native.captureID,raw:rawStatistics)
    do {
      _ = try validateAnalysisInput(item.request)
      let value = try result.get()
      guard value.operationID == item.request.operationID, value.sessionID == item.request.preview.sessionID,
        value.consumerID == item.request.preview.consumerID, value.revision == item.request.preview.revision,
        value.actualRecipe == item.request.preview.recipe, value.binding.expectedRecipeFingerprint == item.request.expectedRecipeFingerprint,
        value.binding.sourceGeneration == item.request.preview.sourceGeneration, value.binding.stage == item.request.stage,
        value.roi == item.request.roi, value.presentedRecipeFingerprint == item.request.presentedRecipeFingerprint,
        value.binding.sourceContentID == item.sourceContentID, value.role == item.request.preview.role,
        value.quality == item.request.preview.quality, value.clientCorrelation == item.request.preview.clientCorrelation,
        value.samplingRecipeFingerprint == (try EditingFingerprint.of(DevelopmentAnalysisEngine.samplingRecipe(item.request))) else { throw DevelopmentPreviewError.invalidRequest }
      guard let native = sources[item.key]?.native, value.sourceBinding == DevelopmentLocalEditSourceBinding(sourceContentID:item.sourceContentID,
        exifOrientation:native.originalEXIFOrientation,orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height)) else { throw DevelopmentPreviewError.invalidRequest }
      if item.request.operation.isDisplayHistogram {
        guard case .displayHistogram(let histogram)=value.value else { throw DevelopmentPreviewError.invalidRequest }
        try histogram.validate()
      } else if case .displayHistogram=value.value { throw DevelopmentPreviewError.invalidRequest }
      if DevelopmentNaturalCurvePickerV1.isNatural(item.request) {
        guard case .resolved(let command)=value.value,value.binding == command.binding,
          DevelopmentNaturalCurvePickerV1.acceptsCommand(command,request:item.request) else { throw DevelopmentPreviewError.invalidRequest }
      }
      try DevelopmentLocalAnalysisV3.validateResult(request:item.request,result:value,sourceBinding:value.sourceBinding,
        decoderContractFingerprint:native.localDecoderContractFingerprint)
      if case .prepareDehaze=item.request.operation {
        try DevelopmentDehazeAnalysisV3.validateResult(request:item.request,result:value,
          current:admittedDehazeContext(native,key:item.key,source:value.sourceBinding,generation:item.request.preview.sourceGeneration))
      } else if case .dehaze=value.value { throw DevelopmentPreviewError.invalidRequest }
      let geometry = item.request.preview.recipe.adjustmentsV3?.geometry ?? DevelopmentGeometryV3(version:item.request.preview.recipe.schemaVersion == 2 ? .legacyV2:.legacyV1,straightenDegrees:item.request.preview.recipe.straightenDegrees,crop:item.request.preview.recipe.crop)
      if case .geometry(let resolved)=value.value {
        guard case .cropAutomatic=item.request.operation, let input=item.request.cropAutoInputV1,
          resolved.binding == value.binding, resolved.source == value.sourceBinding,
          resolved.presentedRecipeFingerprint == value.presentedRecipeFingerprint else { throw DevelopmentPreviewError.invalidRequest }
        _=try resolved.validatedCandidate(baseline:geometry,expectedSource:value.sourceBinding,expectedInput:input)
      } else if case .cropAutomatic=item.request.operation { throw DevelopmentPreviewError.invalidRequest }
      guard try item.request.matchesSamplingVersion(value.samplingVersion),
        value.geometryMapping == (try geometry.mapping(sourceSize:value.sourceBinding.sourceSize)) else { throw DevelopmentPreviewError.invalidRequest }
      deliverAnalysis(item,.success(value))
    } catch { deliverAnalysis(item,.failure(error)) }
    if clearAfterJoin { clearCaches(); clearAfterJoin = false }
    for key in Array(sources.keys) { cleanupSource(key) }
    await flushRawBaseCommands()
    if analysisWorkerIdentity?.token == token { analysisWorkerIdentity = nil }
    worker = nil; refreshChannels(); pump()
  }

  // MARK: - B7a thumbnail-only background work and resource transfer
  private struct ThumbnailScope { let request:DevelopmentThumbnailRequest }
  private func cancelThumbnailsWaitingFor(_ request:DevelopmentPreviewRequest){
    cancelThumbnailMatching({item in let p=item.request.preview;return p.sessionID==request.sessionID && p.sourceGeneration==request.sourceGeneration && p.consumerID==request.consumerID && p.revision==request.revision},error:DevelopmentThumbnailError.awaitingSource)
  }
  private func validateThumbnailInput(_ request:DevelopmentThumbnailRequest)throws->Lease {
    try request.validate();let lease=try validate(request.preview)
    if let native=sources[lease.key]?.native {
      do{try native.validateCaptureAuthority()}
      catch{beginCaptureFault(key:lease.key,captureID:native.captureID);throw DevelopmentThumbnailError.staleSource}
    }
    guard !criticalPressure,case .raw=lease.source else{throw DevelopmentThumbnailError.unsupportedGraph}
    guard let native=sources[lease.key]?.native else{throw DevelopmentThumbnailError.staleSource}
    try DevelopmentThumbnailEngine.checkSupport(DevelopmentThumbnailEngine.proxyPreparationRecipe(request),sourceIsRAW:native.hasRAWFilter)
    _ = try DevelopmentThumbnailEngine.resourceVersion(request)
    if let current=latest[request.preview.consumerID],current.0==request.preview.sessionID,current.1==request.preview.sourceGeneration {
      guard current.2<=request.preview.revision else{throw DevelopmentThumbnailError.superseded}
      if current.2==request.preview.revision {guard latestRecipeFingerprint[request.preview.consumerID]==request.presentedRecipeFingerprint else{throw DevelopmentThumbnailError.superseded}}
    }
    return lease
  }
  private func thumbnailIsSettled(_ request:DevelopmentThumbnailRequest)->Bool {
    guard let current=thumbnailSettled[request.preview.consumerID],current.sessionID==request.preview.sessionID,
      current.sourceGeneration==request.preview.sourceGeneration,current.revision==request.preview.revision,
      (try? EditingFingerprint.of(current.recipe))==request.presentedRecipeFingerprint else{return false}
    guard current.quality == .settled || (request.basis == .currentCanonical && current.quality == .detail),
      request.basis != .currentCanonical || current.quality==request.preview.quality else{return false}
    return true
  }
  private func matchingSettledFlight(_ request:DevelopmentThumbnailRequest)->Bool {
    let check:(Pending)->Bool={item in
      item.deliveryEnabled && (item.request.quality == .settled || (request.basis == .currentCanonical && item.request.quality == .detail)) &&
      (request.basis != .currentCanonical || item.request.quality==request.preview.quality) && item.request.consumerID==request.preview.consumerID &&
      item.request.sessionID==request.preview.sessionID && item.request.sourceGeneration==request.preview.sourceGeneration &&
      item.request.revision==request.preview.revision && (try? EditingFingerprint.of(item.request.recipe))==request.presentedRecipeFingerprint
    }
    return active.map(check)==true || pending.contains(where:check)
  }
  public func thumbnails(_ request:DevelopmentThumbnailRequest,progress:@escaping @Sendable(DevelopmentThumbnailProgress)->Void)async throws->DevelopmentThumbnailReadyLease {
    try Task.checkCancellation();let lease=try validateThumbnailInput(request)
    guard request.kind == .filters || thumbnailIsSettled(request) || matchingSettledFlight(request) else{throw DevelopmentThumbnailError.awaitingSource}
    guard thumbnailActive?.request.registration != request.registration,thumbnailPending?.request.registration != request.registration,
      !thumbnailSets.values.contains(where:{$0.request.registration==request.registration}) else{throw DevelopmentThumbnailError.invalidRequest}
    guard let native=sources[lease.key]?.native else{throw DevelopmentThumbnailError.staleSource}
    let source=try describe(lease.source).snapshot
    let binding=DevelopmentLocalEditSourceBinding(sourceContentID:source.contentSHA256,exifOrientation:native.originalEXIFOrientation,
      orientedWidth:Int(native.nativeSize.width),orientedHeight:Int(native.nativeSize.height))
    let registration=request.registration,gate=ThumbnailDeliveryGate()
    let cancellationGateRevoked=thumbnailCancellationGateRevokedForTesting
    return try await withTaskCancellationHandler(operation:{
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation{continuation in
        guard !Task.isCancelled else{continuation.resume(throwing:DevelopmentThumbnailError.cancelled);return}
        do {
          try gate.whileOpen {
            // Cancellation handler closes this SAME gate synchronously; admission is atomic to it.
            cancelThumbnailMatching({_ in true},error:DevelopmentThumbnailError.superseded,includeSets:false)
            let batch=ThumbnailBatch(request:request,key:lease.key,source:binding,progress:progress,continuation:continuation,gate:gate)
            thumbnailWanted.insert(registration);thumbnailPending=batch
          }
          if gate.isOpen{progress(.init(registration:registration,completed:0,total:request.kind.count))};pump()
        }catch{continuation.resume(throwing:error)}
      }
    },onCancel:{gate.revoke();Task{
      await cancellationGateRevoked?(.gateRevoked)
      await self.revokeThumbnailDelivery(registration)
      await cancellationGateRevoked?(.actorRevocationReturned)
    }})
  }
  /// Registration-only. Never forwards to cancel(consumerID:) or touches user analysis/channel.
  public func revokeThumbnailDelivery(_ registration:DevelopmentThumbnailRegistration){
    cancelThumbnailMatching({$0.request.registration==registration},error:DevelopmentThumbnailError.cancelled);pump()
  }
  public func cancelAndJoinThumbnail(_ registration:DevelopmentThumbnailRegistration)async {
    let running=thumbnailStepRegistration==registration ? worker:nil
    revokeThumbnailDelivery(registration)
    let retiring=thumbnailRetirements.values.filter{$0.request.registration==registration}.map(\.task)
    if let running{await running.value}
    for task in retiring{await task.value}
    // Include a ready set retired by this same old step's completion, never follow a new worker.
    for item in Array(thumbnailRetirements.values) where item.request.registration==registration{await item.task.value}
  }
  public func adoptThumbnailSet(_ ready:DevelopmentThumbnailReadyLease,registration:DevelopmentThumbnailRegistration)throws->DevelopmentThumbnailDisplayLease {
    guard let entry=thumbnailSets[ready.setID],entry.owner.token==ready.ownershipToken,
      entry.request.registration==registration,ready.descriptor.registration==registration else{throw DevelopmentThumbnailError.invalidLease}
    _=try validateThumbnailInput(entry.request);guard entry.request.kind == .filters || thumbnailIsSettled(entry.request)else{throw DevelopmentThumbnailError.superseded}
    return try entry.owner.adopt()
  }
  public func adoptThumbnailPresentation(_ ready:DevelopmentThumbnailReadyLease,registration:DevelopmentThumbnailRegistration)throws->DevelopmentThumbnailPresentationLease {
    guard let entry=thumbnailSets[ready.setID],entry.owner.token==ready.ownershipToken,
      entry.request.registration==registration,ready.descriptor.registration==registration,
      entry.request.presentationMode == .managedImage else{throw DevelopmentThumbnailError.invalidLease}
    _=try validateThumbnailInput(entry.request);guard entry.request.kind == .filters || thumbnailIsSettled(entry.request)else{throw DevelopmentThumbnailError.superseded}
    return try entry.owner.adoptPresentation()
  }
  public func releaseThumbnailSet(_ ready:DevelopmentThumbnailReadyLease,registration:DevelopmentThumbnailRegistration)async {
    if let old=thumbnailRetirements[ready.setID],old.token==ready.ownershipToken,old.request.registration==registration{await old.task.value;return}
    guard let entry=thumbnailSets[ready.setID],entry.owner.token==ready.ownershipToken,entry.request.registration==registration,
      !entry.owner.isAdopted else{return}
    thumbnailSets.removeValue(forKey:ready.setID);thumbnailWanted.remove(registration)
    let retirement=retireThumbnailOwner(entry);await retirement.value;retireThumbnailProxyIfIdle()
  }
  public func releaseThumbnailDisplay(_ display:DevelopmentThumbnailDisplayLease,registration:DevelopmentThumbnailRegistration)async {
    if let old=thumbnailRetirements[display.setID],old.token==display.ownershipToken,old.request.registration==registration{await old.task.value;return}
    guard let entry=thumbnailSets[display.setID],entry.owner.token==display.ownershipToken,entry.request.registration==registration else{return}
    thumbnailSets.removeValue(forKey:display.setID);thumbnailWanted.remove(registration)
    let retirement=retireThumbnailOwner(entry);await retirement.value;retireThumbnailProxyIfIdle()
  }
  public func releaseThumbnailPresentation(_ presentation:DevelopmentThumbnailPresentationLease,registration:DevelopmentThumbnailRegistration)async {
    if let old=thumbnailRetirements[presentation.setID],old.token==presentation.ownershipToken,old.request.registration==registration{await old.task.value;return}
    guard let entry=thumbnailSets[presentation.setID],entry.owner.token==presentation.ownershipToken,
      entry.request.registration==registration,entry.request.presentationMode == .managedImage else{return}
    thumbnailSets.removeValue(forKey:presentation.setID);thumbnailWanted.remove(registration)
    let retirement=retireThumbnailOwner(entry);await retirement.value;retireThumbnailProxyIfIdle()
  }
  public func thumbnailStatistics()->DevelopmentThumbnailStatistics {
    var value=thumbnailLedger.snapshot();value.pending=thumbnailPending==nil ? 0:1;value.active=thumbnailActive==nil ? 0:1
    value.readySets=thumbnailSets.values.filter{!$0.owner.isAdopted}.count;value.displaySets=thumbnailSets.values.filter{$0.owner.isAdopted}.count
    value.completed=thumbnailStats.completed;value.cancelled=thumbnailStats.cancelled;value.maximumStepNanoseconds=thumbnailStats.maximumStepNanoseconds;return value
  }
  @discardableResult private func retireThumbnailOwner(_ entry:(owner:ThumbnailSetOwner,request:DevelopmentThumbnailRequest))->Task<Void,Never> {
    entry.owner.revokeReads();let id=entry.owner.id
    if let existing=thumbnailRetirements[id]{return existing.task}
    let task=Task{await entry.owner.retireAndJoin();self.thumbnailRetirements.removeValue(forKey:id)}
    thumbnailRetirements[id]=(entry.request,entry.owner.token,task);return task
  }
  private func retireThumbnailSets(where matches:(DevelopmentThumbnailRequest)->Bool)async {
    let entries=thumbnailSets.filter{matches($0.value.request)}
    for(id,entry)in entries{thumbnailSets.removeValue(forKey:id);thumbnailWanted.remove(entry.request.registration);retireThumbnailOwner(entry)}
    // Also join a release that removed its ready/display entry BEFORE this scope-close began.
    let existing=thumbnailRetirements.values.filter{matches($0.request)}.map(\.task)
    for task in existing{await task.value}
  }
  private func cancelThumbnailMatching(_ matches:(ThumbnailScope)->Bool,error:Error,includeSets:Bool=true) {
    if let batch=thumbnailPending,matches(.init(request:batch.request)){thumbnailWanted.remove(batch.request.registration);batch.revoke(error);batch.retireTiles();thumbnailPending=nil;thumbnailStats.cancelled+=1}
    if let batch=thumbnailActive,matches(.init(request:batch.request)){
      thumbnailWanted.remove(batch.request.registration);batch.revoke(error);thumbnailStats.cancelled+=1
      if thumbnailStepRegistration != batch.request.registration{batch.retireTiles();thumbnailActive=nil}
    }
    if includeSets {
      for(id,entry)in thumbnailSets where matches(.init(request:entry.request)){
        thumbnailWanted.remove(entry.request.registration);entry.owner.revokeReads()
        // An adopted set stays charged until explicit display detach/release (or whole scope close).
        if !entry.owner.isAdopted{thumbnailSets.removeValue(forKey:id);retireThumbnailOwner(entry)}
      }
    }
    retireThumbnailProxyIfIdle()
  }
  private func retireThumbnailProxyIfIdle(){
    guard thumbnailStepRegistration==nil,thumbnailWanted.isEmpty else{return}
    // A finished input proxy is source-bound, unlike the cancelled candidate batch.
    // Keep only one existing allocation in the current opt-in image preview lease.
    if policy.nativePointwiseProfile, !criticalPressure, !terminated,
      let proxy=thumbnailProxy, let scope=thumbnailProxyScope,
      let lease=leases[scope.session], lease.valid, lease.key==proxy.key,
      lease.generation==proxy.value.sourceGeneration,
      let native=sources[proxy.key]?.native, !native.hasRAWFilter, !native.artifact,
      captureRetirements[proxy.key]==nil, draining[scope.consumer]==nil,
      let head=latest[scope.consumer], head.0==scope.session, head.1==lease.generation {
      return
    }
    thumbnailProxy?.value.surface.retire();thumbnailProxy=nil;thumbnailProxyScope=nil
  }
  private func makeThumbnailSettledHook(_ item:Pending,native:PreviewNativeSource)->ThumbnailSettledHook? {
    guard item.request.quality == .settled,item.request.recipe.schemaVersion==3,
      (try? DevelopmentRendererV3.legacyEquivalent(item.request.recipe))==nil,thumbnailProxy==nil,
      let batch=thumbnailActive ?? thumbnailPending,batch.gate.isOpen,batch.key==item.key,
      batch.request.preview.sessionID==item.request.sessionID,batch.request.preview.sourceGeneration==item.request.sourceGeneration,
      batch.request.preview.revision==item.request.revision,
      batch.request.presentedRecipeFingerprint==(try? EditingFingerprint.of(item.request.recipe)),let device=MTLCreateSystemDefaultDevice() else{return nil}
    return .init(batch:batch,native:native,ledger:thumbnailLedger,device:device,contextOwner:thumbnailContextOwner)
  }
  /// Warm the canonical 1:1 base once per source while the canvas is idle. Runs before the
  /// thumbnail step so a later 1:1 gesture does not wait for the full decode.
  /// Turbo only: the warm-up occupies the single native worker for about one full RAW decode, so
  /// balanced mode never pays for it. Measured on the real sequence (settle, idle, then enter 1:1)
  /// it takes the first 1:1 frame from 142.6 to 39.1 ms; an unconditional run showed 6% matrix
  /// noise with the heaviest recipes slower, which is why it is scoped to the opt-in profile.
  static var detailPrewarmEnabled: Bool {
    if let raw = ProcessInfo.processInfo.environment["RAWMASTER_QA_DETAIL_PREWARM"] { return raw != "0" }
    return PreviewPerformancePreferences.isTurbo
  }
  /// The warm-up occupies the single native worker for about the length of one full RAW decode.
  /// Wait longer than the ordinary quiescence so a user who is still working never queues behind it.
  static let detailPrewarmIdleMilliseconds = Int(
    ProcessInfo.processInfo.environment["RAWMASTER_QA_DETAIL_PREWARM_IDLE_MS"] ?? "") ?? 750
  @discardableResult private func startDetailPrewarm() -> Bool {
    guard Self.detailPrewarmEnabled, !terminated, worker == nil,
          let (key, generation) = idlePrewarmCandidate() else { return false }
    guard let native = sources[key]?.native else { return false }
    detailPrewarmDone[key] = generation
    active = nil
    worker = Task { [weak self] in
      await Task.detached(priority: .utility) { native.prewarmCanonicalDetail(sourceKey: key) }.value
      guard let self else { return }
      await self.finishDetailPrewarm()
    }
    return true
  }
  /// The single source that currently owns a lease and can be warmed.
  private func idlePrewarmCandidate() -> (String, UInt64)? {
    var candidate: (String, UInt64)?
    for lease in leases.values where lease.valid {
      guard let record = sources[lease.key], record.native.hasRAWFilter, !record.native.artifact else { continue }
      if detailPrewarmDone[lease.key] == lease.generation { continue }
      candidate = (lease.key, lease.generation)
    }
    return candidate
  }
  private func finishDetailPrewarm() {
    worker = nil
    pump()
  }
  @discardableResult private func startThumbnailStep()->Bool {
    if thumbnailActive==nil{thumbnailActive=thumbnailPending;thumbnailPending=nil}
    guard let batch=thumbnailActive else{return false}
    guard batch.gate.isOpen else {
      // The synchronous cancellation gate may close before its actor revocation arrives.
      // Complete the caller before dropping the last queued batch; a later revoke is idempotent.
      thumbnailWanted.remove(batch.request.registration);batch.revoke(DevelopmentThumbnailError.cancelled)
      batch.retireTiles();thumbnailActive=nil;thumbnailStats.cancelled+=1
      retireThumbnailProxyIfIdle();return false
    }
    guard batch.request.kind == .filters || thumbnailIsSettled(batch.request)else{return false}
    do{_=try validateThumbnailInput(batch.request)}catch{batch.revoke(error);batch.retireTiles();thumbnailActive=nil;pump();return true}
    guard let native=sources[batch.key]?.native else{batch.revoke(DevelopmentThumbnailError.staleSource);thumbnailActive=nil;return false}
    let inputRecipe:DevelopmentRecipe,key:String
    do{
      inputRecipe=try DevelopmentThumbnailEngine.proxyPreparationRecipe(batch.request)
      key=try native.thumbnailInputFingerprint(recipe:inputRecipe,source:batch.source,generation:batch.request.preview.sourceGeneration)
    }
    catch{batch.revoke(error);batch.retireTiles();thumbnailActive=nil;pump();return true}
    if let old=thumbnailProxy,old.key != batch.key || old.value.fingerprint != key ||
      (policy.nativePointwiseProfile && !native.hasRAWFilter &&
        (thumbnailProxyScope?.session != batch.request.preview.sessionID || thumbnailProxyScope?.consumer != batch.request.preview.consumerID)) {
      old.value.surface.retire();thumbnailProxy=nil;thumbnailProxyScope=nil
    }
    let proxy=thumbnailProxy?.value,scalars=batch.scalars,index=batch.tiles.count,ledger=thumbnailLedger,contextOwner=thumbnailContextOwner
    let step:PreviewQALifecycleTrace.ThumbnailStep = proxy==nil ? .proxy:((scalars != nil || batch.request.kind == .filters) ? .tile:.scalars)
    thumbnailStepRegistration=batch.request.registration;stats.activeNativeRenders=1;stats.maximumObservedNativeRenders=max(1,stats.maximumObservedNativeRenders)
    let started=now(),beforeStep=thumbnailStepWillBeginForTesting
    let qaStep=PreviewQALifecycleTrace.isEnabled ? UUID():batch.request.registration.operationID
    let qaKind:PreviewQALifecycleTrace.Kind = batch.request.kind == .filters ? .filterThumbnail:.summaryThumbnail
    qaLifecycle(qaKind,.admitted,id:qaStep,request:batch.request.preview,sourceID:native.captureID,thumbnailStep:step)
    worker=Task{
      let telemetry = ImagePerformanceTelemetry.shared
      let token = telemetry.begin(operation: "缩略图", stage: step.rawValue, queue: "缩略图")
      let result=await Task.detached(priority:.utility){()->Result<ThumbnailStepResult,Error> in
        PreviewQALifecycleTrace.record(qaKind,.entered,id:qaStep,request:batch.request.preview,sourceID:native.captureID,thumbnailStep:step)
        defer { PreviewQALifecycleTrace.record(qaKind,.returned,id:qaStep,request:batch.request.preview,sourceID:native.captureID,thumbnailStep:step) }
        return Result{try DevelopmentRenderStack.run { try autoreleasepool{
        try native.validateCaptureAuthority();guard batch.gate.isOpen else{throw DevelopmentThumbnailError.cancelled}
        try beforeStep?();guard batch.gate.isOpen else{throw DevelopmentThumbnailError.cancelled}
        guard let device=MTLCreateSystemDefaultDevice()else{throw DevelopmentThumbnailError.unavailableDevice}
        let result:ThumbnailStepResult
        if let proxy {
          guard proxy.surface.deviceRegistryID==device.registryID else{throw DevelopmentThumbnailError.unavailableDevice}
          if scalars != nil || batch.request.kind == .filters {
            if batch.request.presentationMode == .managedImage {
              let value=try DevelopmentThumbnailEngine.managedTile(batch.request,index:index,scalars:scalars,proxy:proxy,ledger:ledger,device:device,contextOwner:contextOwner)
              guard batch.gate.isOpen else{value.0.detach();throw DevelopmentThumbnailError.cancelled}
              result = .managedTile(value.0,value.1,value.2)
            }else{
              let value=try DevelopmentThumbnailEngine.tile(batch.request,index:index,scalars:scalars,proxy:proxy,ledger:ledger,device:device,contextOwner:contextOwner)
              result = .tile(value.0,value.1,value.2)
            }
          }
          else{result = .scalars(try DevelopmentThumbnailEngine.prepareScalars(batch.request,proxy:proxy,ledger:ledger,device:device,contextOwner:contextOwner))}
        }else{
          result = .proxy(try native.prepareThumbnailProxy(recipe:inputRecipe,source:batch.source,generation:batch.request.preview.sourceGeneration,ledger:ledger,device:device,contextOwner:contextOwner,interest:{batch.gate.isOpen}))
        }
        try native.validateCaptureAuthority();return result
      } }}}.value
      telemetry.end(token, result: result)
      await self.finishThumbnailStep(batch:batch,result:result,started:started,qaStep:qaStep,step:step)
    }
    return true
  }
  private func finishThumbnailStep(batch:ThumbnailBatch,result:Result<ThumbnailStepResult,Error>,started:UInt64,qaStep:UUID,step:PreviewQALifecycleTrace.ThumbnailStep)async {
    guard thumbnailStepRegistration==batch.request.registration else{return}
    thumbnailStats.maximumStepNanoseconds=max(thumbnailStats.maximumStepNanoseconds,now()>=started ? now()-started:0)
    if case .failure(let fault as PreviewCaptureFault)=result{beginCaptureFault(key:batch.key,captureID:fault.captureID)}
    // The detached native operation has ACTUALLY joined. No cancellation released this slot early.
    thumbnailStepRegistration=nil;stats.activeNativeRenders=0
    qaLifecycle(batch.request.kind == .filters ? .filterThumbnail:.summaryThumbnail,.joined,id:qaStep,
      request:batch.request.preview,sourceID:sources[batch.key]?.native.captureID,thumbnailStep:step)
    do{
      _=try validateThumbnailInput(batch.request);guard batch.gate.isOpen,thumbnailActive===batch else{throw DevelopmentThumbnailError.cancelled}
      switch try result.get(){
      case .proxy(let proxy):
        thumbnailProxy=(batch.key,proxy)
        thumbnailProxyScope=(batch.request.preview.sessionID,batch.request.preview.consumerID)
      case .scalars(let scalars):batch.scalars=scalars
      case .tile(let surface,let tile,let ev):batch.surfaces.append(surface);batch.tiles.append(tile);batch.candidateEV.append(ev)
        batch.progress(.init(registration:batch.request.registration,completed:batch.tiles.count,total:batch.request.kind.count))
      case .managedTile(let backing,let tile,let ev):batch.managedBackings.append(backing);batch.tiles.append(tile);batch.candidateEV.append(ev)
        batch.progress(.init(registration:batch.request.registration,completed:batch.tiles.count,total:batch.request.kind.count))
      }
      if batch.tiles.count==batch.request.kind.count,let proxy=thumbnailProxy?.value {
        let d=DevelopmentThumbnailSetDescriptor(registration:batch.request.registration,actualRequest:batch.request.preview,sourceBinding:batch.source,
          expectedRecipeFingerprint:batch.request.expectedRecipeFingerprint,presentedRecipeFingerprint:batch.request.presentedRecipeFingerprint,
          kind:batch.request.kind,target:batch.request.target,contractVersion:1,pipelineVersion:[DevelopmentThumbnailEngine.version,DevelopmentRendererV3.pipelineVersion,DevelopmentSpatialEngineV3.operatorVersion,DevelopmentColorEngineV3.operatorVersion,DevelopmentGlobalEngineV3.operatorVersion,DevelopmentWhiteBalanceEngineV3.operatorVersion,DevelopmentGeometryEngineV3.operatorVersion].joined(separator:"/"),
          proxyInputFingerprint:proxy.fingerprint,proxyWidth:proxy.surface.width,proxyHeight:proxy.surface.height,proxyEncoding:"extended-linear-sRGB/rgba32Float/premultiplied/top-row-first",sourceToProxy:proxy.affine,
          bakedBaseEV:proxy.bakedBaseEV,candidateNativeEV:batch.candidateEV,approximationVersion:"thumbnail-compact-source-scale-v3/post-native-EV-before-legacy-color/unbaked-image-prefix/native-Core-map",
          preparationCold:proxy.cold,preparationNanoseconds:proxy.preparationNanoseconds,
          bakedStages:proxy.sourceIsRAW ? ["oriented-native-RAW/WB/NR/EV","linear-premul-F32-256"]:["oriented-image-ICC","linear-premul-F32-256"],
          unbakedStages:["image-preamble256-legacyWB-EV-absoluteWB-if-image","legacy-color-v2-both-sources","image-LightEV-if-image","LightSpatial-compact-native-radius-times-scale","V3Pointwise","curves-levels","global-compact","photo-filter-actual-resource","Core-native-map-conjugation"],tiles:batch.tiles,
          presentationMode:batch.request.presentationMode,presentationVersion:batch.request.presentationMode == .managedImage ? ThumbnailImageBacking.version:nil,
          photoFilterResourceVersion:try DevelopmentThumbnailEngine.resourceVersion(batch.request),proxyContentRect:proxy.contentRect)
        let owner=ThumbnailSetOwner(descriptor:d,surfaces:batch.surfaces,managedBackings:batch.managedBackings,gate:batch.gate);batch.surfaces=[];batch.managedBackings=[]
        thumbnailSets[owner.id]=(owner,batch.request);thumbnailActive=nil;thumbnailStats.completed+=1
        let c=batch.continuation;batch.continuation=nil;c?.resume(returning:owner.ready())
      }
    }catch{
      if case .success(let step)=result{switch step{case .proxy(let proxy):proxy.surface.retire();case .tile(let surface,_,_):surface.retire();case .managedTile(let backing,_,_):backing.detach();default:break}}
      thumbnailWanted.remove(batch.request.registration);batch.revoke(error);batch.retireTiles();if thumbnailActive===batch{thumbnailActive=nil}
    }
    retireThumbnailProxyIfIdle()
    if clearAfterJoin{clearCaches();clearAfterJoin=false}
    for key in Array(sources.keys){cleanupSource(key)}
    await flushRawBaseCommands();worker=nil;refreshChannels();pump()
  }

}
