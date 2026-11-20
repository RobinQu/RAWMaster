import AppKit
import XCTest
@testable import RAWMaster
import RAWMasterCore
@testable import RAWMasterImaging

final class EditingProgressPresentationTests: XCTestCase {
    @MainActor private func wait(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 { if await predicate() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTFail("Progress presentation timed out", file: file, line: line)
    }
    @MainActor private func currentBox(_ backend: ProgressPresentationBackend) async throws -> ProgressPresentationBox {
        let value = await backend.latestBox
        return try XCTUnwrap(value)
    }
    private let focus = UUID()
    private func intent(_ exposure: Double = 0, quality: PreviewQuality = .interactive, crop: NormalizedCrop = .init(), sourceID: String = "A", progress: Bool = true) throws -> EditingPreviewIntent {
        let source = EditingSourceSnapshot(projectID: "project", assetID: sourceID, contentSHA256: String(repeating: "a", count: 64),
            byteCount: 100, admissionFingerprint: "admission", sourceLocation: URL(fileURLWithPath: "/fixture/\(sourceID).ARW"))
        var recipe = DevelopmentRecipe(); recipe.exposureEV = exposure; recipe.crop = crop
        let context: EditingDraftPresentation? = progress ? .init(focusID: focus, workID: sourceID, draftParentID: "original", selectedVersionID: "original", cropOverlay: false, comparing: false) : nil
        return try .init(source: .raw(source), recipe: recipe, quality: quality, draftPresentation: context,
            presentationID: progress ? "editable-draft" : "fixed-version")
    }
    @MainActor func testThreeHundredInputsPublishMultipleActualProgressFramesThenExactSettledWithoutPerInputTasks() async throws {
        let backend = ProgressPresentationBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        var events: [EditingPreviewDiagnosticEvent] = []; active.diagnosticSink = { events.append($0) }
        active.submit(try intent(), input: .capture(control: "fixture-EV", phase: "begin"))
        try await wait { await backend.latestBox?.hasWorker == true }
        let box = try await currentBox(backend)
        for index in 1...300 {
            let input = EditingPreviewInput.classified(control: "fixture-EV", phase: "change", committedAt: UInt64(index) * 50_000_000, eventAt: nil, nativeEvent: false)
            active.submit(try intent(Double(index) / 100), input: input)
            if index % 5 == 0 {
                let completedRevision = try XCTUnwrap(box.activeRevision)
                box.finishActive()
                try await wait { active.displayedRevision == completedRevision }
                let frame = try XCTUnwrap(active.frame)
                XCTAssertTrue(active.rendering, "An older completed frame cannot clear the latest target's busy state")
                XCTAssertTrue(active.didDraw(.init(frameID: frame.id, drawBeganUptimeNanoseconds: 1, drawReturnedUptimeNanoseconds: 2,
                    imagePixelWidth: Int(frame.outputSize.width), imagePixelHeight: Int(frame.outputSize.height))))
                XCTAssertLessThanOrEqual(active.ownedOperationCount, 2, "Only the reader and lifecycle resource child may be active")
            }
        }
        XCTAssertGreaterThan(events.filter { $0.outcome == "progress" }.count, 10, "The test must prove intermediate feedback, not only final output")
        XCTAssertGreaterThan(events.filter { $0.outcome == "drawn" }.count, 10)
        active.submit(try intent(3, quality: .settled), input: .capture(control: "fixture-EV", phase: "end"))
        while box.hasWorker { box.finishActive(); await Task.yield() }
        try await wait { active.frame?.revision == active.currentRevision && active.frame?.quality == .settled && !active.rendering }
        XCTAssertEqual(active.frameRecipe?.exposureEV, 3)
        XCTAssertGreaterThanOrEqual(box.activityCount, 300)
        XCTAssertLessThanOrEqual(box.maximumPending, 1); XCTAssertEqual(box.maximumWorkers, 1)
        await active.shutdown()
    }
    @MainActor func testPendingHigherRevisionTerminalCannotSuppressOlderActivePublicationAndDrawAttribution() async throws {
        let backend = ProgressPresentationBackend()
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        var events: [EditingPreviewDiagnosticEvent] = []; pane.diagnosticSink = { events.append($0) }
        let first = EditingPreviewInput.capture(control: "first", phase: "change")
        pane.submit(try intent(), input: first); try await wait { await backend.latestBox?.hasWorker == true }
        let box = try await currentBox(backend)
        pane.submit(try intent(1), input: .capture(control: "replaced-pending", phase: "change"))
        pane.submit(try intent(2), input: .capture(control: "latest", phase: "change"))
        try await wait { events.contains { $0.outcome == "superseded" } }
        box.finishActive(); try await wait { pane.frame != nil }
        XCTAssertEqual(pane.frameRecipe?.exposureEV, 0); XCTAssertTrue(pane.rendering)
        XCTAssertTrue(events.contains { $0.operationID == first.id && $0.outcome == "progress" })
        let frame = try XCTUnwrap(pane.frame)
        XCTAssertTrue(pane.didDraw(.init(frameID: frame.id, drawBeganUptimeNanoseconds: 1, drawReturnedUptimeNanoseconds: 2, imagePixelWidth: 120, imagePixelHeight: 80)))
        XCTAssertTrue(events.contains { $0.operationID == first.id && $0.outcome == "drawn" })
        let shutdown = Task { await pane.shutdown() }; await Task.yield(); box.finishActive(); await shutdown.value
    }
    @MainActor func testCacheAheadFinalAndMetadataUpdatesCannotRegressToOldActiveFrame() async throws {
        let backend = ProgressPresentationBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        active.submit(try intent(), input: .capture(control: "old", phase: "change"))
        try await wait { await backend.latestBox?.hasWorker == true }
        let box = try await currentBox(backend)
        box.cacheNextSubmission()
        active.submit(try intent(1, quality: .settled), input: .capture(control: "final", phase: "end"))
        try await wait { active.frame?.quality == .settled && !active.rendering }
        let finalID = active.frame?.id, finalRevision = active.displayedRevision
        box.finishActive(); box.metadataOnly()
        await Task.yield(); try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(active.frame?.id, finalID); XCTAssertEqual(active.displayedRevision, finalRevision); XCTAssertFalse(active.rendering)
        await active.shutdown()
    }
    @MainActor func testStickyLatestFailureSurvivesOldProgressAndTerminalOverflow() async throws {
        let backend = ProgressPresentationBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        active.submit(try intent(), input: .capture(control: "old", phase: "change"))
        try await wait { await backend.latestBox?.hasWorker == true }
        let box = try await currentBox(backend)
        active.submit(try intent(1), input: .capture(control: "failed", phase: "change")); box.failLatest()
        try await wait { active.error != nil && !active.rendering }
        let message = active.error
        box.finishActive(); box.floodTerminals(80)
        try await wait { active.frame != nil }
        XCTAssertEqual(active.error, message); XCTAssertFalse(active.rendering)
        XCTAssertGreaterThan(box.overflowCount, 0)
        await active.shutdown()
    }
    @MainActor func testGeometryABACreatesNewRegistrationAndOldACannotPublish() async throws {
        let backend = ProgressPresentationBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        active.submit(try intent(), input: .capture(control: "A", phase: "change"))
        try await wait { await backend.latestBox?.hasWorker == true }
        let first = try await currentBox(backend)
        active.submit(try intent(1, crop: .init(width: 0.9)), input: .capture(control: "B", phase: "change"))
        active.submit(try intent(2), input: .capture(control: "A-again", phase: "change"))
        try await wait { first.closing }
        first.finishActive()
        try await wait { await backend.channelCount == 2 }
        let last = try await currentBox(backend)
        XCTAssertNotEqual(first.id, last.id); XCTAssertNil(active.frame)
        try await wait { last.hasWorker }; last.finishActive()
        try await wait { active.frameRecipe?.exposureEV == 2 }
        await active.shutdown()
    }
    @MainActor func testDetailTransitionJoinsChannelBeforeStrictNativeRequest() async throws {
        let backend = ProgressPresentationBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        active.submit(try intent(), input: .capture(control: "draft", phase: "change"))
        try await wait { await backend.latestBox?.hasWorker == true }
        let box = try await currentBox(backend)
        active.submit(try intent(quality: .detail, progress: false), input: .capture(control: "detail", phase: "discrete"))
        try await wait { box.closing }
        let before = await backend.strictRequests; XCTAssertTrue(before.isEmpty)
        box.finishActive()
        try await wait { active.frame?.quality == .detail }
        let strict = await backend.strictRequests
        XCTAssertEqual(strict.count, 1); XCTAssertEqual(strict.first?.viewport.maxPixel, 0); XCTAssertEqual(strict.first?.deliveryPolicy, .latestOnly)
        await active.shutdown()
    }
    @MainActor func testLateFactoryResourceIsOwnedAndJoinedOnShutdown() async throws {
        let backend = ProgressPresentationBackend(holdFactory: true)
        let active = EditingPreviewPane(role: .primary, backend: backend)
        active.submit(try intent(), input: .capture(control: "fixture", phase: "change"))
        try await wait { await backend.channelCount == 1 }
        var returned = false
        let shutdown = Task { await active.shutdown(); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        await backend.releaseFactory(); await shutdown.value
        let closed = await backend.closedChannels.count, leases = await backend.closedLeases.count
        XCTAssertEqual(closed, 1); XCTAssertEqual(leases, 1); XCTAssertNil(active.frame)
    }
    func testCorrelationIsBoundedOptionalAndDoesNotRelabelMissingDataAsNativeOrCurrent() throws {
        let input = EditingPreviewInput.classified(control: "test", phase: "change", committedAt: 1_000, eventAt: 500, nativeEvent: true)
        let encoded = try XCTUnwrap(input.correlationData())
        XCTAssertLessThanOrEqual(encoded.count, 4096)
        XCTAssertEqual(EditingPreviewInput.decodeCorrelation(encoded, token: UUID()).id, input.id)
        XCTAssertEqual(EditingPreviewInput.decodeCorrelation(nil, token: UUID()).origin, .unattributed)
        XCTAssertEqual(EditingPreviewInput.decodeCorrelation(Data(repeating: 1, count: 4097), token: UUID()).association, .malformedCorrelation)
        var ledger = EditingProgressTerminalLedger(capacity: 4)
        let older = UUID(), newer = UUID(); ledger.register(older, newer, newer)
        XCTAssertTrue(ledger.accept(newer)); XCTAssertTrue(ledger.accept(older)); XCTAssertFalse(ledger.accept(older))
        for _ in 0..<100 { _ = ledger.accept(UUID()) }
        XCTAssertFalse(ledger.accept(newer), "Sticky current-target terminal is not duplicated after the recent ring overflows")
        ledger.register(nil, nil, nil)
        XCTAssertLessThanOrEqual(ledger.retainedCount, 4)
    }
}

/// Bounded mailbox/worker fixture. Image ownership is latestCompleted1; histories contain requests/IDs only.
final class ProgressPresentationBox: @unchecked Sendable {
    let id = PreviewProgressChannelID(rawValue: UUID())
    let lease: EditingPreviewLease
    let consumer: PreviewConsumerID
    let stream: AsyncStream<PreviewDeliverySnapshot>
    private let continuation: AsyncStream<PreviewDeliverySnapshot>.Continuation
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var terminalSequence: UInt64 = 0
    private var state: PreviewProgressChannelState = .open
    private var worker: PreviewSubmittedWork?
    private var pending: PreviewSubmittedWork?
    private var target: PreviewSubmittedWork?
    private var targetTerminal: PreviewSubmissionTerminal?
    private var completed: PreviewCompletedWork?
    private var terminals: [PreviewSubmissionTerminal] = []
    private var overflow: UInt64 = 0
    private var cacheNext = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var activity = 0
    private var observedPending = 0
    init(lease: EditingPreviewLease, consumer: PreviewConsumerID) {
        self.lease = lease; self.consumer = consumer
        let pair = AsyncStream<PreviewDeliverySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1)); stream = pair.stream; continuation = pair.continuation
    }
    var hasWorker: Bool { lock.lock(); defer { lock.unlock() }; return worker != nil }
    var activeRevision: UInt64? { lock.lock(); defer { lock.unlock() }; return worker?.request.revision }
    var closing: Bool { lock.lock(); defer { lock.unlock() }; return state == .closing }
    var overflowCount: UInt64 { lock.lock(); defer { lock.unlock() }; return overflow }
    var activityCount: Int { lock.lock(); defer { lock.unlock() }; return activity }
    var maximumPending: Int { lock.lock(); defer { lock.unlock() }; return observedPending }
    var maximumWorkers: Int { 1 }
    func channel() -> EditingProgressChannel { .init(id: id, snapshots: stream, submit: { try self.submit($0) }, noteActivity: { self.note() }) }
    private func note() { lock.lock(); defer { lock.unlock() }; if state == .open { activity += 1 } }
    private func submit(_ request: DevelopmentPreviewRequest) throws -> PreviewEnqueueReceipt {
        lock.lock(); defer { lock.unlock() }
        guard state == .open else { throw DevelopmentPreviewError.closed }
        let work = PreviewSubmittedWork(id: .init(rawValue: UUID()), request: request)
        target = work; targetTerminal = nil
        if request.quality == .interactive { activity += 1 }
        if cacheNext {
            cacheNext = false; completeLocked(work)
        } else if worker == nil { worker = work }
        else { if let pending { terminalLocked(pending, outcome: .superseded) }; pending = work; observedPending = 1 }
        emitLocked(); return .init(disposition: .buffered, work: work, replacedBeforeAdmission: nil)
    }
    func cacheNextSubmission() { lock.lock(); cacheNext = true; lock.unlock() }
    func metadataOnly() { lock.lock(); emitLocked(); lock.unlock() }
    func failLatest() {
        lock.lock(); defer { lock.unlock() }
        guard let target else { return }; if pending?.id == target.id { pending = nil }
        terminalLocked(target, outcome: .failed, failure: .invalidRequest, message: "fixture latest failed"); emitLocked()
    }
    func floodTerminals(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let target else { return }
        for _ in 0..<count { terminalLocked(.init(id: .init(rawValue: UUID()), request: target.request), outcome: .superseded) }
        emitLocked()
    }
    func finishActive() {
        lock.lock(); defer { lock.unlock() }
        guard let old = worker else { return }; worker = nil
        if state == .open {
            completeLocked(old); worker = pending; pending = nil; emitLocked()
        } else { finishCloseLocked() }
    }
    private func completeLocked(_ work: PreviewSubmittedWork) {
        let request = work.request, size = CGSize(width: 120, height: 80)
        let frame = DevelopmentPreviewFrame(frameID: UUID(), image: NSImage(size: size), sessionID: request.sessionID,
            sourceGeneration: request.sourceGeneration, consumerID: request.consumerID, revision: request.revision, quality: request.quality,
            canonicalPixelSize: .init(width: 3000, height: 2000), outputPixelSize: size, outputKey: "fixture-\(request.revision)", approximate: false)
        if completed == nil || request.revision > completed!.work.request.revision { completed = .init(work: work, frame: frame) }
        terminalLocked(work, outcome: .completed, frameID: frame.frameID)
    }
    private func terminalLocked(_ work: PreviewSubmittedWork, outcome: PreviewSubmissionOutcome, failure: DevelopmentPreviewError? = nil,
                                message: String? = nil, frameID: UUID? = nil) {
        terminalSequence += 1
        let entry = PreviewSubmissionTerminal(sequence: terminalSequence, work: work, outcome: outcome, failure: failure, message: message, frameID: frameID)
        terminals.append(entry); if terminals.count > 64 { terminals.removeFirst(); overflow += 1 }
        if target?.id == work.id { targetTerminal = entry }
    }
    private func emitLocked() {
        sequence += 1
        continuation.yield(.init(sequence: sequence, channelID: id, sessionID: lease.id, sourceGeneration: lease.generation,
            consumerID: consumer, state: state, active: worker, pending: pending, latestCompleted: completed,
            latestTarget: target, latestTargetTerminal: targetTerminal, terminals: terminals, terminalOverflowCount: overflow))
    }
    func close() async {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard state != .closed else { continuation.resume(); return }
            state = .closing; pending = nil; target = nil; targetTerminal = nil; completed = nil
            closeWaiters.append(continuation); emitLocked()
            if worker == nil { finishCloseLocked() }
        }
    }
    private func finishCloseLocked() {
        state = .closed; pending = nil; completed = nil; target = nil; targetTerminal = nil; emitLocked(); continuation.finish()
        let waiters = closeWaiters; closeWaiters = []; waiters.forEach { $0.resume() }
    }
}

actor ProgressPresentationBackend: EditingPreviewBackend {
    private var boxes: [ProgressPresentationBox] = []
    private var factoryWaiter: CheckedContinuation<Void, Never>?
    private var holdFactory: Bool
    private(set) var closedChannels: [PreviewProgressChannelID] = []
    private(set) var closedLeases: [DevelopmentPreviewSessionID] = []
    private(set) var strictRequests: [DevelopmentPreviewRequest] = []
    var latestBox: ProgressPresentationBox? { boxes.last }
    var channelCount: Int { boxes.count }
    init(holdFactory: Bool = false) { self.holdFactory = holdFactory }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { .init(id: .init(), generation: 1) }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap {
        strictRequests.append(request)
        let size = request.quality == .detail ? CGSize(width: 3000, height: 2000) : CGSize(width: 120, height: 80)
        return .init(id: UUID(), image: NSImage(size: size), leaseID: request.sessionID, generation: request.sourceGeneration,
            consumerID: request.consumerID, revision: request.revision, quality: request.quality,
            nativeSize: .init(width: 3000, height: 2000), outputSize: size, approximate: false)
    }
    func cancel(_ consumer: PreviewConsumerID) async {}
    func cancelAndJoin(_ consumer: PreviewConsumerID) async {}
    func close(_ lease: DevelopmentPreviewSessionID) async { closedLeases.append(lease) }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { .init(id: lease, generation: 2) }
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel {
        let box = ProgressPresentationBox(lease: lease, consumer: consumer); boxes.append(box)
        if holdFactory { await withCheckedContinuation { factoryWaiter = $0 } }
        return box.channel()
    }
    func releaseFactory() { holdFactory = false; factoryWaiter?.resume(); factoryWaiter = nil }
    func closeProgressChannel(_ id: PreviewProgressChannelID) async {
        if let box = boxes.first(where: { $0.id == id }) { await box.close(); if !closedChannels.contains(id) { closedChannels.append(id) } }
    }
}

extension EditingProgressPresentationTests {
    @MainActor func testV2ToneCurveAndGradingChangesReuseOneProgressRegistrationAndFinalFullRecipe() async throws {
        let backend = ProgressPresentationBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        let base = try intent()
        var recipe = try base.recipe.promotingToV2()
        func request(_ quality: PreviewQuality = .interactive) throws -> EditingPreviewIntent {
            try .init(source: base.source, recipe: recipe, quality: quality, draftPresentation: base.draftPresentation, presentationID: base.presentationID)
        }
        active.submit(try request(), input: .capture(control: "fixture-v2", phase: "change")); try await wait { await backend.latestBox?.hasWorker == true }
        let box = try await currentBox(backend)
        recipe.color?.tones.contrast = 30
        active.submit(try request(), input: .capture(control: "tone.contrast", phase: "change"))
        recipe.color?.curves.red = .init(points: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.6), .init(x: 1, y: 1)])
        active.submit(try request(), input: .capture(control: "curve.R", phase: "change"))
        box.finishActive(); try await wait { active.frame != nil }
        XCTAssertTrue(active.rendering); XCTAssertLessThan(active.displayedRevision, active.currentRevision)
        recipe.color?.grading.shadows = .init(hueDegrees: 210, saturation: 25, luminance: 5)
        active.submit(try request(.settled), input: .capture(control: "grading.shadows.wheel", phase: "settled"))
        while box.hasWorker { box.finishActive(); await Task.yield() }
        try await wait { active.frameRecipe == recipe && active.frame?.quality == .settled && !active.rendering }
        let channels = await backend.channelCount
        XCTAssertEqual(channels, 1, "New color values do not create a hard geometry/engine epoch")
        await active.shutdown(); XCTAssertEqual(active.ownedOperationCount, 0)
    }
}
