import AppKit
import CryptoKit
import SwiftUI
import RAWMasterImaging
import RAWMasterCore

/// Opt-in local diagnostics. Timestamping precedes asynchronous disk output; no images or paths are logged.
@MainActor
final class InteractionTrace {
    static let shared = InteractionTrace()
    private let writer: DispatchQueue = DispatchQueue(label: "RAWMaster.interaction-trace", qos: .utility)
    private let destination: URL?
    private var monitor: Any?
    private var operation: String?
    private var inputKind = "none"
    private var committed: [String: String] = [:]
    private var updated: Set<String> = []
    private var thumbnailDiagnostics = ThumbnailDiagnosticLimiter(limit:
      Bundle.main.bundleIdentifier == "io.robinqu.RAWMaster.preview022" &&
      ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_POINTWISE_V1"] == "1" ? 4096:128)

    private static let canvasDiagnosticOptIn = Bundle.main.bundleIdentifier == "io.robinqu.RAWMaster.preview022"
        && ProcessInfo.processInfo.environment["RAWMASTER_QA_CANVAS_DRAW_TRACE"] == "1"
    private var canvasDiagnosticBuffer = CanvasDiagnosticBuffer(limit: 512)
    private let qaWindowGeometry = QAInitialWindowGeometry.Evidence()
    func initialWindowViewportSink(frameID: UUID?, quality: PreviewQuality?) -> (@MainActor (ImageCanvasViewportSnapshot) -> Void)? {
        guard destination != nil, let requested = QAInitialWindowGeometry.requestedSize else { return nil }
        return { [weak self] snapshot in
            self?.qaWindowGeometry.append(snapshot, requested: requested, frameID: frameID,
                quality: quality, at: DispatchTime.now().uptimeNanoseconds)
        }
    }
    var canvasDiagnosticEnabled: Bool { Self.canvasDiagnosticOptIn && destination != nil }
    var canvasDiagnosticSink: (@MainActor (ImageCanvasDiagnosticEvent) -> Void)? {
        guard canvasDiagnosticEnabled else { return nil }
        return { [weak self] event in
            switch event {
            case let .installed(canvas, frame, at):
                self?.canvasDiagnosticBuffer.append("canvas.install", at: at, canvas: canvas, frame: frame)
            case let .drawn(canvas, frame, began, returned):
                self?.canvasDiagnosticBuffer.append("canvas.raw-draw", at: returned, canvas: canvas, frame: frame, began: began)
            case let .dismantled(canvas, at):
                self?.canvasDiagnosticBuffer.append("canvas.detach", at: at, canvas: canvas)
            }
        }
    }

    func canvasAcknowledgement(_ frame: UUID, current: UUID?, reason: CanvasAcknowledgementReason) {
        canvasDiagnosticBuffer.append("canvas.ack", at: DispatchTime.now().uptimeNanoseconds,
                                      frame: frame, current: current, reason: reason)
    }

    private static let typedValueDiagnosticOptIn = Bundle.main.bundleIdentifier == "io.robinqu.RAWMaster.preview022"
        && ProcessInfo.processInfo.environment["RAWMASTER_QA_TYPED_VALUE_TRACE"] == "1"
    private var typedValueDiagnosticCount = 0
    var typedValueDiagnosticEnabled: Bool {
        Self.typedValueDiagnosticOptIn && destination != nil && typedValueDiagnosticCount < 128
    }
    /// QA-only scalar evidence; bit patterns distinguish actual value rollback from rounded AX text.
    func typedValueInput(control: String, incoming: Double, before: Double, after: Double,
                         gesture: UUID?, outcome: String, nativeEvent: NSEvent?) {
        guard typedValueDiagnosticEnabled else { return }
        typedValueDiagnosticCount += 1
        var fields: [String: Any] = ["control": control, "sequence": typedValueDiagnosticCount,
            "incoming": String(incoming), "incomingBits": String(incoming.bitPattern, radix: 16),
            "before": String(before), "beforeBits": String(before.bitPattern, radix: 16),
            "after": String(after), "afterBits": String(after.bitPattern, radix: 16),
            "outcome": outcome, "nativeEventType": nativeEvent.map { String(describing: $0.type) } ?? "missing"]
        if let gesture { fields["gestureID"] = gesture.uuidString }
        if let nativeEvent, nativeEvent.timestamp.isFinite {
            fields["nativeEventTimestamp"] = nativeEvent.timestamp
        }
        record("qa.typed-value", fields: fields, includeAssociation: false)
    }

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let path = arguments.firstIndex(of: "--interaction-trace").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["RAWMASTER_INTERACTION_TRACE"]
        destination = path.map { URL(fileURLWithPath: $0) }
    }
    var isEnabled: Bool { destination != nil }
    func sceneDrawableCompleted(frame: DevelopmentScenePreviewFrameV1,
                                display: SceneDisplayEnvironment, windowNumber: Int, pixelSize: CGSize,
                                edrEnabled: Bool, nativeWindow: Bool) {
        guard isEnabled else { return }
        var fields: [String: Any] = ["frameID": frame.id.uuidString, "target": frame.target.rawValue, "displayID": display.id,
            "windowNumber": windowNumber, "headroom": display.headroom, "potentialHeadroom": display.potentialHeadroom,
            "pixelWidth": pixelSize.width, "pixelHeight": pixelSize.height, "edrEnabled": edrEnabled, "nativeWindow": nativeWindow]
        if let execution = frame.execution {
            fields["graphBackend"] = execution.backend.rawValue
            fields["graphDispatches"] = execution.dispatches
            fields["graphPeakBytes"] = execution.peakBytes
            fields["graphFallbackReason"] = execution.fallbackReason
        }
        if let profile = display.colorProfile {
            fields["displayProfileSHA256"] = SHA256.hash(data: profile).map { String(format: "%02x", $0) }.joined()
        }
        record("scene.drawable.completed", fields: fields, includeAssociation: false)
    }
    /// Lazy, opt-in, process-bounded metadata. This family never inherits event association IDs.
    func thumbnail(_ stage: ThumbnailDiagnosticStage, kind: DevelopmentThumbnailKind? = nil,
                   _ payload: () -> ThumbnailDiagnosticPayload = { .init() }) {
        guard let fields = thumbnailDiagnostics.collect(enabled: isEnabled, stage: stage, kind: kind, payload) else { return }
        record("thumbnail.diagnostic", fields: fields, includeAssociation: false)
    }
    private var acceptedBWSummaryV2Count = 0
    func recordAcceptedBWSummaryV2(_ result: DevelopmentAnalysisResult, parameters: DevelopmentBlackAndWhiteV3) {
        guard isEnabled, acceptedBWSummaryV2Count < 128,
              Bundle.main.bundleIdentifier == "io.robinqu.RAWMaster.preview022",
              ProcessInfo.processInfo.environment["RAWMASTER_QA_BW_SUMMARY_V2"] == "1" else { return }
        acceptedBWSummaryV2Count += 1
        let values = [parameters.intensity, parameters.neutrals, parameters.tone]
        record("qa.bw-summary.accepted", fields: ["operationID": result.operationID.uuidString,
            "samplingVersion": result.samplingVersion, "sequence": acceptedBWSummaryV2Count,
            "intensity": values[0], "neutrals": values[1], "tone": values[2],
            "doubleBits": values.map { String($0.bitPattern, radix: 16) }], includeAssociation: false)
    }
    func workbenchTeardown(_ phase: String, mounted: Int, result: QAWorkbenchTeardown.Result? = nil,
                           thumbnails: DevelopmentThumbnailStatistics) {
        var fields: [String: Any] = ["phase": phase, "mounted": mounted,
            "thumbnailActive": thumbnails.active, "thumbnailPending": thumbnails.pending,
            "thumbnailReadySets": thumbnails.readySets, "thumbnailDisplaySets": thumbnails.displaySets,
            "thumbnailManagedBackingBytes": thumbnails.managedBackingBytes,
            "thumbnailRetiredManagedBackingBytes": thumbnails.retiredManagedBackingBytes]
        if let result {
            fields["outcome"] = result.outcome; fields["watched"] = result.watched; fields["remaining"] = result.remaining
        }
        record("qa.workbench-teardown", fields: fields, includeAssociation: false)
    }
    func recordAnalysisFailure(stage: AnalysisFailureStage, error: Error) {
        guard isEnabled else { return }
        record("analysis.failure", fields: AnalysisFailureDiagnostic.fields(stage: stage, error: error))
    }
    func install() {
        guard destination != nil, monitor == nil else { return }
        record("session", fields: ["boundary": "native-event-to-selection-and-NSView-update; not-display-presentation",
                                  "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                  "doubleClickIntervalMs": NSEvent.doubleClickInterval * 1000])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .leftMouseUp {
                self.operation = UUID().uuidString
                self.inputKind = event.type == .keyDown ? "keyboard" : "pointer"
            }
            self.record(event.type == .leftMouseDown ? "input.down" : (event.type == .leftMouseUp ? "input.up" : "input.key"),
                        time: event.timestamp,
                        fields: event.type == .keyDown ? ["keyCode": event.keyCode] : ["clickCount": event.clickCount])
            return event
        }
    }
    func selectionCommitted(assetID: String, changed: Bool, count: Int) {
        guard destination != nil, let operation else { return }
        committed[assetID] = operation
        record("selection.commit", fields: ["assetID": assetID, "changed": changed, "selectedCount": count])
    }
    func selectionViewUpdated(assetID: String?) {
        guard destination != nil, let assetID, let token = committed[assetID], !updated.contains(token) else { return }
        updated.insert(token)
        record("selection.view-update", token: token, fields: ["assetID": assetID])
    }
    func preview(_ event: String, input: EditingPreviewInput, role: PreviewConsumerRole, revision: UInt64,
                 lease: EditingPreviewLease? = nil, quality: PreviewQuality? = nil,
                 frame: EditingPreviewBitmap? = nil, draw: ImageFrameDrawEvent? = nil,
                 consumerID: PreviewConsumerID? = nil, outcome: String? = nil, reason: String? = nil,
                 tokenID: UUID? = nil, channelID: UUID? = nil, publicationEpoch: UInt64? = nil,
                 requestedRevision: UInt64? = nil, displayedRevision: UInt64? = nil,
                 capturedAt: UInt64? = nil, viewport: PreviewViewport? = nil) {
        guard isEnabled else { return }
        var fields: [String: Any] = ["pane": role.rawValue, "revision": revision, "control": input.control,
            "phase": input.phase, "inputOrigin": input.origin.rawValue, "eventAssociation": input.association.rawValue,
            "paneVisibility": "unmeasured",
            "parameterCommitUptimeNanoseconds": input.committedAt,
            "metricBoundary": "AppKit-draw-return; not-WindowServer-presentation"]
        if let time = input.eventAt { fields["inputUptimeNanoseconds"] = time }
        if let age = input.eventAgeNanoseconds { fields["nativeEventAgeMilliseconds"] = Double(age) / 1_000_000 }
        if input.origin == .nativeAction && input.eventAt == nil { fields["nativeAssociationMissingReason"] = input.association.rawValue }
        if let gesture = input.gestureID { fields["gestureID"] = gesture.uuidString }
        if let trigger = input.settleTriggeredAt { fields["settleTriggeredUptimeNanoseconds"] = trigger }
        if let release = input.releaseEventAt { fields["releaseEventUptimeNanoseconds"] = release }
        if let consumerID { fields["consumerID"] = consumerID.rawValue.uuidString }
        if let tokenID { fields["submissionID"] = tokenID.uuidString }
        if let channelID { fields["channelID"] = channelID.uuidString }
        if let publicationEpoch { fields["publicationEpoch"] = publicationEpoch }
        if let requestedRevision { fields["requestedRevision"] = requestedRevision }
        if let displayedRevision {
            fields["displayedRevision"] = displayedRevision
            if let requestedRevision, requestedRevision >= displayedRevision { fields["revisionLag"] = requestedRevision - displayedRevision }
        }
        if input.origin == .unattributed { fields["correlationMissingReason"] = input.association.rawValue }
        if let outcome { fields["outcome"] = outcome }
        if let reason { fields["reason"] = reason }
        fields["renderTerminal"] = event == "preview.frame" || (event == "preview.terminal" && !["deduplicated", "overlay-only", "blocked"].contains(outcome ?? ""))
        fields["pixelRequest"] = !["preview.parameter", "preview.interaction"].contains(event) && !["deduplicated", "overlay-only", "blocked"].contains(outcome ?? "")
        if let lease { fields["leaseID"] = lease.id.rawValue.uuidString; fields["sourceGeneration"] = lease.generation }
        if let quality { fields["quality"] = quality.rawValue }
        if let viewport, quality == .detail {
            if let rect = viewport.window {
                fields["viewportWindow"] = [rect.minX, rect.minY, rect.width, rect.height]
            } else {
                fields["viewportWindow"] = NSNull()
            }
            if let scale = viewport.detailScale { fields["viewportScale"] = scale }
        }
        if let frame {
            fields["frameID"] = frame.id.uuidString; fields["approximate"] = frame.approximate
            fields["pixelWidth"] = Int(frame.outputSize.width); fields["pixelHeight"] = Int(frame.outputSize.height)
        }
        if let draw {
            fields["drawBeganUptimeNanoseconds"] = draw.drawBeganUptimeNanoseconds
            fields["drawReturnedUptimeNanoseconds"] = draw.drawReturnedUptimeNanoseconds
            if input.committedAt > 0, draw.drawReturnedUptimeNanoseconds >= input.committedAt {
                fields["parameterToDrawReturnMilliseconds"] = Double(draw.drawReturnedUptimeNanoseconds - input.committedAt) / 1_000_000
            }
            if let time = input.eventAt, draw.drawReturnedUptimeNanoseconds >= time {
                fields["inputToDrawReturnMilliseconds"] = Double(draw.drawReturnedUptimeNanoseconds - time) / 1_000_000
            }
            if let trigger = input.settleTriggeredAt, draw.drawReturnedUptimeNanoseconds >= trigger {
                fields["settleTriggerToDrawReturnMilliseconds"] = Double(draw.drawReturnedUptimeNanoseconds - trigger) / 1_000_000
            }
            if let release = input.releaseEventAt, draw.drawReturnedUptimeNanoseconds >= release {
                fields["releaseToDrawReturnMilliseconds"] = Double(draw.drawReturnedUptimeNanoseconds - release) / 1_000_000
            }
        }
        // The prompt child returns this scalar with its actual result. Logging never gates rendering;
        // consumers use the captured time/identity rather than assuming file-write order is event order.
        if let capturedAt { fields["capturedUptimeNanoseconds"] = capturedAt }
        record(event, time: capturedAt.map { Double($0) / 1_000_000_000 } ?? ProcessInfo.processInfo.systemUptime,
               token: input.id.uuidString, fields: fields)
    }
private var previewCacheShutdownSummaryGate = PreviewCacheShutdownSummaryGate()

func claimPreviewCacheShutdownSummary() -> Bool {
  previewCacheShutdownSummaryGate.claim(traceEnabled: isEnabled)
}

func previewCacheShutdownSummary(_ s: PreviewStatistics) {
  guard previewCacheShutdownSummaryGate.emit(traceEnabled: isEnabled) else { return }
  record("preview.cache.shutdown-summary", token: "shutdown", fields: PreviewCacheShutdownSummaryDiagnostic.fields(s))
}
    func flush() {
        if QAInitialWindowGeometry.requestedSize != nil, let rows = qaWindowGeometry.seal() {
            for row in rows {
                record("qa.window.viewport", time: Double(row.at) / 1_000_000_000, fields: row.fields, includeAssociation: false)
            }
            record("qa.window.viewport-seal", fields: ["rowCount": rows.count, "overflow": qaWindowGeometry.overflow,
                "matchedCanvasQualification": "NOT_ASSIGNED_REQUIRES_PUBLIC_CAPTURE"], includeAssociation: false)
        }
        if canvasDiagnosticEnabled, !canvasDiagnosticBuffer.sealed {
            canvasDiagnosticBuffer.sealed = true
            for row in canvasDiagnosticBuffer.rows {
                record(row.event, time: Double(row.at) / 1_000_000_000,
                       fields: row.fields, includeAssociation: false)
            }
            record("canvas.seal", fields: ["rowCount": canvasDiagnosticBuffer.rows.count,
                  "overflow": canvasDiagnosticBuffer.overflow], includeAssociation: false)
        }
        writer.sync {}
    }
    private func record(_ event: String, time: TimeInterval = ProcessInfo.processInfo.systemUptime,
                        token: String? = nil, fields: [String: Any] = [:], includeAssociation: Bool = true) {
        guard let destination else { return }
        var row = fields
        row["event"] = event; row["uptimeSeconds"] = time
        if includeAssociation { row["operationID"] = token ?? operation ?? "session"; row["inputKind"] = inputKind }
        guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
            } catch { NSLog("Interaction trace write failed: %@", error.localizedDescription) }
        }
    }
}

// Closed layout/admission scalars only; no unconstrained dictionary keys or string payloads.
enum ThumbnailDiagnosticStage: String { case visibility, ownerVisible, retry, refresh, driver, requestGate, requestBuilt, requestRejected, terminal, overflow }
enum ThumbnailDiagnosticReason: String {
    case none, appear, rect, height, context, disappear, accepted, staleScope, notVisible
    case noVisible, noContext, alreadyDriving, retirementOnly, requestRejected, alreadyCurrent, attemptExhausted
    case scheduled, operationAdmissionRejected, gateFailed, adapterEntered, built
    case unsupportedGraph, awaitingSource, staleSource, superseded, closed, cancelled, budgetUnavailable, other
    static func error(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? DevelopmentThumbnailError {
            switch error {
            case .unsupportedGraph: return .unsupportedGraph
            case .awaitingSource: return .awaitingSource
            case .staleSource: return .staleSource
            case .superseded: return .superseded
            case .closed: return .closed
            case .cancelled: return .cancelled
            case .budgetUnavailable: return .budgetUnavailable
            default: return .other
            }
        }
        if let error = error as? DevelopmentPreviewError {
            switch error {
            case .closed: return .closed
            case .superseded: return .superseded
            default: return .other
            }
        }
        return .other
    }
}
enum ThumbnailDiagnosticFlag: String {
    case finite, scopeMatch, computedVisible, requestedVisible, previouslyVisible, childPresent, driving, witnessAvailable, editingPresent
    case interfaceActive, presented, sourceReady, notShuttingDown, developmentStage, notPreviewInteracting, notAnalysisBusy
    case noActiveGesture, notShowingOriginal, notComparing, notCropEditing, contextPresent, factsGenerationMatch, canInspectSource
    case cancelled, generationMatch
}
enum ThumbnailDiagnosticNumber: String { case x, y, width, height, viewportHeight, visibleBefore, visibleAfter, visibleCount, retirementCount }
struct ThumbnailDiagnosticPayload {
    var reason: ThumbnailDiagnosticReason = .none
    var flags: [ThumbnailDiagnosticFlag: Bool] = [:]
    var numbers: [ThumbnailDiagnosticNumber: Double] = [:]
    var failedGate: ThumbnailDiagnosticFlag?
    var state: EditingThumbnailPresentation.State?
}
/// A separate value permits deterministic off/lazy/cap validation without resetting the process trace.
struct ThumbnailDiagnosticLimiter {
    private var count = 0
    private let limit: Int
    init(limit: Int = 128) { self.limit = max(1,min(4096,limit)) }
    mutating func collect(enabled: Bool, stage: ThumbnailDiagnosticStage, kind: DevelopmentThumbnailKind?,
                          _ make: () -> ThumbnailDiagnosticPayload) -> [String: Any]? {
        guard enabled, count < limit else { return nil }
        count += 1
        if count == limit { return ["stage": ThumbnailDiagnosticStage.overflow.rawValue, "count": limit] }
        let payload = make()
        var row: [String: Any] = ["stage": stage.rawValue, "reason": payload.reason.rawValue]
        if let kind {
            switch kind {
            case .summary(.light): row["kind"] = "light"
            case .summary(.color): row["kind"] = "color"
            case .summary(.blackAndWhite): row["kind"] = "blackAndWhite"
            case .filters: row["kind"] = "filters"
            default: break
            }
        }
        for (key, value) in payload.flags { row[key.rawValue] = value }
        for (key, value) in payload.numbers where value.isFinite { row[key.rawValue] = value }
        if let failedGate = payload.failedGate { row["failedGate"] = failedGate.rawValue }
        if let state = payload.state { row["state"] = state.rawValue }
        return row
    }
}

/// Closed stage/case names only. No error description, userInfo, associated payload or image data.
enum AnalysisFailureStage: String {
    case localProjection = "local-projection"
    case admissionRequest = "analysis-admission-request"
    case previewRequest = "analysis-preview-request"
    case awaitService = "analysis-await-service"
    case accept = "analysis-accept"
}
enum AnalysisFailureDiagnostic {
    static func fields(stage: AnalysisFailureStage, error: Error) -> [String: Any] {
        let native = error as NSError
        return ["stage": stage.rawValue, "errorType": String(reflecting: type(of: error)),
                "errorDomain": native.domain, "errorCode": native.code, "errorCase": closedCase(error)]
    }
    private static func closedCase(_ error: Error) -> String {
        if let e = error as? DevelopmentLocalPreparationError {
            switch e {
            case .invalidInput: return "DevelopmentLocalPreparationError.invalidInput"
            case .staleInput: return "DevelopmentLocalPreparationError.staleInput"
            case .invalidResolution: return "DevelopmentLocalPreparationError.invalidResolution"
            case .unresolvedOperation: return "DevelopmentLocalPreparationError.unresolvedOperation"
            case .donorOutOfBounds: return "DevelopmentLocalPreparationError.donorOutOfBounds"
            case .localWorkBudgetExceeded: return "DevelopmentLocalPreparationError.localWorkBudgetExceeded"
            }
        }
        if let e = error as? DevelopmentAdjustmentCommandError {
            switch e {
            case .requiresV3: return "DevelopmentAdjustmentCommandError.requiresV3"
            case .missingSourceContext: return "DevelopmentAdjustmentCommandError.missingSourceContext"
            case .staleAnalysis: return "DevelopmentAdjustmentCommandError.staleAnalysis"
            case .mismatchedSource: return "DevelopmentAdjustmentCommandError.mismatchedSource"
            case .invalidAnalysisResult: return "DevelopmentAdjustmentCommandError.invalidAnalysisResult"
            case .missingOperation: return "DevelopmentAdjustmentCommandError.missingOperation"
            case .unsupportedGrainSampling: return "DevelopmentAdjustmentCommandError.unsupportedGrainSampling"
            }
        }
        if let e = error as? DevelopmentDehazePreparationError {
            switch e {
            case .missingContext: return "DevelopmentDehazePreparationError.missingContext"
            case .staleInput: return "DevelopmentDehazePreparationError.staleInput"
            case .invalidPreparation: return "DevelopmentDehazePreparationError.invalidPreparation"
            case .preparationRequired: return "DevelopmentDehazePreparationError.preparationRequired"
            }
        }
        if let e = error as? DevelopmentV3Error {
            switch e {
            case .unsupportedAdjustment(_): return "DevelopmentV3Error.unsupportedAdjustment"
            case .unsupportedGeometry: return "DevelopmentV3Error.unsupportedGeometry"
            case .unsupportedAnalysis: return "DevelopmentV3Error.unsupportedAnalysis"
            case .unsupportedNativeParameters: return "DevelopmentV3Error.unsupportedNativeParameters"
            case .unrepresentableParameters: return "DevelopmentV3Error.unrepresentableParameters"
            case .invalidGraph: return "DevelopmentV3Error.invalidGraph"
            }
        }
        if let e = error as? DevelopmentPreviewError {
            switch e {
            case .superseded: return "DevelopmentPreviewError.superseded"
            case .closed: return "DevelopmentPreviewError.closed"
            case .sourceInvalidated: return "DevelopmentPreviewError.sourceInvalidated"
            case .capacityExceeded: return "DevelopmentPreviewError.capacityExceeded"
            case .memoryBudgetExceeded: return "DevelopmentPreviewError.memoryBudgetExceeded"
            case .invalidRequest: return "DevelopmentPreviewError.invalidRequest"
            }
        }
        if let e = error as? DevelopmentError {
            switch e {
            case .unreadable: return "DevelopmentError.unreadable"
            case .unsupportedEngine: return "DevelopmentError.unsupportedEngine"
            case .invalidGeometry: return "DevelopmentError.invalidGeometry"
            case .outputExists: return "DevelopmentError.outputExists"
            case .protectedDestination: return "DevelopmentError.protectedDestination"
            case .invalidEncoding: return "DevelopmentError.invalidEncoding"
            }
        }
        if let e = error as? EditingError {
            switch e {
            case .invalidRecipe: return "EditingError.invalidRecipe"
            case .invalidArtifact: return "EditingError.invalidArtifact"
            case .invalidProfile: return "EditingError.invalidProfile"
            case .invalidSource: return "EditingError.invalidSource"
            case .staleSource: return "EditingError.staleSource"
            case .staleAdoption: return "EditingError.staleAdoption"
            case .invalidParent: return "EditingError.invalidParent"
            case .commandConflict: return "EditingError.commandConflict"
            case .staleAttempt: return "EditingError.staleAttempt"
            case .illegalTransition: return "EditingError.illegalTransition"
            case .outcomeUnknown: return "EditingError.outcomeUnknown"
            case .workerNotJoined: return "EditingError.workerNotJoined"
            case .missingWork: return "EditingError.missingWork"
            case .missingVersion: return "EditingError.missingVersion"
            case .missingJob: return "EditingError.missingJob"
            case .archiveNotConfigured: return "EditingError.archiveNotConfigured"
            case .archiveMismatch: return "EditingError.archiveMismatch"
            case .unsafePath: return "EditingError.unsafePath"
            case .incompleteBackup: return "EditingError.incompleteBackup"
            case .outputAlreadyReceived: return "EditingError.outputAlreadyReceived"
            case .strictDocumentary: return "EditingError.strictDocumentary"
            }
        }
        if let e = error as? DevelopmentGeometryMappingError {
            switch e {
            case .invalidExtent: return "DevelopmentGeometryMappingError.invalidExtent"
            case .unsupportedPerspectiveMapping: return "DevelopmentGeometryMappingError.unsupportedPerspectiveMapping"
            case .pointOutsideSource: return "DevelopmentGeometryMappingError.pointOutsideSource"
            }
        }
        if let e = error as? EditingDevelopmentSessionError {
            switch e {
            case .inactive: return "EditingDevelopmentSessionError.inactive"
            case .staleInteraction: return "EditingDevelopmentSessionError.staleInteraction"
            case .unfinishedGesture: return "EditingDevelopmentSessionError.unfinishedGesture"
            case .wrongGesture: return "EditingDevelopmentSessionError.wrongGesture"
            case .recipeDiverged: return "EditingDevelopmentSessionError.recipeDiverged"
            case .commitRejected: return "EditingDevelopmentSessionError.commitRejected"
            case .missingSourceCapability: return "EditingDevelopmentSessionError.missingSourceCapability"
            case .staleAnalysis: return "EditingDevelopmentSessionError.staleAnalysis"
            case .staleFrame: return "EditingDevelopmentSessionError.staleFrame"
            case .epochExhausted: return "EditingDevelopmentSessionError.epochExhausted"
            case .invalidIdentity: return "EditingDevelopmentSessionError.invalidIdentity"
            }
        }
        if error is DevelopmentAnalysisError { return "DevelopmentAnalysisError.noVisibleSamples" }
        if error is CancellationError { return "CancellationError" }
        return "unclassified"
    }
}

struct PreviewCacheShutdownSummaryGate {
  private enum State:Equatable {case fresh,claimed,emitted}
  private var state:State = .fresh
  mutating func claim(traceEnabled:Bool)->Bool {
    guard traceEnabled,state == .fresh else{return false}
    state = .claimed;return true
  }
  mutating func emit(traceEnabled:Bool)->Bool {
    guard traceEnabled,state == .claimed else{return false}
    state = .emitted;return true
  }
}

/// Records an AppKit view update after SwiftUI has consumed the focused selection.
/// This does not claim that WindowServer has presented a frame.
struct SelectionUpdateProbe: NSViewRepresentable {
    let assetID: String?
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) { InteractionTrace.shared.selectionViewUpdated(assetID: assetID) }
}

/// Fixed observed scalars only; no fallback reason, associated error or source payload is exported.
/// Called only after the existing opt-in/single-emission shutdown gate succeeds.
enum PreviewCacheShutdownSummaryDiagnostic {
  static func fields(_ s: PreviewStatistics) -> [String: Any] {
    [
    "boundary": "after-editing.shutdown-and-shared.closeAll-actual-joins",
    // Slot jobs are dispatch counts, not source decodes. Validated outputs are not draw returns.
    "nativeProfileInteractiveJobs": s.nativeProfileInteractiveJobs,
    "nativeProfileCanonicalJobs": s.nativeProfileCanonicalJobs,
    "nativeProfileCanonicalValidatedOutputs": s.nativeProfileCanonicalValidatedOutputs,
    "nativeProfileCanonicalProvenGlobalOutputs": s.nativeProfileCanonicalProvenGlobalOutputs,
    "nativeProfileCanonicalProvenBitmapHits": s.nativeProfileCanonicalProvenBitmapHits,
    "nativeProfileSemanticBitmapHits": s.nativeProfileSemanticBitmapHits,
    "nativeProfilePreservedInputs": s.nativeProfilePreservedInputs,
    "nativeProfileCancelledFrames": s.nativeProfileCancelledFrames,
    "nativeProfileLastRoute": s.nativeProfileLastRoute,
    "nativeProfileLastSlotWaitNanoseconds": s.nativeProfileLastSlotWaitNanoseconds,
    "rawBaseFills": s.rawBaseFills,
    "rawBaseHits": s.rawBaseHits,
    "rawBaseMisses": s.rawBaseMisses,
    "rawBaseEvictions": s.rawBaseEvictions,
    "rawBaseResidentBytes": s.rawBaseResidentBytes,
    "rawBaseReservedBytes": s.rawBaseReservedBytes,
    "rawBaseBuildingBytes": s.rawBaseBuildingBytes,
    "rawBaseRetiredBytes": s.rawBaseRetiredBytes,
    "rawBasePinnedBytes": s.rawBasePinnedBytes,
    "sourceCaptures": s.sourceCaptures,
    "sourceFullHashPasses": s.sourceFullHashPasses,
    "sourceHashBytes": s.sourceHashBytes,
    "sourceStatChecks": s.sourceStatChecks,
    "sourceSnapshotDiskBytes": s.sourceSnapshotDiskBytes,
    "bitmapCacheHits": s.cacheHits,
    "cachedBitmapBytes": s.cachedBitmapBytes,
    "completedRenders": s.completedRenders,
    "supersededRequests": s.supersededRequests,
    "activeNativeRenders": s.activeNativeRenders,
    "pendingRequests": s.pendingRequests,
    "maximumObservedNativeRenders": s.maximumObservedNativeRenders,
    "maximumObservedPendingRequests": s.maximumObservedPendingRequests
  ]
  }
}

enum CanvasAcknowledgementReason: String {
    case accepted, inactiveSource, replacedFrame, changedEpoch, alreadyAcknowledged, scopeFence
}

struct CanvasDiagnosticBuffer {
    struct Row {
        let event: String
        let sequence: Int
        let at: UInt64
        let canvas: UUID?
        let frame: UUID?
        let began: UInt64?
        let current: UUID?
        let reason: CanvasAcknowledgementReason?

        var fields: [String: Any] {
            var value: [String: Any] = ["sequence": sequence, "atNS": at]
            if let canvas { value["canvasID"] = canvas.uuidString }
            if let frame { value["frameID"] = frame.uuidString }
            if let began { value["drawBeganNS"] = began }
            if let current { value["currentFrameID"] = current.uuidString }
            if let reason { value["reason"] = reason.rawValue }
            return value
        }
    }

    let limit: Int
    private(set) var rows: [Row] = []
    private(set) var overflow = false
    var sealed = false

    mutating func append(_ event: String, at: UInt64, canvas: UUID? = nil, frame: UUID? = nil,
                         began: UInt64? = nil, current: UUID? = nil, reason: CanvasAcknowledgementReason? = nil) {
        guard !sealed else { return }
        guard rows.count < limit else { overflow = true; return }
        rows.append(.init(event: event, sequence: rows.count + 1, at: at, canvas: canvas, frame: frame,
                          began: began, current: current, reason: reason))
    }
}
