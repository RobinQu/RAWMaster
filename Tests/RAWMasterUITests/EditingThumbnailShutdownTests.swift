import AppKit
import Metal
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMaster

/// Exercises the existing App owner with real Service-managed image providers.
/// No window, NSHostingView, fabricated RAW facts, or replacement image owner.
final class EditingThumbnailShutdownTests: XCTestCase {
    private enum Failure: Error { case timedOut(String) }
    private let kind = DevelopmentThumbnailKind.summary(.blackAndWhite)

    @MainActor private func wait(_ label: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out: " + label)
        throw Failure.timedOut(label)
    }
    @MainActor private func prepare(_ editing: EditingController, asset: AssetRecord) async throws -> EditingInteractionContext {
        editing.isPresented = true; editing.focus(asset)
        try await wait("real source and primary frame") { editing.work != nil && editing.previews.primary.frame != nil }
        editing.beginDevelopmentInterface()
        try await wait("current context, canonical frame, and histogram") {
            editing.developmentContext != nil && editing.developmentHistogram != nil
                && editing.previews.primary.frameRecipe == editing.recipe
                && editing.previews.primary.frame?.revision == editing.previews.primary.currentRevision
                && !editing.previews.primary.rendering
        }
        XCTAssertEqual(editing.developmentSourceFacts?.sourceKind, .image, "The actual fixture is PNG, never fake RAW")
        return try XCTUnwrap(editing.developmentContext)
    }
    @MainActor private func ready(_ editing: EditingController, context: EditingInteractionContext) async throws {
        editing.developmentThumbnails.setVisible(kind, true, context: context)
        try await wait("five actual managed images, driver finished") {
            editing.developmentThumbnails.state(self.kind) == .ready
                && editing.developmentThumbnails.sets[self.kind.presentationKey]?.images.count == 5
                && !editing.developmentThumbnails.driving
        }
    }
    @MainActor private func assertNoServiceWork(_ service: DevelopmentPreviewService, file: StaticString = #filePath, line: UInt = #line) async {
        let s = await service.statistics(), t = await service.thumbnailStatistics()
        XCTAssertEqual(s.activeNativeRenders, 0, file: file, line: line)
        XCTAssertEqual(s.pendingRequests, 0, file: file, line: line)
        XCTAssertEqual(s.sourceSnapshotDiskBytes, 0, file: file, line: line)
        XCTAssertEqual(t.pending, 0, file: file, line: line); XCTAssertEqual(t.active, 0, file: file, line: line)
        XCTAssertEqual(t.readySets, 0, file: file, line: line); XCTAssertEqual(t.displaySets, 0, file: file, line: line)
        XCTAssertEqual(t.reservedBytes, 0, file: file, line: line); XCTAssertEqual(t.inFlightBytes, 0, file: file, line: line)
        XCTAssertEqual(t.gpuBytes, 0, file: file, line: line)
    }
    @MainActor private func assertZero(_ service: DevelopmentPreviewService, file: StaticString = #filePath, line: UInt = #line) async {
        await assertNoServiceWork(service, file: file, line: line)
        let t = await service.thumbnailStatistics()
        XCTAssertEqual(t.cpuBytes, 0, file: file, line: line); XCTAssertEqual(t.unionBytes, 0, file: file, line: line)
        XCTAssertEqual(t.retiredBytes, 0, file: file, line: line)
        XCTAssertEqual(t.managedBackingBytes, 0, file: file, line: line)
        XCTAssertEqual(t.managedBackingCount, 0, file: file, line: line)
        XCTAssertEqual(t.retiredManagedBackingBytes, 0, file: file, line: line)
    }
    @MainActor private func rejectReentry(_ editing: EditingController, context: EditingInteractionContext) {
        let owner = editing.developmentThumbnails
        owner.setVisible(kind, true, context: context); owner.retry(kind, context: context); owner.refresh()
        editing.beginDevelopmentInterface()
        XCTAssertTrue(owner.sets.isEmpty); XCTAssertNil(editing.developmentContext)
    }

    @MainActor func testReadyOwnerShutdownReleasesActualFiveImagesBeforeServiceCloseAll() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0))
        let backend = ThumbnailShutdownBackend(service: service)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        do {
            let context = try await prepare(editing, asset: fixture.assets[0]), before = editing.recipe
            try await ready(editing, context: context)
            weak var displayed: NSImage?
            autoreleasepool {
                displayed = editing.developmentThumbnails.sets[kind.presentationKey]?.images.first
                XCTAssertNotNil(displayed)
            }
            let held = await service.thumbnailStatistics()
            XCTAssertEqual(held.displaySets, 1); XCTAssertEqual(held.managedBackingCount, 5)
            XCTAssertGreaterThan(held.managedBackingBytes, 0)
            await editing.shutdown(); autoreleasepool {}
            XCTAssertTrue(editing.developmentThumbnails.sets.isEmpty); XCTAssertFalse(editing.developmentThumbnails.driving)
            XCTAssertNil(displayed, "The App owner must release its NSImage wrappers without an external alias")
            await assertZero(service) // Crucially before this test's independent Service.closeAll.
            rejectReentry(editing, context: context)
            await editing.shutdown() // Existing repeated shutdown must not close the source twice.
            let counts = await backend.counts
            XCTAssertEqual(counts.requests, 1); XCTAssertEqual(counts.adoptions, 1)
            XCTAssertEqual(counts.presentationReleases, 1); XCTAssertEqual(counts.closes, 1)
            XCTAssertEqual(editing.recipe, before)
        } catch { await editing.shutdown(); await service.closeAll(); throw error }
        await service.closeAll(); await assertZero(service)
    }

    @MainActor func testEscapedNSImageStaysChargedAfterOwnerShutdownUntilActualLastRelease() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0))
        let backend = ThumbnailShutdownBackend(service: service)
        let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
        var escaped: NSImage?
        do {
            let context = try await prepare(editing, asset: fixture.assets[0]); try await ready(editing, context: context)
            let heldBytes = try autoreleasepool { () throws -> Int in
                let set = try XCTUnwrap(editing.developmentThumbnails.sets[kind.presentationKey])
                escaped = try XCTUnwrap(set.images.first)
                return try XCTUnwrap(set.lease.tiles.first).allocation.unionBytes
            }
            await editing.shutdown(); autoreleasepool {}
            XCTAssertTrue(editing.developmentThumbnails.sets.isEmpty); XCTAssertFalse(editing.developmentThumbnails.driving)
            await assertNoServiceWork(service)
            let retired = await service.thumbnailStatistics()
            XCTAssertEqual(retired.managedBackingCount, 1)
            XCTAssertEqual(retired.managedBackingBytes, heldBytes); XCTAssertEqual(retired.retiredManagedBackingBytes, heldBytes)
            XCTAssertEqual(retired.unionBytes, heldBytes); XCTAssertEqual(retired.cpuBytes, heldBytes)
            try autoreleasepool {
                let image = try XCTUnwrap(escaped), cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertGreaterThan(cg.width, 0); XCTAssertGreaterThan(cg.height, 0)
                let data = try XCTUnwrap(cg.dataProvider?.data)
                XCTAssertGreaterThan(CFDataGetLength(data), 0, "Escaped image retains real readable provider storage after owner close")
            }
            rejectReentry(editing, context: context)
            escaped = nil; autoreleasepool {}
            await assertZero(service)
            let counts = await backend.counts
            XCTAssertEqual(counts.requests, 1); XCTAssertEqual(counts.adoptions, 1); XCTAssertEqual(counts.presentationReleases, 1)
        } catch { escaped = nil; await editing.shutdown(); await service.closeAll(); throw error }
        await service.closeAll(); await assertZero(service)
    }

    @MainActor func testInflightShutdownJoinsRealWorkerAndRejectsLateActualReadyLease() async throws {
        _ = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for phase in ["native", "readyDelivery"] {
            let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
            let entered = expectation(description: phase + " actual seam entered")
            let cancelled = expectation(description: phase + " actual cancellation/join entered")
            let native = ThumbnailShutdownNativeGate(entered: entered)
            let delivery = ThumbnailShutdownDeliveryGate(entered: entered, cancelled: cancelled)
            let nativeHook: (@Sendable () throws -> Void)?
            let cancellationHook: (@Sendable () -> Void)?
            if phase == "native" {
                nativeHook = { native.blockFirstActualStep() }
                cancellationHook = { cancelled.fulfill() }
            } else {
                nativeHook = nil
                cancellationHook = nil
            }
            let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0),
                thumbnailStepWillBeginForTesting: nativeHook)
            let backend = ThumbnailShutdownBackend(service: service, deliveryGate: phase == "readyDelivery" ? delivery : nil,
                cancellationObserved: cancellationHook)
            let editing = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults, previewBackend: backend)
            var shutdown: Task<Void, Never>?
            do {
                let context = try await prepare(editing, asset: fixture.assets[0]), before = editing.recipe
                editing.developmentThumbnails.setVisible(kind, true, context: context)
                await fulfillment(of: [entered], timeout: 5)
                if phase == "native" { XCTAssertTrue(native.didEnter) }
                else {
                    let ready = await service.thumbnailStatistics()
                    XCTAssertEqual(ready.readySets, 1); XCTAssertEqual(ready.managedBackingCount, 5)
                }
                var returned = false
                shutdown = Task { await editing.shutdown(); returned = true }
                await fulfillment(of: [cancelled], timeout: 5)
                XCTAssertFalse(returned, "A cancellation notification cannot replace the real child join")
                rejectReentry(editing, context: context)
                let held = await backend.counts
                XCTAssertEqual(held.requests, 1); XCTAssertEqual(held.adoptAttempts, 0)
                if phase == "native" {
                    let stats = await service.statistics(); XCTAssertEqual(stats.activeNativeRenders, 1)
                    XCTAssertEqual(held.joins, 0, "Real native step is still held")
                }
                native.release(); await delivery.release(); await shutdown?.value
                XCTAssertTrue(returned); XCTAssertFalse(editing.developmentThumbnails.driving)
                XCTAssertTrue(editing.developmentThumbnails.sets.isEmpty); XCTAssertEqual(editing.recipe, before)
                let finished = await backend.counts
                XCTAssertEqual(finished.requests, 1); XCTAssertEqual(finished.adoptAttempts, 0); XCTAssertEqual(finished.adoptions, 0)
                XCTAssertEqual(finished.joins, 1); XCTAssertEqual(finished.closes, 1)
                XCTAssertEqual(finished.readyReleases, phase == "readyDelivery" ? 1 : 0)
                await assertZero(service)
            } catch {
                native.release(); await delivery.release(); await shutdown?.value
                await editing.shutdown(); await service.closeAll(); throw error
            }
            native.release(); await delivery.release(); await service.closeAll(); await assertZero(service)
        }
    }
}

/// Holds the existing native-step hook once; cancellation cannot signal the producer as joined.
private final class ThumbnailShutdownNativeGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private let entered: XCTestExpectation
    private var first = true, observed = false
    init(entered: XCTestExpectation) { self.entered = entered }
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return observed }
    func blockFirstActualStep() {
        lock.lock(); let block = first; first = false; if block { observed = true }; lock.unlock()
        if block { entered.fulfill(); semaphore.wait() }
    }
    func release() { semaphore.signal() }
}
/// Holds only delivery of an already real, completed Service-managed ready lease.
private actor ThumbnailShutdownDeliveryGate {
    private let entered: XCTestExpectation
    nonisolated let noteCancellation: @Sendable () -> Void
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation, cancelled: XCTestExpectation) { self.entered = entered; self.noteCancellation = { cancelled.fulfill() } }
    func hold() async { entered.fulfill(); if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
/// Observes real product adapter boundaries. All resources and operations belong to actual Service.
private actor ThumbnailShutdownBackend: EditingPreviewBackend {
    struct Counts: Sendable { var requests = 0, adoptAttempts = 0, adoptions = 0, readyReleases = 0, presentationReleases = 0, joins = 0, closes = 0 }
    private let shared: SharedEditingPreviewBackend
    private let deliveryGate: ThumbnailShutdownDeliveryGate?
    private let cancellationObserved: (@Sendable () -> Void)?
    private(set) var counts = Counts()
    init(service: DevelopmentPreviewService, deliveryGate: ThumbnailShutdownDeliveryGate? = nil, cancellationObserved: (@Sendable () -> Void)? = nil) {
        shared = .init(service: service); self.deliveryGate = deliveryGate; self.cancellationObserved = cancellationObserved
    }
    func thumbnails(_ request: DevelopmentThumbnailRequest, progress: @escaping @Sendable (DevelopmentThumbnailProgress) -> Void) async throws -> DevelopmentThumbnailReadyLease {
        counts.requests += 1
        let observeCancellation = cancellationObserved
        let ready = try await withTaskCancellationHandler(operation: {
            try await shared.thumbnails(request, progress: progress)
        }, onCancel: { observeCancellation?() })
        if let deliveryGate {
            await withTaskCancellationHandler(operation: { await deliveryGate.hold() }, onCancel: { deliveryGate.noteCancellation() })
        }
        return ready // Deliberately return the actual lease even after cancellation; App must reject it.
    }
    func adoptThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async throws -> DevelopmentThumbnailPresentationLease {
        counts.adoptAttempts += 1; let value = try await shared.adoptThumbnails(ready, registration: registration)
        counts.adoptions += 1; return value
    }
    func releaseThumbnails(_ ready: DevelopmentThumbnailReadyLease, registration: DevelopmentThumbnailRegistration) async {
        await shared.releaseThumbnails(ready, registration: registration); counts.readyReleases += 1
    }
    func releaseThumbnails(_ presentation: DevelopmentThumbnailPresentationLease, registration: DevelopmentThumbnailRegistration) async {
        await shared.releaseThumbnails(presentation, registration: registration); counts.presentationReleases += 1
    }
    func revokeThumbnails(_ registration: DevelopmentThumbnailRegistration) async { await shared.revokeThumbnails(registration) }
    func joinThumbnails(_ registration: DevelopmentThumbnailRegistration) async {
        await shared.joinThumbnails(registration); counts.joins += 1
    }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { try await shared.open(source) }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap { try await shared.render(request) }
    func cancel(_ consumer: PreviewConsumerID) async { await shared.cancel(consumer) }
    func cancelAndJoin(_ consumer: PreviewConsumerID) async { await shared.cancelAndJoin(consumer) }
    func close(_ lease: DevelopmentPreviewSessionID) async { await shared.close(lease); counts.closes += 1 }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { try await shared.revalidate(lease, source: source) }
    func sourceFacts(_ lease: EditingPreviewLease) async throws -> DevelopmentSourceFacts { try await shared.sourceFacts(lease) }
    func analyze(_ request: DevelopmentAnalysisRequest) async throws -> DevelopmentAnalysisResult { try await shared.analyze(request) }
    func joinAnalysis(_ request: DevelopmentAnalysisRequest) async { await shared.joinAnalysis(request) }
    func makeProgressChannel(_ lease: EditingPreviewLease, consumer: PreviewConsumerID) async throws -> EditingProgressChannel { try await shared.makeProgressChannel(lease, consumer: consumer) }
    func closeProgressChannel(_ id: PreviewProgressChannelID) async { await shared.closeProgressChannel(id) }
}
