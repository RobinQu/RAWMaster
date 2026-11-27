import AppKit
import Combine
import RAWMasterCore
import RAWMasterImaging

/// The product adapter always uses the process-wide imaging service. Tests inject only this boundary.
protocol EditingPreviewBackend: Sendable {
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap
    func cancel(_ consumer: PreviewConsumerID) async
    func cancelAndJoin(_ consumer: PreviewConsumerID) async
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel
    func closeProgressChannel(_ id: PreviewProgressChannelID) async
    func close(_ lease: DevelopmentPreviewSessionID) async
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease
    func sourceFacts(_ lease: EditingPreviewLease) async throws -> DevelopmentSourceFacts
    func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult
    func joinAnalysis(_ request: DevelopmentAnalysisRequest) async
    func thumbnails(_ request: DevelopmentThumbnailRequest, progress: @escaping @Sendable (DevelopmentThumbnailProgress) -> Void) async throws -> DevelopmentThumbnailReadyLease
    func revokeThumbnails(_ registration: DevelopmentThumbnailRegistration) async
    func joinThumbnails(_ registration: DevelopmentThumbnailRegistration) async
    func adoptThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async throws -> DevelopmentThumbnailPresentationLease
    func releaseThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async
    func releaseThumbnails(_ presentation: DevelopmentThumbnailPresentationLease, registration: DevelopmentThumbnailRegistration) async
}
struct EditingProgressChannel: Sendable {
    let id: PreviewProgressChannelID
    let snapshots: AsyncStream<PreviewDeliverySnapshot>
    let submit: @Sendable (DevelopmentPreviewRequest) throws -> PreviewEnqueueReceipt
    let noteActivity: @Sendable () -> Void
}
extension EditingPreviewBackend {
    func thumbnails(_ request: DevelopmentThumbnailRequest, progress: @escaping @Sendable (DevelopmentThumbnailProgress) -> Void) async throws -> DevelopmentThumbnailReadyLease { throw DevelopmentThumbnailError.unsupportedGraph }
    func revokeThumbnails(_ registration: DevelopmentThumbnailRegistration) async {}
    func joinThumbnails(_ registration: DevelopmentThumbnailRegistration) async {}
    func adoptThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async throws -> DevelopmentThumbnailPresentationLease { throw DevelopmentThumbnailError.unsupportedGraph }
    func releaseThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async {}
    func releaseThumbnails(_ presentation: DevelopmentThumbnailPresentationLease, registration: DevelopmentThumbnailRegistration) async {}
    // Strict-only test backends have no native worker/registration; progress tests provide explicit implementations.
    func cancelAndJoin(_ consumer: PreviewConsumerID) async { await cancel(consumer) }
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel { throw DevelopmentPreviewError.invalidRequest }
    func closeProgressChannel(_ id: PreviewProgressChannelID) async {}
    func sourceFacts(_ lease: EditingPreviewLease) async throws -> DevelopmentSourceFacts { throw DevelopmentPreviewError.invalidRequest }
    func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult { throw DevelopmentV3Error.unsupportedAnalysis }
    // Scalar-only test backends finish with their analyze call; the product adapter joins native work.
    func joinAnalysis(_ request: DevelopmentAnalysisRequest) async {}
}
struct EditingThumbnailCanonicalWitness: Hashable, Sendable {
    let frameID: UUID
    let sessionID: DevelopmentPreviewSessionID
    let sourceGeneration: UInt64
    let revision: UInt64
    let quality: String
    let viewportMaximumPixel: Int
    let recipeFingerprint: String
}
struct EditingPreviewSourceContext: Sendable {
    let lease: EditingPreviewLease
    let facts: DevelopmentSourceFacts
    var binding: DevelopmentLocalEditSourceBinding { facts.sourceBinding }
    var noiseReduction: DevelopmentNoiseReductionSourceCapability { facts.noiseReduction.sourceCapability }
}
struct EditingPreviewLease: Sendable {
    let id: DevelopmentPreviewSessionID
    let generation: UInt64
    let sourceIdentity: String?
    let canonicalGesture: PreviewCanonicalGestureCapability?
    init(id: DevelopmentPreviewSessionID, generation: UInt64, sourceIdentity:String? = nil,
         canonicalGesture:PreviewCanonicalGestureCapability? = nil) {
        self.id=id;self.generation=generation;self.sourceIdentity=sourceIdentity;self.canonicalGesture=canonicalGesture
    }
    init(_ info: PreviewSessionInfo) {
        id=info.id;generation=info.sourceGeneration;sourceIdentity=info.sourceIdentity;canonicalGesture=info.canonicalGesture
    }
}
struct EditingPreviewBitmap: @unchecked Sendable {
    let id: UUID
    let image: NSImage
    let leaseID: DevelopmentPreviewSessionID
    let generation: UInt64
    let consumerID: PreviewConsumerID
    let revision: UInt64
    let quality: PreviewQuality
    let nativeSize: CGSize
    let outputSize: CGSize
    let approximate: Bool
    /// Canvas window this bitmap covers at 1:1. `nil` is the whole canvas.
    let window: CGRect?
    init(id: UUID, image: NSImage, leaseID: DevelopmentPreviewSessionID, generation: UInt64,
         consumerID: PreviewConsumerID, revision: UInt64, quality: PreviewQuality,
         nativeSize: CGSize, outputSize: CGSize, approximate: Bool, window: CGRect? = nil) {
        self.id = id; self.image = image; self.leaseID = leaseID; self.generation = generation
        self.consumerID = consumerID; self.revision = revision; self.quality = quality
        self.nativeSize = nativeSize; self.outputSize = outputSize; self.approximate = approximate
        self.window = window
    }
    init(_ frame: DevelopmentPreviewFrame) {
        self.init(id: frame.frameID, image: frame.image, leaseID: frame.sessionID, generation: frame.sourceGeneration,
                  consumerID: frame.consumerID, revision: frame.revision, quality: frame.quality,
                  nativeSize: frame.canonicalPixelSize, outputSize: frame.outputPixelSize,
                  approximate: frame.approximate, window: frame.window)
    }
}
struct SharedEditingPreviewBackend: EditingPreviewBackend {
    let engine: any ImageEngine
    init(engine: any ImageEngine = ImageEngines.editing) { self.engine = engine }
    init(service: any ImageEngine) { self.init(engine: service) }
    func thumbnails(_ request: DevelopmentThumbnailRequest, progress: @escaping @Sendable (DevelopmentThumbnailProgress) -> Void) async throws -> DevelopmentThumbnailReadyLease { try await engine.thumbnails(request, progress: progress) }
    func revokeThumbnails(_ registration: DevelopmentThumbnailRegistration) async { await engine.revokeThumbnailDelivery(registration) }
    func joinThumbnails(_ registration: DevelopmentThumbnailRegistration) async { await engine.cancelAndJoinThumbnail(registration) }
    func adoptThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async throws -> DevelopmentThumbnailPresentationLease { try await engine.adoptThumbnailPresentation(ready, registration: registration) }
    func releaseThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async { await engine.releaseThumbnailSet(ready, registration: registration) }
    func releaseThumbnails(_ presentation: DevelopmentThumbnailPresentationLease, registration: DevelopmentThumbnailRegistration) async { await engine.releaseThumbnailPresentation(presentation, registration: registration) }
    func sourceFacts(_ lease: EditingPreviewLease) async throws -> DevelopmentSourceFacts {
        try await engine.sourceFacts(sessionID: lease.id, sourceGeneration: lease.generation)
    }
    func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult {
        try await engine.analyze(request)
    }
    func joinAnalysis(_ request: DevelopmentAnalysisRequest) async { await engine.cancelAnalysisAndJoin(request) }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { let info = try await engine.open(source: source); return .init(info) }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap { let frame = try await engine.render(request); return .init(frame) }
    func cancel(_ consumer: PreviewConsumerID) async { await engine.cancel(consumerID: consumer) }
    func cancelAndJoin(_ consumer: PreviewConsumerID) async { await engine.cancelAndJoin(consumerID: consumer) }
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel {
        let channel = try await engine.makeProgressChannel(sessionID: lease.id, sourceGeneration: lease.generation, consumerID: consumer)
        return .init(id: channel.id, snapshots: channel.snapshots, submit: { try channel.submit($0) }, noteActivity: { channel.noteActivity() })
    }
    func closeProgressChannel(_ id: PreviewProgressChannelID) async { await engine.closeProgressChannel(id) }
    func close(_ lease: DevelopmentPreviewSessionID) async { await engine.close(lease) }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease {
        let info = try await engine.revalidate(lease, source: source); return .init(info)
    }
}
/// Does not include exposure/WB. Every change creates a new registration/publication epoch.
struct EditingDraftPresentation: Equatable, Sendable {
    let focusID: UUID
    let workID: String
    let draftParentID: String?
    let selectedVersionID: String?
    let cropOverlay: Bool
    let comparing: Bool
    let draftBranchID: UUID?
    let draftBranchEpoch: UInt64?
    init(focusID: UUID, workID: String, draftParentID: String?, selectedVersionID: String?, cropOverlay: Bool, comparing: Bool,
         draftBranchID: UUID? = nil, draftBranchEpoch: UInt64? = nil) {
        self.focusID = focusID; self.workID = workID; self.draftParentID = draftParentID; self.selectedVersionID = selectedVersionID
        self.cropOverlay = cropOverlay; self.comparing = comparing; self.draftBranchID = draftBranchID; self.draftBranchEpoch = draftBranchEpoch
    }
}
struct EditingPreviewIntent: Sendable, Equatable {
    let source: DevelopmentPreviewSource
    let sourceKey: String
    let recipe: DevelopmentRecipe
    let quality: PreviewQuality
    let draftPresentation: EditingDraftPresentation?
    let presentationID: String
    var isRaw: Bool { if case .raw = source { return true }; return false }
    let viewport: PreviewViewport
    init(source: DevelopmentPreviewSource, recipe: DevelopmentRecipe, quality: PreviewQuality, draftPresentation: EditingDraftPresentation? = nil, presentationID: String = "fixed", detailWindow: CGRect? = nil, detailScale: CGFloat? = nil) throws {
        viewport = .init(maxPixel: quality == .detail ? 0 : 2400,
                         window: quality == .detail ? detailWindow : nil,
                         detailScale: quality == .detail ? detailScale : nil)
        self.source = source; self.recipe = recipe; self.quality = quality; self.draftPresentation = draftPresentation; self.presentationID = presentationID
        switch source {
        case .raw(let snapshot): sourceKey = "raw:" + (try EditingFingerprint.of(snapshot))
        case .artifact(let url, let artifact): sourceKey = "artifact:" + url.path + ":" + (try EditingFingerprint.of(artifact))
        }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.sourceKey == rhs.sourceKey && lhs.recipe == rhs.recipe && lhs.quality == rhs.quality && lhs.draftPresentation == rhs.draftPresentation && lhs.presentationID == rhs.presentationID && lhs.viewport == rhs.viewport }
}
/// QA-only scheduling change. The existing canonical capability still decides the image domain.
enum EditingPreviewPromptDispatch {
    static func enabled(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        bundleIdentifier == "io.robinqu.RAWMaster.preview022" && environment["RAWMASTER_QA_PROMPT_CANONICAL_DISPATCH_V1"] == "1"
    }
    struct Outcome: Sendable {
        let requestBeganAt: UInt64?
        let result: Result<EditingPreviewBitmap, Error>
    }
    /// Created synchronously by the existing lifecycle driver, before its MainActor waiter is queued.
    static func start(backend: any EditingPreviewBackend, request: DevelopmentPreviewRequest,
                      beforeCallForTesting: (@Sendable () async -> Void)? = nil) -> Task<Outcome, Never> {
        Task.detached(priority: .userInitiated) {
            if let beforeCallForTesting { await beforeCallForTesting() }
            do { try Task.checkCancellation() }
            catch { return .init(requestBeganAt: nil, result: .failure(error)) }
            let began = DispatchTime.now().uptimeNanoseconds
            do { return .init(requestBeganAt: began, result: .success(try await backend.render(request))) }
            catch { return .init(requestBeganAt: began, result: .failure(error)) }
        }
    }
    /// Cancellation before this waiter begins must still reach the already-created child and join it.
    static func join(_ child: Task<Outcome, Never>) async -> Outcome {
        await withTaskCancellationHandler(operation: { await child.value }, onCancel: { child.cancel() })
    }
}
/// One pane owns a serial lifecycle driver, one resource child, and either a strict waiter or a channel reader.
@MainActor final class EditingPreviewPane: ObservableObject {
    @Published private(set) var frame: EditingPreviewBitmap?
    private(set) var fitFallback: EditingPreviewBitmap?
    @Published private(set) var rendering = false
    @Published private(set) var error: String? {
        didSet { if let error, error != oldValue { onFailure?(error) } }
    }
    @Published private(set) var sourceInvalidated = false
    let consumerID = PreviewConsumerID()
    let role: PreviewConsumerRole
    private let backend: any EditingPreviewBackend
    private let promptCanonicalDispatch: Bool
    private struct Desired {
        let intent: EditingPreviewIntent
        let input: EditingPreviewInput
        let revision: UInt64
        let epoch: UInt64
    }
    /// One pure string for the actual immutable desired metadata; never keyed by recipe Equatable.
    private struct DesiredFingerprintKey: Equatable {
        let revision: UInt64, epoch: UInt64, generation: UInt64
        let leaseID: DevelopmentPreviewSessionID
    }
    private var desiredFingerprintMemo: (key: DesiredFingerprintKey, value: String)?
    private let recipeFingerprintForTesting: ((DevelopmentRecipe) throws -> String)?
    private func encodeRecipeFingerprint(_ recipe: DevelopmentRecipe) throws -> String {
        if let recipeFingerprintForTesting { return try recipeFingerprintForTesting(recipe) }
        return try EditingFingerprint.of(recipe)
    }
    private func fingerprint(of target: Desired, lease: EditingPreviewLease) throws -> String {
        let key = DesiredFingerprintKey(revision: target.revision, epoch: target.epoch,
            generation: lease.generation, leaseID: lease.id)
        if let cached = desiredFingerprintMemo, cached.key == key { return cached.value }
        desiredFingerprintMemo = nil
        let value = try encodeRecipeFingerprint(target.intent.recipe)
        desiredFingerprintMemo = (key, value)
        return value
    }
    private struct Fence: Equatable {
        let sourceKey: String
        let presentationID: String
        let draft: EditingDraftPresentation?
        let degrees: Double
        let crop: NormalizedCrop
        let geometryV3: DevelopmentGeometryV3?
        let engine: String
        let viewport: PreviewViewport
        init(_ intent: EditingPreviewIntent) {
            sourceKey = intent.sourceKey; presentationID = intent.presentationID; draft = intent.draftPresentation
            degrees = intent.recipe.straightenDegrees; crop = intent.recipe.crop; engine = intent.recipe.engineVersion
            geometryV3 = intent.recipe.adjustmentsV3?.geometry
            viewport = intent.viewport
        }
    }
    private enum Resource: Sendable { case lease(EditingPreviewLease), channel(EditingProgressChannel) }
    private final class Revalidation {
        let id = UUID()
        let source: EditingSourceSnapshot
        let continuation: CheckedContinuation<Void, Error>
        var cancelled = false
        init(source: EditingSourceSnapshot, continuation: CheckedContinuation<Void, Error>) { self.source = source; self.continuation = continuation }
    }
    private var canonicalGestureIntent: EditingPreviewIntent?
    private var desired: Desired?
    var canonicalGestureRequestActive: Bool {
        guard !stopped,!sourceInvalidated,retireRequested == retireCompleted,
              let desired,desired.intent == canonicalGestureIntent,boundSourceKey == desired.intent.sourceKey,
              let lease,let capability=lease.canonicalGesture else{return false}
        return capability.sessionID == lease.id && capability.sourceGeneration == lease.generation &&
            capability.sourceIdentity == lease.sourceIdentity
    }
    func supportsPromptCanonicalDispatch(_ recipe: DevelopmentRecipe) -> Bool {
        guard promptCanonicalDispatch, role == .primary, !stopped, !sourceInvalidated,
              !suspendedAfterRevalidation, retireRequested == retireCompleted,
              let desired, desired.intent.draftPresentation == nil, desired.intent.quality != .detail,
              boundSourceKey == desired.intent.sourceKey, let lease, let capability = lease.canonicalGesture else { return false }
        return capability.sessionID == lease.id && capability.sourceGeneration == lease.generation &&
            capability.sourceIdentity == lease.sourceIdentity && (try? capability.supports(recipe)) == true
    }
    private var lease: EditingPreviewLease?
    private var boundSourceKey: String?
    private var channel: EditingProgressChannel?
    private var channelEpoch: UInt64?
    private var channelFence: Fence?
    private var reader: Task<Void, Never>?
    private var lastSubmittedRevision: UInt64?
    private var latestTarget: PreviewSubmittedWork?
    private var finalSettledTarget: PreviewSubmissionID?
    private var lastSnapshotSequence: UInt64 = 0
    private var terminalOverflow: UInt64 = 0
    private var progressLedger = EditingProgressTerminalLedger()
    private var legacy: Task<Void, Never>?
    private var retiringLegacy: Task<Void, Never>?
    private var legacyDesired: Desired?
    private var legacyFinished = false
    private var driver: Task<Void, Never>?
    private var resourceChild: Task<Resource, Error>?
    private let signals: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation
    private var retireRequested: UInt64 = 0
    private var retireCompleted: UInt64 = 0
    private var retirementWaiters: [(UInt64, CheckedContinuation<Void, Never>)] = []
    private var revalidation: Revalidation?
    private var suspendedAfterRevalidation = false
    private var blockedAfterError = false
    private var revision: UInt64 = 0
    private var publicationEpoch: UInt64 = 0
    private var stopped = false
    private var displayedEpoch: UInt64 = 0
    private(set) var displayedRevision: UInt64 = 0
    private var displayedToken: PreviewSubmissionID?
    private var displayedChannel: PreviewProgressChannelID?
    private var frameInput: EditingPreviewInput?
    private var frameDrawn = false
    private var lastAcceptedDraw: ImageFrameDrawEvent?
    private(set) var frameRecipe: DevelopmentRecipe?
    private(set) var framePresentationID: String?
    private(set) var frameSourceKey: String?
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onInvalidation: (() -> Void)?
    var diagnosticSink: ((EditingPreviewDiagnosticEvent) -> Void)?
    private var diagnosticLedger = EditingPreviewTerminalLedger()
    private var activeDiagnostic: (input: EditingPreviewInput, revision: UInt64, quality: PreviewQuality)?
    var currentRevision: UInt64 { revision }
    var currentFrameWasDrawn: Bool { frameDrawn && frame?.revision == revision && displayedEpoch == publicationEpoch }
    var currentAcceptedDraw: ImageFrameDrawEvent? {
        guard currentFrameWasDrawn, let lastAcceptedDraw, lastAcceptedDraw.frameID == frame?.id else { return nil }
        return lastAcceptedDraw
    }
    var currentSourceGeneration: UInt64? { lease?.generation }
    var canInspectDevelopmentSource: Bool {
        !stopped && !sourceInvalidated && desired?.intent.isRaw == true && lease != nil && boundSourceKey == desired?.intent.sourceKey
    }
    func developmentSourceContext() async throws -> EditingPreviewSourceContext {
        guard canInspectDevelopmentSource, let lease, let target = desired,
              case .raw(let source) = target.intent.source else { throw DevelopmentPreviewError.closed }
        let facts = try await backend.sourceFacts(lease)
        try Task.checkCancellation()
        guard canInspectDevelopmentSource, self.lease?.id == lease.id, self.lease?.generation == lease.generation,
              desired?.intent.sourceKey == target.intent.sourceKey, facts.sourceGeneration == lease.generation,
              facts.sourceBinding.sourceContentID == source.contentSHA256 else { throw DevelopmentPreviewError.superseded }
        try facts.sourceBinding.validate()
        return .init(lease: lease, facts: facts)
    }
    func developmentAnalysisRequest(operationID: UUID, recipe: DevelopmentRecipe, expectedFingerprint: String,
                                    presentedFingerprint: String, stage: DevelopmentAnalysisStage,
                                    operation: DevelopmentAnalysisOperation, input: EditingPreviewInput? = nil,
                                    localInputV1: DevelopmentLocalInputV1? = nil,
                                    dehazeInputV1: DevelopmentDehazeInputV1? = nil,
                                    cropAutoInputV1: DevelopmentCropAutoInputV1? = nil,
                                    sampling: DevelopmentAnalysisSampling = .legacy) throws -> DevelopmentAnalysisRequest {
        try makeDevelopmentAnalysisRequest(operationID: operationID, recipe: recipe,
            expectedFingerprint: expectedFingerprint, presentedFingerprint: presentedFingerprint, stage: stage,
            operation: operation, input: input, localInputV1: localInputV1, dehazeInputV1: dehazeInputV1,
            cropAutoInputV1: cropAutoInputV1, sampling: sampling,
            actualRecipeFingerprint: { try self.encodeRecipeFingerprint(recipe) })
    }
    private func makeDevelopmentAnalysisRequest(operationID: UUID, recipe: DevelopmentRecipe, expectedFingerprint: String,
                                    presentedFingerprint: String, stage: DevelopmentAnalysisStage,
                                    operation: DevelopmentAnalysisOperation, input: EditingPreviewInput? = nil,
                                    localInputV1: DevelopmentLocalInputV1? = nil,
                                    dehazeInputV1: DevelopmentDehazeInputV1? = nil,
                                    cropAutoInputV1: DevelopmentCropAutoInputV1? = nil,
                                    sampling: DevelopmentAnalysisSampling = .legacy,
                                    actualRecipeFingerprint: () throws -> String) throws -> DevelopmentAnalysisRequest {
        guard canInspectDevelopmentSource, let lease, let target = desired,
              expectedFingerprint == (try actualRecipeFingerprint()) else { throw DevelopmentPreviewError.superseded }
        let visibleFingerprint = try fingerprint(of: target, lease: lease)
        if visibleFingerprint != presentedFingerprint {
            // Crop editing intentionally displays the uncropped canonical geometry stage. It is
            // still the same actual recipe apart from this explicit presentation crop override.
            var uncropped = try recipe.promotingToV3(); uncropped.adjustmentsV3?.geometry.crop = .init()
            guard (try target.intent.recipe.promotingToV3()) == uncropped else { throw DevelopmentPreviewError.superseded }
        }
        let preview = DevelopmentPreviewRequest(sessionID: lease.id, sourceGeneration: lease.generation,
            consumerID: consumerID, role: role, revision: target.revision, recipe: recipe, quality: target.intent.quality,
            viewport: target.intent.viewport, clientCorrelation: (input ?? target.input).correlationData())
        return .init(operationID: operationID, preview: preview, expectedRecipeFingerprint: expectedFingerprint,
            stage: stage, operation: operation, presentedRecipeFingerprint: visibleFingerprint, localInputV1: localInputV1,
            dehazeInputV1: dehazeInputV1, cropAutoInputV1: cropAutoInputV1, sampling: sampling)
    }
    /// Current metadata identity only. Auto Crop must not depend on bitmap/draw readiness, or
    /// mistake the deliberately uncropped presentation for the complete draft it will mutate.
    /// Natural Picker captures this exact publication, not only a matching recipe/revision.
    func currentDevelopmentPickerPublicationEpoch(frameID: UUID) -> UInt64? {
        guard canInspectDevelopmentSource,frame?.id == frameID,displayedEpoch == publicationEpoch else { return nil }
        return publicationEpoch
    }
    func isCurrentDevelopmentAnalysisRequest(_ request: DevelopmentAnalysisRequest) -> Bool {
        guard canInspectDevelopmentSource, let lease, let target = desired,
              request.preview.sessionID == lease.id, request.preview.sourceGeneration == lease.generation,
              request.preview.consumerID == consumerID, request.preview.role == role,
              request.preview.revision == revision, request.preview.revision == target.revision,
              request.preview.quality == target.intent.quality, request.preview.viewport == target.intent.viewport,
              let visible = try? EditingFingerprint.of(target.intent.recipe) else { return false }
        return visible == request.presentedRecipeFingerprint
    }
    func analyzeDevelopment(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult {
        guard canInspectDevelopmentSource, request.preview.sessionID == lease?.id,
              request.preview.sourceGeneration == lease?.generation, request.preview.consumerID == consumerID else {
            throw DevelopmentPreviewError.superseded
        }
        return try await backend.analyze(request)
    }
    /// Join the captured old analysis even after this pane has changed source/scope. Applying a
    /// current-pane guard here would discard the only handle to the retiring native worker.
    func joinDevelopmentAnalysis(_ request: DevelopmentAnalysisRequest) async { await backend.joinAnalysis(request) }
    /// Read-only proof of the actual current canonical publication, never an older progress frame.
    func thumbnailCanonicalWitness(recipe: DevelopmentRecipe, presentationID: String) -> EditingThumbnailCanonicalWitness? {
        guard canInspectDevelopmentSource, let lease, let target = desired, let frame,
              displayedEpoch == publicationEpoch, frame.leaseID == lease.id, frame.generation == lease.generation,
              frame.consumerID == consumerID, frame.revision == target.revision, frame.revision == revision,
              !frame.approximate, frame.window == nil, frame.quality == .settled || frame.quality == .detail,
              frame.quality == target.intent.quality, frameRecipe == recipe, target.intent.recipe == recipe,
              framePresentationID == presentationID, target.intent.presentationID == presentationID,
              let fingerprint = try? EditingFingerprint.of(recipe) else { return nil }
        return .init(frameID: frame.id, sessionID: lease.id, sourceGeneration: lease.generation, revision: frame.revision,
            quality: frame.quality.rawValue, viewportMaximumPixel: target.intent.viewport.maxPixel, recipeFingerprint: fingerprint)
    }
    var thumbnailBackend: any EditingPreviewBackend { backend }
    func renderDevelopmentFilterHover(recipe: DevelopmentRecipe, consumerID: PreviewConsumerID,
                                      revision: UInt64, quality: PreviewQuality = .interactive) async throws -> EditingPreviewBitmap {
        guard canInspectDevelopmentSource, let lease else { throw DevelopmentPreviewError.sourceInvalidated }
        return try await backend.render(.init(sessionID: lease.id, sourceGeneration: lease.generation,
            consumerID: consumerID, role: .primary, revision: revision, recipe: recipe,
            quality: quality, viewport: .init(maxPixel: 2400)))
    }
    func cancelDevelopmentFilterHover(_ consumerID: PreviewConsumerID) async {
        await backend.cancel(consumerID)
    }
    func thumbnailRequest(recipe: DevelopmentRecipe, kind: DevelopmentThumbnailKind, registration: DevelopmentThumbnailRegistration, basis: DevelopmentThumbnailBasis, resourceVersion: String?) throws -> DevelopmentThumbnailRequest {
        let promoted = try recipe.promotingToV3(), fp = try encodeRecipeFingerprint(recipe)
        // promotingToV3 validates then returns self for v3; this is value provenance, not Equatable.
        let promotedFP: String
        if recipe.schemaVersion == 3 { promotedFP = fp } else { promotedFP = try encodeRecipeFingerprint(promoted) }
        let analysis = try makeDevelopmentAnalysisRequest(operationID: registration.operationID, recipe: promoted,
            expectedFingerprint: promotedFP, presentedFingerprint: fp, stage: .workingImageBeforeGeometry,
            operation: .histogram, actualRecipeFingerprint: { promotedFP })
        return .init(registration: registration, preview: analysis.preview, expectedRecipeFingerprint: analysis.expectedRecipeFingerprint,
            presentedRecipeFingerprint: fp, kind: kind, target: kind == .filters ? .filters192 : .summary128, presentationMode: .managedImage,
            basis: basis, expectedPhotoFilterResourceVersion: resourceVersion)
    }
    var hasRawSource: Bool { desired?.intent.isRaw == true }
    var ownedOperationCount: Int { (resourceChild == nil ? 0 : 1) + (reader == nil ? 0 : 1) + (legacy == nil ? 0 : 1) + (retiringLegacy == nil ? 0 : 1) }
    private var diagnosticsEnabled: Bool { diagnosticSink != nil || InteractionTrace.shared.isEnabled }
    init(role: PreviewConsumerRole, backend: any EditingPreviewBackend,
         promptCanonicalDispatch: Bool = EditingPreviewPromptDispatch.enabled(),
         recipeFingerprintForTesting: ((DevelopmentRecipe) throws -> String)? = nil) {
        self.role = role; self.backend = backend; self.promptCanonicalDispatch = promptCanonicalDispatch
        self.recipeFingerprintForTesting = recipeFingerprintForTesting
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = pair.stream; signalContinuation = pair.continuation
    }
    deinit { signalContinuation.finish() }

    private static func sameDraftPixels(_ lhs: EditingDraftPresentation?, _ rhs: EditingDraftPresentation?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.focusID == rhs.focusID && lhs.workID == rhs.workID
            && lhs.draftParentID == rhs.draftParentID && lhs.selectedVersionID == rhs.selectedVersionID
            && lhs.draftBranchID == rhs.draftBranchID && lhs.comparing == rhs.comparing
        // cropOverlay and the interaction-only draftBranchEpoch deliberately do not affect pixels.
    }

    /// Rebind presentation metadata only when every pixel-affecting input is identical.
    /// The existing frame/revision/lease remain the same; no renderer or service call is made.
    func reuseForPresentation(_ requested: EditingPreviewIntent, input: EditingPreviewInput) -> Bool {
        guard let current = desired, let frame,
              !rendering, frame.revision == current.revision,
              current.intent.sourceKey == requested.sourceKey,
              current.intent.recipe == requested.recipe,
              current.intent.quality == requested.quality,
              Self.sameDraftPixels(current.intent.draftPresentation, requested.draftPresentation),
              frameRecipe == requested.recipe,
              current.intent.presentationID != requested.presentationID else { return false }
        desired = Desired(intent: requested, input: input, revision: current.revision, epoch: current.epoch)
        framePresentationID = requested.presentationID
        onChange?()
        return true
    }

    func submit(_ requested: EditingPreviewIntent, input: EditingPreviewInput, duplicateReason: String? = nil,
                allowCanonicalGesture:Bool = false) {
        var next=requested
        if allowCanonicalGesture,role == .primary,requested.quality == .interactive,requested.draftPresentation == nil,
           !stopped,!sourceInvalidated,!suspendedAfterRevalidation,retireRequested == retireCompleted,
           boundSourceKey == requested.sourceKey,let lease,let capability=lease.canonicalGesture,
           capability.sessionID == lease.id,capability.sourceGeneration == lease.generation,
           capability.sourceIdentity == lease.sourceIdentity,(try? capability.supports(requested.recipe)) == true,
           let canonical=try? EditingPreviewIntent(source:requested.source,recipe:requested.recipe,quality:.settled,
               draftPresentation:requested.draftPresentation,presentationID:requested.presentationID) {
            next=canonical;canonicalGestureIntent=canonical
        } else if !allowCanonicalGesture || next != canonicalGestureIntent {
            canonicalGestureIntent=nil
        }
        guard !stopped else { diagnoseNoRender(input, quality: next.quality, outcome: "blocked", reason: "shutdown"); return }
        if sourceInvalidated && desired?.intent.sourceKey == next.sourceKey {
            diagnoseNoRender(input, quality: next.quality, outcome: "blocked", reason: "source-invalidated"); return
        }
        guard next != desired?.intent || (frame == nil && (legacy == nil || legacyFinished) && channel == nil) || suspendedAfterRevalidation || blockedAfterError else {
            channel?.noteActivity()
            diagnoseNoRender(input, quality: next.quality, outcome: duplicateReason ?? "deduplicated", reason: "unchanged-pixels"); return
        }
        if let previous = desired?.intent,
           previous.sourceKey != next.sourceKey || previous.presentationID != next.presentationID ||
           previous.recipe.crop != next.recipe.crop || previous.recipe.straightenDegrees != next.recipe.straightenDegrees ||
           previous.recipe.adjustmentsV3?.geometry != next.recipe.adjustmentsV3?.geometry {
            fitFallback = nil
        }
        let changedFence = desired.map { Fence($0.intent) != Fence(next) } ?? true
        if changedFence {
            publicationEpoch &+= 1; resourceChild?.cancel()
            // Publication is revoked now, even while the lifecycle driver is still joining the old registration.
        }
        if desired?.intent.sourceKey != next.sourceKey && boundSourceKey != nil { requestFullRetirement() }
        if !usesProgress(next) { finishActiveDiagnostic(outcome: "superseded", reason: "newer-request") }
        revision &+= 1
        desired = Desired(intent: next, input: input, revision: revision, epoch: publicationEpoch)
        suspendedAfterRevalidation = false; blockedAfterError = false
        if frame?.quality == .detail && next.quality != .detail { clearFrame(keepingFitFallback: true) }
        rendering = true; error = nil; onChange?()
        if usesProgress(next), let channel, channelEpoch == publicationEpoch, channelFence == Fence(next), let lease {
            submitToChannel(channel, lease: lease, target: desired!)
        }
        wakeDriver()
    }
    private func usesProgress(_ intent: EditingPreviewIntent) -> Bool {
        role == .primary && intent.isRaw && intent.draftPresentation != nil && intent.quality != .detail && intent.viewport.maxPixel > 0
    }
    private func wakeDriver() {
        signalContinuation.yield(())
        guard driver == nil else { return }
        let signals = signals
        driver = Task { [weak self] in
            for await _ in signals {
                guard let self else { return }
                await self.reconcile()
                if self.stopped && self.idle && self.retireCompleted == self.retireRequested && self.revalidation == nil { self.driver = nil; return }
            }
        }
    }
    private var idle: Bool { resourceChild == nil && lease == nil && channel == nil && reader == nil && legacy == nil && retiringLegacy == nil }
    private func acquire(_ operation: @escaping @Sendable () async throws -> Resource) async -> Result<Resource, Error> {
        let task = Task { try await operation() }; resourceChild = task
        let result = await task.result
        resourceChild = nil
        return result
    }
    private func reconcile() async {
        while true {
            if retireCompleted < retireRequested {
                await retireAll()
                retireCompleted = retireRequested; finishRetirementWaiters()
            }
            if let command = revalidation { await performRevalidation(command); continue }
            guard !stopped, let target = desired else {
                await retireAll(); retireCompleted = retireRequested; finishRetirementWaiters(); return
            }
            guard !sourceInvalidated, !suspendedAfterRevalidation, !blockedAfterError else { await retireRenderer(); return }
            if lease == nil || boundSourceKey != target.intent.sourceKey {
                await retireAll()
                guard !stopped, desired?.epoch == target.epoch, desired?.intent.sourceKey == target.intent.sourceKey else { continue }
                let backend = backend, source = target.intent.source
                let result = await acquire { .lease(try await backend.open(source)) }
                switch result {
                case .success(.lease(let info)):
                    // Resource acquisition is owned even if reset/cancellation arrived during open.
                    lease = info; boundSourceKey = target.intent.sourceKey
                case .failure(let failure):
                    if desired?.epoch == target.epoch && retireCompleted == retireRequested && !stopped {
                        applyFailure(failure, target: target); blockedAfterError = !sourceInvalidated
                    }
                    return
                default: return
                }
                continue
            }
            guard let info = lease else { continue }
            if usesProgress(target.intent) {
                if channel == nil || channelEpoch != target.epoch || channelFence != Fence(target.intent) {
                    await retireRenderer()
                    await backend.cancelAndJoin(consumerID)
                    guard !stopped, let current = desired, current.epoch == target.epoch, usesProgress(current.intent), !sourceInvalidated else { continue }
                    let backend = backend, consumer = consumerID
                    let result = await acquire { .channel(try await backend.makeProgressChannel(info, consumer: consumer)) }
                    switch result {
                    case .success(.channel(let value)):
                        channel = value; channelEpoch = target.epoch; channelFence = Fence(target.intent)
                        lastSnapshotSequence = 0; lastSubmittedRevision = nil; latestTarget = nil; finalSettledTarget = nil
                        progressLedger = .init(); terminalOverflow = 0
                        startReader(value, lease: info, epoch: target.epoch)
                    case .failure(let failure):
                        if desired?.epoch == target.epoch && !stopped && retireRequested == retireCompleted {
                            applyFailure(failure, target: desired ?? target); blockedAfterError = !sourceInvalidated
                        }
                        return
                    default: return
                    }
                    continue
                }
                if lastSubmittedRevision != target.revision, let channel { channel.noteActivity(); submitToChannel(channel, lease: info, target: target) }
                return
            }
            if channel != nil || reader != nil { await retireRenderer(); continue }
            if legacyDesired?.revision != target.revision {
                // Keep strict latest semantics without losing ownership of the cancelled waiter.
                // At most one retiring waiter may coexist with the newest waiter; further inputs stay as a value.
                if let retiringLegacy { await retiringLegacy.value; self.retiringLegacy = nil }
                if let previous = legacy { previous.cancel(); retiringLegacy = previous; legacy = nil; legacyDesired = nil }
                guard !stopped, desired?.revision == target.revision, retireRequested == retireCompleted, !sourceInvalidated else { continue }
                startLegacy(target, lease: info)
            }
            return
        }
    }
    private func startLegacy(_ target: Desired, lease info: EditingPreviewLease) {
        legacyDesired = target; legacyFinished = false
        if diagnosticsEnabled {
            activeDiagnostic = (target.input, target.revision, target.intent.quality)
            InteractionTrace.shared.preview("preview.submission", input: target.input, role: role, revision: target.revision, quality: target.intent.quality, consumerID: consumerID)
        }
        let request = makeRequest(target, lease: info, progress: false)
        let promptChild = target.intent.quality == .settled && canonicalGestureRequestActive &&
            supportsPromptCanonicalDispatch(target.intent.recipe)
            ? EditingPreviewPromptDispatch.start(backend: backend, request: request) : nil
        legacy = Task { [weak self] in
            // Preserve the original strong owner during the waiter. Even if it was already gone,
            // the child was started by startLegacy and must be cancelled and actually joined.
            let owner = self
            let promptResult: EditingPreviewPromptDispatch.Outcome?
            if let promptChild {
                if owner == nil { promptChild.cancel() }
                promptResult = await EditingPreviewPromptDispatch.join(promptChild)
            } else { promptResult = nil }
            guard let self = owner else { return }
            do {
                let output: EditingPreviewBitmap
                if let promptResult {
                    if let began = promptResult.requestBeganAt {
                        InteractionTrace.shared.preview("preview.request", input: target.input, role: self.role,
                            revision: target.revision, lease: info, quality: target.intent.quality,
                            consumerID: self.consumerID, capturedAt: began)
                    }
                    output = try promptResult.result.get()
                } else {
                    InteractionTrace.shared.preview("preview.request", input: target.input, role: self.role, revision: target.revision, lease: info, quality: target.intent.quality, consumerID: self.consumerID)
                    output = try await self.backend.render(request)
                }
                guard self.acceptsExact(target), !Task.isCancelled else {
                    self.diagnoseTerminal(target.input, revision: target.revision, quality: target.intent.quality, outcome: Task.isCancelled ? "cancelled" : "superseded", reason: "late-frame", lease: info); if self.legacyDesired?.revision == target.revision { self.legacyFinished = true }; return
                }
                guard self.valid(output, request: request) else { throw DevelopmentPreviewError.invalidRequest }
                self.publish(output, request: request, input: target.input, epoch: target.epoch, token: nil, channel: nil)
                self.rendering = false; self.error = nil
                self.diagnoseTerminal(target.input, revision: target.revision, quality: target.intent.quality, outcome: "accepted", reason: "frame-delivered", lease: info, frame: output)
            } catch {
                let current = self.acceptsExact(target) && !Task.isCancelled
                self.diagnoseTerminal(target.input, revision: target.revision, quality: target.intent.quality,
                    outcome: Task.isCancelled ? "cancelled" : (current ? "error" : "superseded"), reason: current ? "backend" : "retired-request", lease: info)
                if current { self.applyFailure(error, target: target) }
            }
            if self.legacyDesired?.revision == target.revision { self.legacyFinished = true }; self.onChange?()
        }
    }
    private func makeRequest(_ target: Desired, lease: EditingPreviewLease, progress: Bool) -> DevelopmentPreviewRequest {
        DevelopmentPreviewRequest(sessionID: lease.id, sourceGeneration: lease.generation, consumerID: consumerID, role: role,
            revision: target.revision, recipe: target.intent.recipe, quality: target.intent.quality, viewport: target.intent.viewport,
            deliveryPolicy: progress ? .inFlightProgress : .latestOnly,
            clientCorrelation: progress && diagnosticsEnabled ? target.input.correlationData() : nil)
    }
    private func submitToChannel(_ value: EditingProgressChannel, lease: EditingPreviewLease, target: Desired) {
        guard channel?.id == value.id, channelEpoch == target.epoch, desired?.revision == target.revision, !sourceInvalidated else { return }
        do {
            let request = makeRequest(target, lease: lease, progress: true)
            let receipt = try value.submit(request)
            latestTarget = receipt.work; lastSubmittedRevision = target.revision
            if target.intent.quality == .settled { finalSettledTarget = receipt.work.id } else { finalSettledTarget = nil }
            rendering = true; error = nil
            InteractionTrace.shared.preview("preview.submission", input: target.input, role: role, revision: target.revision, lease: lease, quality: target.intent.quality, consumerID: consumerID, tokenID: receipt.work.id.rawValue, channelID: value.id.rawValue, publicationEpoch: target.epoch)
            if let replaced = receipt.replacedBeforeAdmission { diagnoseProgressTerminal(replaced, outcome: "superseded", reason: "before-admission", channel: value.id) }
        } catch { if acceptsExact(target) { applyFailure(error, target: target) } }
    }
    private func startReader(_ value: EditingProgressChannel, lease: EditingPreviewLease, epoch: UInt64) {
        reader = Task { [weak self] in
            for await snapshot in value.snapshots {
                guard !Task.isCancelled else { return }
                self?.receive(snapshot, expected: value.id, lease: lease, epoch: epoch)
            }
        }
    }
    private func receive(_ snapshot: PreviewDeliverySnapshot, expected: PreviewProgressChannelID, lease info: EditingPreviewLease, epoch: UInt64) {
        guard !stopped, channel?.id == expected, snapshot.channelID == expected,
              snapshot.sessionID == info.id, snapshot.sourceGeneration == info.generation, snapshot.consumerID == consumerID else { return }
        // Physical trust belongs to the current lease, even if an old geometry request discovered the change.
        if snapshot.state == .sourceInvalidated, lease?.id == info.id, lease?.generation == info.generation,
           desired?.intent.sourceKey == boundSourceKey {
            invalidateDisplayedSource(); onInvalidation?(); return
        }
        guard channelEpoch == epoch, publicationEpoch == epoch, snapshot.sequence > lastSnapshotSequence else { return }
        lastSnapshotSequence = snapshot.sequence
        if snapshot.state != .open {
            if snapshot.state == .sourceInvalidated { invalidateDisplayedSource(); onInvalidation?() }
            else { rendering = false; blockedAfterError = true; error = "预览已停止，请重试。"; onChange?() }
            return
        }
        progressLedger.register(snapshot.active?.id.rawValue, snapshot.pending?.id.rawValue, snapshot.latestTarget?.id.rawValue)
        for terminal in snapshot.terminals {
            diagnoseProgressTerminal(terminal.work, outcome: terminal.outcome.rawValue, reason: terminal.failure == nil ? "backend" : "backend-failure", channel: expected)
        }
        if snapshot.terminalOverflowCount > terminalOverflow {
            let gap = snapshot.terminalOverflowCount - terminalOverflow; terminalOverflow = snapshot.terminalOverflowCount
            if diagnosticsEnabled {
                InteractionTrace.shared.preview("preview.coverage-gap", input: .unattributed(id: expected.rawValue, reason: "terminal-overflow"), role: role, revision: revision,
                    consumerID: consumerID, outcome: "missing", reason: "terminal-ring-overflow-\(gap)", channelID: expected.rawValue, publicationEpoch: epoch)
            }
        }
        // The synchronous receipt identifies our latest target; old conflated target snapshots cannot clear new busy/error.
        if let target = snapshot.latestTarget, target.id == latestTarget?.id {
            if let terminal = snapshot.latestTargetTerminal, terminal.work.id == target.id {
                rendering = false
                if terminal.outcome == .failed { error = terminal.message ?? "无法计算最新预览，请重试。" }
                else if terminal.outcome == .completed { error = nil }
                else { error = "最新预览已取消，请重试。" }
                diagnoseProgressTerminal(terminal.work, outcome: terminal.outcome.rawValue, reason: "latest-target", channel: expected)
                if terminal.failure == .sourceInvalidated { invalidateDisplayedSource(); onInvalidation?(); return }
            } else { rendering = true }
        }
        if let completion = snapshot.latestCompleted {
            let request = completion.work.request, output = EditingPreviewBitmap(completion.frame)
            guard request.deliveryPolicy == .inFlightProgress, request.sessionID == info.id, request.sourceGeneration == info.generation,
                  request.consumerID == consumerID, request.role == .primary, request.viewport.maxPixel == 2400,
                  request.quality != .detail, request.revision <= revision,
                  request.recipe.straightenDegrees == channelFence?.degrees, request.recipe.crop == channelFence?.crop,
                  request.recipe.engineVersion == channelFence?.engine, valid(output, request: request),
                  (displayedEpoch != epoch || request.revision > displayedRevision),
                  let desired, Fence(desired.intent) == channelFence else { onChange?(); return }
            let exact = completion.work.id == latestTarget?.id && request.revision == desired.revision
            publish(output, request: request, input: diagnosticsEnabled ? .decodeCorrelation(request.clientCorrelation, token: completion.work.id.rawValue) : nil,
                    epoch: epoch, token: completion.work.id, channel: expected)
            if diagnosticsEnabled {
                InteractionTrace.shared.preview("preview.publication", input: frameInput ?? .unattributed(id: completion.work.id.rawValue, reason: "missing-correlation"), role: role, revision: request.revision,
                    lease: info, quality: request.quality, frame: output, consumerID: consumerID, outcome: "accepted", reason: exact ? "exact" : "progress",
                    tokenID: completion.work.id.rawValue, channelID: expected.rawValue, publicationEpoch: epoch,
                    requestedRevision: revision, displayedRevision: displayedRevision)
            }
            if let input = frameInput { diagnosticSink?(.init(inputOrigin: input.origin, association: input.association, control: input.control, operationID: input.id,
                pane: role, revision: request.revision, quality: request.quality, outcome: exact ? "accepted" : "progress", reason: "publication")) }
        }
        onChange?()
    }
    private func valid(_ output: EditingPreviewBitmap, request: DevelopmentPreviewRequest) -> Bool {
        output.leaseID == request.sessionID && output.generation == request.sourceGeneration && output.consumerID == request.consumerID
            && output.revision == request.revision && output.quality == request.quality && output.id != frame?.id
    }
    private func publish(_ output: EditingPreviewBitmap, request: DevelopmentPreviewRequest, input: EditingPreviewInput?, epoch: UInt64,
                         token: PreviewSubmissionID?, channel: PreviewProgressChannelID?) {
        if output.quality != .detail, output.window == nil { fitFallback = output }
        frame = output; frameRecipe = request.recipe; framePresentationID = desired?.intent.presentationID
        frameSourceKey = desired?.intent.sourceKey; frameInput = input; frameDrawn = false
        displayedEpoch = epoch; displayedRevision = request.revision; displayedToken = token; displayedChannel = channel
    }
    private func acceptsExact(_ target: Desired) -> Bool { !stopped && !sourceInvalidated && desired?.revision == target.revision && publicationEpoch == target.epoch }
    @discardableResult func didDraw(_ event: ImageFrameDrawEvent, canvasDiagnostic: Bool = false) -> Bool {
        var accepted = false
        defer {
            if canvasDiagnostic && InteractionTrace.shared.canvasDiagnosticEnabled {
                let reason: CanvasAcknowledgementReason
                if accepted { reason = .accepted }
                else if stopped || sourceInvalidated { reason = .inactiveSource }
                else if frame?.id != event.frameID { reason = .replacedFrame }
                else if displayedEpoch != publicationEpoch { reason = .changedEpoch }
                else if frameDrawn { reason = .alreadyAcknowledged }
                else { reason = .scopeFence }
                InteractionTrace.shared.canvasAcknowledgement(event.frameID, current: frame?.id, reason: reason)
            }
        }
        guard !frameDrawn, let frame, let lease, event.frameID == frame.id, displayedEpoch == publicationEpoch,
              frame.leaseID == lease.id, frame.generation == lease.generation, frame.consumerID == consumerID,
              frame.revision == displayedRevision, !sourceInvalidated, !stopped,
              (displayedChannel == nil ? frame.revision == revision : displayedChannel == channel?.id) else { return false }
        frameDrawn = true
        lastAcceptedDraw = event
        accepted = true
        if let frameInput {
            InteractionTrace.shared.preview("preview.draw-return", input: frameInput, role: role, revision: displayedRevision,
                lease: lease, quality: frame.quality, frame: frame, draw: event, consumerID: consumerID, outcome: "drawn", reason: "AppKit-draw-return",
                tokenID: displayedToken?.rawValue, channelID: displayedChannel?.rawValue, publicationEpoch: displayedEpoch,
                requestedRevision: revision, displayedRevision: displayedRevision)
            diagnosticSink?(.init(inputOrigin: frameInput.origin, association: frameInput.association, control: frameInput.control, operationID: frameInput.id,
                pane: role, revision: displayedRevision, quality: frame.quality, outcome: "drawn", reason: "AppKit-draw-return"))
        }
        return true
    }
    private func applyFailure(_ failure: Error, target: Desired) {
        guard acceptsExact(target) else { return }
        rendering = false
        switch failure {
        case is CancellationError, DevelopmentPreviewError.superseded, DevelopmentPreviewError.closed: break
        case DevelopmentPreviewError.sourceInvalidated:
            invalidateDisplayedSource(); if target.intent.isRaw { onInvalidation?() }
        case DevelopmentPreviewError.memoryBudgetExceeded: error = "预览内存不足。请先结束比较或退出实际像素，再重试。"
        case DevelopmentPreviewError.capacityExceeded: error = "上一张照片仍在释放预览，请稍后重试。"
        default: error = "无法读取此预览：\(failure.localizedDescription)"
        }
        onChange?()
    }
    func invalidateDisplayedSource() {
        canonicalGestureIntent=nil
        guard !sourceInvalidated else { return }
        finishActiveDiagnostic(outcome: "source-invalidated", reason: "source-revoked")
        publicationEpoch &+= 1; revision &+= 1; resourceChild?.cancel()
        desiredFingerprintMemo = nil
        clearFrame(); sourceInvalidated = true; rendering = false
        error = "原片已变化或不可用。重新验证后才能继续初修。"; onChange?(); wakeDriver()
    }
    func revalidate(source: EditingSourceSnapshot) async throws {
        guard hasRawSource, !stopped, revalidation == nil else { throw DevelopmentPreviewError.invalidRequest }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let command = Revalidation(source: source, continuation: continuation)
                revalidation = command
                revalidationCallerID = (id, command.id)
                wakeDriver()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancelRevalidation(id) } })
    }
    private var revalidationCallerID: (UUID, UUID)?
    private func cancelRevalidation(_ caller: UUID) {
        guard revalidationCallerID?.0 == caller, let revalidation else { return }
        revalidation.cancelled = true; resourceChild?.cancel(); wakeDriver()
    }
    private func performRevalidation(_ command: Revalidation) async {
        guard !command.cancelled, !stopped, desired != nil else {
            if revalidation?.id == command.id { revalidation = nil; revalidationCallerID = nil }
            command.continuation.resume(throwing: CancellationError()); return
        }
        await retireRenderer()
        let backend = backend, old = lease, source = command.source
        let result = await acquire {
            if let old { return .lease(try await backend.revalidate(old.id, source: .raw(source))) }
            return .lease(try await backend.open(.raw(source)))
        }
        if case .success(.lease(let value)) = result { lease = value }
        defer { if revalidation?.id == command.id { revalidation = nil; revalidationCallerID = nil } }
        guard !command.cancelled, !stopped, desired != nil, retireRequested == retireCompleted else {
            command.continuation.resume(throwing: CancellationError()); return
        }
        switch result {
        case .success(.lease):
            do {
                guard let previous = desired else { throw CancellationError() }
                let replacement = try EditingPreviewIntent(source: .raw(source), recipe: previous.intent.recipe, quality: previous.intent.quality,
                    draftPresentation: previous.intent.draftPresentation, presentationID: previous.intent.presentationID)
                publicationEpoch &+= 1
                desired = Desired(intent: replacement, input: previous.input, revision: previous.revision, epoch: publicationEpoch)
                boundSourceKey = replacement.sourceKey; sourceInvalidated = false; blockedAfterError = false; suspendedAfterRevalidation = true
                error = nil; onChange?(); command.continuation.resume()
            } catch { command.continuation.resume(throwing: error) }
        case .failure(let failure): command.continuation.resume(throwing: failure)
        default: command.continuation.resume(throwing: DevelopmentPreviewError.invalidRequest)
        }
    }
    private func retireLegacy() async {
        guard legacy != nil || retiringLegacy != nil else { return }
        let old = legacy, retiring = retiringLegacy
        old?.cancel(); retiring?.cancel(); await backend.cancelAndJoin(consumerID)
        await old?.value; await retiring?.value
        legacy = nil; retiringLegacy = nil; legacyDesired = nil; legacyFinished = false
    }
    private func retireRenderer() async {
        if let old = channel {
            let observer = reader; channel = nil; reader = nil; channelEpoch = nil; channelFence = nil; latestTarget = nil; finalSettledTarget = nil
            observer?.cancel(); await backend.closeProgressChannel(old.id); await observer?.value
        }
        await retireLegacy()
    }
    private func retireAll() async {
        await retireRenderer()
        if let old = lease { lease = nil; boundSourceKey = nil; await backend.close(old.id) }
    }
    private func clearFrame(keepingFitFallback: Bool = false) {
        if !keepingFitFallback { fitFallback = nil }
        frame = nil; frameRecipe = nil; framePresentationID = nil; frameSourceKey = nil; frameInput = nil
        displayedToken = nil; displayedChannel = nil; displayedRevision = 0; displayedEpoch = 0
    }
    private func requestFullRetirement() { desiredFingerprintMemo=nil; canonicalGestureIntent=nil; retireRequested &+= 1; resourceChild?.cancel() }
    func reset() {
        desiredFingerprintMemo=nil; canonicalGestureIntent=nil
        if stopped && idle && revalidation == nil {
            // A finished AsyncStream reader is not a new retirement owner. Empty repeated shutdown is synchronous.
            desired = nil; clearFrame(); rendering = false; error = nil; sourceInvalidated = false
            retireCompleted = retireRequested; finishRetirementWaiters(); onChange?()
            if driver != nil { signalContinuation.yield(()) }
            return
        }
        finishActiveDiagnostic(outcome: "cancelled", reason: stopped ? "shutdown" : "context-closed")
        publicationEpoch &+= 1; revision &+= 1; desired = nil; revalidation?.cancelled = true
        requestFullRetirement(); clearFrame(); rendering = false; error = nil; sourceInvalidated = false
        suspendedAfterRevalidation = false; blockedAfterError = false; onChange?(); wakeDriver()
    }
    private func finishRetirementWaiters() {
        let ready = retirementWaiters.filter { $0.0 <= retireCompleted }; retirementWaiters.removeAll { $0.0 <= retireCompleted }
        for (_, continuation) in ready { continuation.resume() }
    }
    func joinRetirement() async {
        let ticket = retireRequested
        guard retireCompleted < ticket else { return }
        await withCheckedContinuation { retirementWaiters.append((ticket, $0)) }
    }
    func clearIfNeeded() { if desired != nil || lease != nil || channel != nil || legacy != nil { reset() } }
    func beginShutdown() { stopped = true; reset() }
    func finishShutdown() async { await joinRetirement(); await driver?.value }
    func shutdown() async { beginShutdown(); await finishShutdown() }

    private func finishActiveDiagnostic(outcome: String, reason: String) {
        guard let activeDiagnostic else { return }
        diagnoseTerminal(activeDiagnostic.input, revision: activeDiagnostic.revision, quality: activeDiagnostic.quality, outcome: outcome, reason: reason, lease: lease)
    }
    private func diagnoseTerminal(_ input: EditingPreviewInput, revision: UInt64, quality: PreviewQuality,
                                  outcome: String, reason: String, lease: EditingPreviewLease? = nil, frame: EditingPreviewBitmap? = nil) {
        guard diagnosticsEnabled, diagnosticLedger.acceptRenderedTerminal(revision: revision) else { return }
        if activeDiagnostic?.revision == revision { activeDiagnostic = nil }
        InteractionTrace.shared.preview(outcome == "accepted" ? "preview.frame" : "preview.terminal", input: input, role: role,
            revision: revision, lease: lease, quality: quality, frame: frame, consumerID: consumerID, outcome: outcome, reason: reason)
        diagnosticSink?(.init(inputOrigin: input.origin, association: input.association, control: input.control, operationID: input.id,
            pane: role, revision: revision, quality: quality, outcome: outcome, reason: reason))
    }
    private func diagnoseProgressTerminal(_ work: PreviewSubmittedWork, outcome: String, reason: String, channel: PreviewProgressChannelID) {
        guard diagnosticsEnabled, progressLedger.accept(work.id.rawValue) else { return }
        let input = EditingPreviewInput.decodeCorrelation(work.request.clientCorrelation, token: work.id.rawValue)
        InteractionTrace.shared.preview("preview.terminal", input: input, role: role, revision: work.request.revision,
            lease: lease, quality: work.request.quality, consumerID: consumerID, outcome: outcome, reason: reason,
            tokenID: work.id.rawValue, channelID: channel.rawValue, publicationEpoch: channelEpoch)
        diagnosticSink?(.init(inputOrigin: input.origin, association: input.association, control: input.control, operationID: input.id,
            pane: role, revision: work.request.revision, quality: work.request.quality, outcome: outcome, reason: reason))
    }
    private func diagnoseNoRender(_ input: EditingPreviewInput, quality: PreviewQuality, outcome: String, reason: String) {
        guard diagnosticsEnabled, diagnosticLedger.acceptNoRender(operation: input.id, quality: quality, outcome: outcome) else { return }
        InteractionTrace.shared.preview("preview.terminal", input: input, role: role, revision: revision, lease: lease,
            quality: quality, consumerID: consumerID, outcome: outcome, reason: reason)
        diagnosticSink?(.init(inputOrigin: input.origin, association: input.association, control: input.control, operationID: input.id,
            pane: role, revision: revision, quality: quality, outcome: outcome, reason: reason))
    }
}

@MainActor final class EditingPreviewCoordinator {
    let primary: EditingPreviewPane
    let comparison: EditingPreviewPane
    init(backend: any EditingPreviewBackend = SharedEditingPreviewBackend(),
         promptCanonicalDispatch: Bool = EditingPreviewPromptDispatch.enabled()) {
        primary = EditingPreviewPane(role: .primary, backend: backend, promptCanonicalDispatch: promptCanonicalDispatch)
        comparison = EditingPreviewPane(role: .comparison, backend: backend, promptCanonicalDispatch: promptCanonicalDispatch)
    }
    func reset() { primary.reset(); comparison.reset() }
    func invalidateRawSources() {
        if primary.hasRawSource { primary.invalidateDisplayedSource() }
        if comparison.hasRawSource { comparison.invalidateDisplayedSource() }
    }
    func revalidateRawSources(_ source: EditingSourceSnapshot) async throws {
        if primary.hasRawSource { try await primary.revalidate(source: source) }
        if comparison.hasRawSource { try await comparison.revalidate(source: source) }
    }
    func shutdown() async {
        primary.beginShutdown(); comparison.beginShutdown()
        await primary.finishShutdown(); await comparison.finishShutdown()
    }
}
