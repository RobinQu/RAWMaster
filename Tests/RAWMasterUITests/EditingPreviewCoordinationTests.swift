import AppKit
import XCTest
@testable import RAWMaster
import RAWMasterCore
@testable import RAWMasterImaging

final class EditingPreviewCoordinationTests: XCTestCase {
    @MainActor private func wait(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Preview coordination timed out", file: file, line: line)
    }
    private func source(_ id: String = "A") -> EditingSourceSnapshot {
        .init(projectID: "project", assetID: id, contentSHA256: String(repeating: "a", count: 64), byteCount: 100,
              admissionFingerprint: "admission", sourceLocation: URL(fileURLWithPath: "/fixture/\(id).raw"))
    }
    @MainActor func testCancelledBaselineLateFailureCannotCoverNewImage() async throws {
        let backend = ControllablePreviewBackend(hold: true)
        let pane = EditingPreviewPane(role: .comparison, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
        try await wait { await backend.requests.count == 1 }
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .detail), input: input)
        try await wait { await backend.requests.count == 2 }
        await backend.finish(1)
        try await wait { pane.frame?.quality == .detail }
        let currentID = pane.frame?.id
        await backend.finish(0, error: NSError(domain: "CancelledOldBaseline", code: 1))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(pane.frame?.id, currentID); XCTAssertNil(pane.error)
        let requests = await backend.requests
        XCTAssertEqual(requests[1].viewport.maxPixel, 0, "Detail always asks for native pixels explicitly")
        await pane.shutdown()
    }
    @MainActor func testNativePresentationRebindRequiresTheSameViewport() async throws {
        let backend = ControllablePreviewBackend()
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "actualPixels", phase: "discrete")
        let raw = DevelopmentPreviewSource.raw(source())
        let firstWindow = CGRect(x: 0.125, y: 0.125, width: 0.25, height: 0.25)
        let secondWindow = CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25)
        let first = try EditingPreviewIntent(source: raw, recipe: .init(), quality: .detail,
            presentationID: "first", detailWindow: firstWindow)
        pane.submit(first, input: input)
        try await wait { pane.frame != nil && !pane.rendering }
        let firstID = try XCTUnwrap(pane.frame?.id)
        let sameViewport = try EditingPreviewIntent(source: raw, recipe: .init(), quality: .detail,
            presentationID: "rebound", detailWindow: firstWindow)
        XCTAssertTrue(pane.reuseForPresentation(sameViewport, input: input))
        XCTAssertEqual(pane.frame?.id, firstID)
        let differentViewport = try EditingPreviewIntent(source: raw, recipe: .init(), quality: .detail,
            presentationID: "panned", detailWindow: secondWindow)
        XCTAssertFalse(pane.reuseForPresentation(differentViewport, input: input))
        pane.submit(differentViewport, input: input)
        try await wait { pane.frame?.id != firstID && !pane.rendering }
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.viewport.window), [firstWindow, secondWindow])
        await pane.shutdown()
    }
    @MainActor func testLeaseRetirementWaitsForLateOpenAndCannotPublishIntoNewPhoto() async throws {
        let backend = ControllablePreviewBackend(holdOpen: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
        try await wait { await backend.opens == 1 }
        pane.reset()
        pane.submit(try .init(source: .raw(source("B")), recipe: .init(), quality: .settled), input: input)
        await backend.finishOpen()
        try await wait { await backend.opens == 2 }
        let closedBeforeNewOpen = await backend.closed.count
        XCTAssertEqual(closedBeforeNewOpen, 1)
        await backend.finishOpen()
        try await wait { pane.frame != nil }
        let renders = await backend.requests
        XCTAssertEqual(renders.count, 1, "A retired late open must close before it can render")
        await pane.shutdown()
        let closed = await backend.closed.count; XCTAssertEqual(closed, 2)
    }
    @MainActor func testRapidPhotoChangesCancelIntermediateOpensButJoinActiveCapture() async throws {
        let backend = ControllablePreviewBackend(holdOpen: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source("A")), recipe: .init(), quality: .settled), input: input)
        try await wait { await backend.opens == 1 }
        for id in ["B", "C", "D"] {
            pane.submit(try .init(source: .raw(source(id)), recipe: .init(), quality: .settled), input: input)
            await Task.yield()
        }
        let opensWhileBlocked = await backend.opens; XCTAssertEqual(opensWhileBlocked, 1)
        await backend.finishOpen()
        try await wait { await backend.opens == 2 }
        let opened = await backend.openedAssetIDs
        XCTAssertEqual(opened, ["A", "D"], "Obsolete queued opens must never capture intermediate RAWs")
        let closed = await backend.closed.count; XCTAssertEqual(closed, 1, "The active old capture really joins before opening D")
        await backend.finishOpen(); try await wait { pane.frame != nil }
        await pane.shutdown()
    }
    @MainActor func testFailedStrictRevalidationCanRetryAndNeverLeaksKnownLease() async throws {
        let backend = ControllablePreviewBackend()
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let intent = try EditingPreviewIntent(source: .raw(source()), recipe: .init(), quality: .settled)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(intent, input: input); try await wait { pane.frame != nil }
        let originalLease = try XCTUnwrap(pane.frame?.leaseID)
        pane.invalidateDisplayedSource(); await backend.failRevalidationOnce()
        do { try await pane.revalidate(source: source()); XCTFail("Fixture must fail its first strict verification") } catch {}
        XCTAssertTrue(pane.sourceInvalidated); XCTAssertNil(pane.frame)
        try await pane.revalidate(source: source())
        pane.submit(intent, input: input); try await wait { pane.frame != nil }
        XCTAssertEqual(pane.frame?.leaseID, originalLease)
        let opens = await backend.opens, checks = await backend.revalidations
        XCTAssertEqual(opens, 1); XCTAssertEqual(checks, 2)
        await pane.shutdown()
        let closed = await backend.closed; XCTAssertEqual(closed, [originalLease])
    }
    @MainActor func testLeavingAfterFailedRevalidationAlwaysClosesExistingLease() async throws {
        let backend = ControllablePreviewBackend()
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
        try await wait { pane.frame != nil }
        let originalLease = try XCTUnwrap(pane.frame?.leaseID)
        pane.invalidateDisplayedSource(); await backend.failRevalidationOnce()
        do { try await pane.revalidate(source: source()); XCTFail("Expected strict verification failure") } catch {}
        pane.reset(); await pane.joinRetirement()
        let closed = await backend.closed; XCTAssertEqual(closed, [originalLease])
        pane.submit(try .init(source: .raw(source("B")), recipe: .init(), quality: .settled), input: input)
        try await wait { pane.frame != nil }
        XCTAssertNotEqual(pane.frame?.leaseID, originalLease)
        await pane.shutdown()
    }
    @MainActor func testScopeExitDuringFailedRevalidationClosesLeaseEvenWhenReplacementThrows() async throws {
        let backend = ControllablePreviewBackend(holdRevalidation: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
        try await wait { pane.frame != nil }
        let originalLease = try XCTUnwrap(pane.frame?.leaseID)
        pane.invalidateDisplayedSource()
        let verification = Task { try await pane.revalidate(source: source()) }
        try await wait { await backend.revalidations == 1 }
        pane.reset()
        await backend.finishRevalidation(error: DevelopmentPreviewError.sourceInvalidated)
        _ = try? await verification.value
        await pane.joinRetirement()
        let closed = await backend.closed; XCTAssertEqual(closed, [originalLease])
        XCTAssertNil(pane.frame)
        await pane.shutdown()
    }
    @MainActor func testInitialOpenFailureNeedsExplicitVerifiedNewLeaseBeforeRendering() async throws {
        let backend = ControllablePreviewBackend(initialOpenFails: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let intent = try EditingPreviewIntent(source: .raw(source()), recipe: .init(), quality: .settled)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(intent, input: input); try await wait { pane.sourceInvalidated }
        pane.submit(intent, input: input); await Task.yield()
        let failedOpens = await backend.opens; XCTAssertEqual(failedOpens, 1)
        XCTAssertNil(pane.frame)
        try await pane.revalidate(source: source())
        XCTAssertFalse(pane.sourceInvalidated)
        pane.submit(intent, input: input); try await wait { pane.frame != nil }
        let opens = await backend.opens; XCTAssertEqual(opens, 2)
        let renderCount = await backend.requests.count; XCTAssertEqual(renderCount, 1)
        await pane.shutdown()
        let closed = await backend.closed.count; XCTAssertEqual(closed, 1)
    }
    @MainActor func testScopeExitDuringStrictFreshOpenRetryJoinsAndClosesLateLease() async throws {
        let backend = ControllablePreviewBackend(holdOpen: true, initialOpenFails: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
        try await wait { pane.sourceInvalidated }
        let retry = Task { try await pane.revalidate(source: source()) }
        try await wait { await backend.opens == 2 }
        pane.reset()
        var joined = false
        let joining = Task { await pane.joinRetirement(); joined = true }
        await Task.yield(); XCTAssertFalse(joined)
        await backend.finishOpen()
        _ = try? await retry.value; await joining.value
        let closed = await backend.closed.count; XCTAssertEqual(closed, 1)
        XCTAssertNil(pane.frame)
        let renders = await backend.requests.count; XCTAssertEqual(renders, 0)
        await pane.shutdown()
    }
    @MainActor func testCancellingFreshRetryCallerBeforePaneShutdownRetainsAndClosesAcquiredLease() async throws {
        let backend = ControllablePreviewBackend(holdOpen: true, initialOpenFails: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
        try await wait { pane.sourceInvalidated }
        let retry = Task { try await pane.revalidate(source: source()) }
        try await wait { await backend.opens == 2 }
        // This is Controller.shutdown's ordering: cancel/join the revalidation caller before resetting the pane.
        retry.cancel()
        await backend.finishOpen()
        do { try await retry.value; XCTFail("A cancelled retry cannot restore publication") } catch {}
        XCTAssertTrue(pane.sourceInvalidated); XCTAssertNil(pane.frame)
        let closedBeforeShutdown = await backend.closed; XCTAssertTrue(closedBeforeShutdown.isEmpty)
        await pane.shutdown()
        let acquired = await backend.openedLeaseIDs, closed = await backend.closed
        XCTAssertEqual(acquired.count, 1)
        XCTAssertEqual(closed, acquired, "The newly acquired lease must close exactly once despite caller cancellation")
    }
    @MainActor func testShutdownCompletesRetirementTicketsAfterCancelledInitialOpenReturnsNoLease() async throws {
        let backend = ControllablePreviewBackend(holdOpen: true, failCancelledOpen: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled),
                    input: .capture(control: "fixture", phase: "programmatic"))
        try await wait { await backend.opens == 1 }
        pane.reset()
        var returned = false
        let shutdown = Task { await pane.shutdown(); returned = true }
        await Task.yield(); await backend.finishOpen()
        for _ in 0..<500 { if returned { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(returned, "An idle driver cannot exit while a later reset's retirement ticket is unacknowledged")
        guard returned else { return }
        await shutdown.value
        XCTAssertEqual(pane.ownedOperationCount, 0)
        let closed = await backend.closed; XCTAssertTrue(closed.isEmpty, "Cancelled open returned no lease to close")
    }
    @MainActor func testRepeatedShutdownAndResetRemainIdempotentAfterDriverExit() async throws {
        let backend = ControllablePreviewBackend()
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled),
                    input: .capture(control: "fixture", phase: "programmatic"))
        try await wait { pane.frame != nil }
        await pane.shutdown()
        for _ in 0..<3 { pane.reset(); await pane.shutdown(); await pane.joinRetirement() }
        let closed = await backend.closed.count, opens = await backend.opens
        XCTAssertEqual(closed, 1); XCTAssertEqual(opens, 1); XCTAssertEqual(pane.ownedOperationCount, 0)
    }
    @MainActor func testIdenticalRequestsDoNotOpenOrRenderTwiceAndClosingBaselinePreservesPrimary() async throws {
        let backend = ControllablePreviewBackend()
        let coordinator = EditingPreviewCoordinator(backend: backend)
        let intent = try EditingPreviewIntent(source: .raw(source()), recipe: .init(), quality: .settled)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        coordinator.primary.submit(intent, input: input); coordinator.primary.submit(intent, input: input)
        coordinator.comparison.submit(intent, input: input)
        try await wait { coordinator.primary.frame != nil && coordinator.comparison.frame != nil }
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 2); XCTAssertNotEqual(requests[0].consumerID, requests[1].consumerID)
        XCTAssertNotEqual(requests[0].sessionID, requests[1].sessionID)
        coordinator.comparison.reset()
        try await wait { await backend.closed.count == 1 }
        var changed = DevelopmentRecipe(); changed.exposureEV = 1
        coordinator.primary.submit(try .init(source: .raw(source()), recipe: changed, quality: .settled), input: input)
        try await wait { coordinator.primary.frame?.revision == coordinator.primary.currentRevision }
        XCTAssertNotNil(coordinator.primary.frame); XCTAssertNil(coordinator.primary.error)
        let opens = await backend.opens; XCTAssertEqual(opens, 2)
        await coordinator.shutdown()
    }
    @MainActor func testSourceInvalidationRequiresExplicitStrictRevalidationWithoutAutomaticReopen() async throws {
        let backend = ControllablePreviewBackend(hold: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let intent = try EditingPreviewIntent(source: .raw(source()), recipe: .init(), quality: .settled)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(intent, input: input); try await wait { await backend.requests.count == 1 }
        await backend.finish(0, error: DevelopmentPreviewError.sourceInvalidated)
        try await wait { pane.sourceInvalidated }
        XCTAssertNil(pane.frame)
        pane.submit(intent, input: input)
        try await Task.sleep(nanoseconds: 10_000_000)
        let opens = await backend.opens; XCTAssertEqual(opens, 1)
        try await pane.revalidate(source: source())
        pane.submit(intent, input: input); try await wait { await backend.requests.count == 2 }
        await backend.finish(1); try await wait { pane.frame != nil }
        let requests = await backend.requests
        XCTAssertEqual(requests[0].sessionID, requests[1].sessionID)
        XCTAssertNotEqual(requests[0].sourceGeneration, requests[1].sourceGeneration)
        let revalidations = await backend.revalidations; XCTAssertEqual(revalidations, 1)
        await pane.shutdown()
    }
    @MainActor func testShutdownJoinsUncooperativeRenderAndPreventsNewSubmission() async throws {
        let backend = ControllablePreviewBackend(hold: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let intent = try EditingPreviewIntent(source: .raw(source()), recipe: .init(), quality: .settled)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        pane.submit(intent, input: input); try await wait { await backend.requests.count == 1 }
        var returned = false
        let quit = Task { await pane.shutdown(); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        await backend.finish(0); await quit.value
        XCTAssertTrue(returned); XCTAssertNil(pane.frame)
        pane.submit(intent, input: input); await Task.yield()
        let requests = await backend.requests.count; XCTAssertEqual(requests, 1)
    }
    @MainActor func testWrongRevisionIsRejectedAndDrawIdentityIsValidatedOnlyOnce() async throws {
        let backend = ControllablePreviewBackend(hold: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend)
        let intent = try EditingPreviewIntent(source: .raw(source()), recipe: .init(), quality: .settled)
        let input = EditingPreviewInput.capture(control: "fixture", phase: "programmatic")
        XCTAssertNil(input.eventAt, "Programmatic entry never inherits NSApp.currentEvent")
        pane.submit(intent, input: input); try await wait { await backend.requests.count == 1 }
        await backend.finish(0, revisionOffset: 1)
        try await wait { pane.error != nil }; XCTAssertNil(pane.frame)
        pane.submit(intent, input: input); try await wait { await backend.requests.count == 2 }
        await backend.finish(1); try await wait { pane.frame != nil }
        let id = try XCTUnwrap(pane.frame?.id)
        func event(_ frame: UUID) -> ImageFrameDrawEvent {
            .init(frameID: frame, drawBeganUptimeNanoseconds: 1, drawReturnedUptimeNanoseconds: 2, imagePixelWidth: 120, imagePixelHeight: 80)
        }
        XCTAssertFalse(pane.didDraw(event(UUID())))
        XCTAssertTrue(pane.didDraw(event(id)))
        XCTAssertFalse(pane.didDraw(event(id)))
        await pane.shutdown(); XCTAssertFalse(pane.didDraw(event(id)))
    }
    @MainActor func testControllerGestureSettlesLatestValueWithoutRerenderingCropOverlay() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let backend = ControllablePreviewBackend()
        let controller = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults, previewBackend: backend)
        controller.focus(f.assets[0]); try await wait { controller.preview != nil }
        controller.previewInteractionChanged("exposure", active: true)
        controller.setRecipe { $0.exposureEV = 0.5 }
        try await wait { controller.previews.primary.frame?.quality == .interactive }
        controller.setRecipe { $0.exposureEV = 0.9 }
        controller.previewInteractionChanged("exposure", active: false)
        try await wait { controller.previews.primary.frame?.quality == .settled && controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
        let last = await backend.requests.last
        XCTAssertEqual(last?.recipe.exposureEV, 0.9)
        controller.cropEditing = true; controller.previewContextChanged()
        try await wait { controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
        let before = await backend.requests.count
        controller.previewInteractionChanged("crop", active: true)
        controller.setRecipe { $0.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        controller.previewInteractionChanged("crop", active: false)
        await Task.yield()
        let after = await backend.requests.count; XCTAssertEqual(after, before)
        controller.cropEditing = false; controller.previewContextChanged()
        try await wait { await backend.requests.count > after }
        controller.setActualPixels(true); controller.setActualPixels(true); controller.requestPreview()
        try await wait { controller.previews.primary.frame?.quality == .detail }
        let detail = await backend.requests.filter { $0.quality == .detail }
        XCTAssertEqual(detail.count, 1); XCTAssertEqual(detail.first?.viewport.maxPixel, 0)
        await controller.shutdown()
    }
    @MainActor func testContinuousZoomDeduplicatesTheSameSamplesWithoutEnteringActualPixels() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let mode = PreviewPerformancePreferences.mode
        defer { PreviewPerformancePreferences.mode = mode }
        let backend = ControllablePreviewBackend()
        let controller = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults, previewBackend: backend)
        PreviewPerformancePreferences.mode = .balanced
        controller.focus(f.assets[0]); try await wait { controller.preview != nil }
        let source = CGSize(width: 6000, height: 4000), viewport = CGSize(width: 1500, height: 1000)
        let zoom = ImageTransform(scale: 1.3)
        let snapshot = ImageCanvasViewportSnapshot(frameID: controller.previews.primary.frame?.id, viewportSize: viewport,
            imagePixelSize: source, imageRect: ImageViewportGeometry.imageRect(pixelSize: source, viewport: viewport,
                transform: zoom, backingScale: 2), backingScale: 2, transform: zoom)
        controller.updateCanvasSampling(snapshot, role: .primary, zooming: true)
        try await wait { controller.previews.primary.frame?.quality == .detail }
        let initialRequests = await backend.requests.count
        for _ in 0..<20 { controller.updateCanvasSampling(snapshot, role: .primary, zooming: true) }
        controller.updateCanvasSampling(snapshot, role: .primary, zooming: false)
        await Task.yield()
        let zoomRequests = await backend.requests
        XCTAssertEqual(zoomRequests.count, initialRequests)
        let sampled = zoomRequests.filter { $0.quality == .detail }
        XCTAssertEqual(sampled.count, 1)
        XCTAssertEqual(try XCTUnwrap(sampled.first?.viewport.detailScale), 0.65, accuracy: 0.0001)
        XCTAssertFalse(controller.actualPixels)
        XCTAssertTrue(controller.resetCanvasSampling())
        controller.previewContextChanged()
        try await wait { controller.previews.primary.frame?.quality == .settled }
        controller.setActualPixels(true)
        try await wait { await backend.requests.count == initialRequests + 2 }
        let detailRequests = await backend.requests.filter { $0.quality == .detail }
        XCTAssertEqual(detailRequests.count, 2)
        XCTAssertNil(detailRequests.last?.viewport.detailScale, "Explicit 1:1 does not inherit the free zoom density")
        XCTAssertTrue(controller.actualPixels)
        await controller.shutdown()
    }

    @MainActor func testReturningToServedPixelsRevokesQueuedAndInFlightPanWindows() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let previousMode = PreviewPerformancePreferences.mode
        PreviewPerformancePreferences.mode = .balanced
        defer { PreviewPerformancePreferences.mode = previousMode }
        let backend = ControllablePreviewBackend(hold: true)
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library,
            defaults: fixture.defaults, previewBackend: backend)
        let origin = CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.15)
        let far = CGRect(x: 0.65, y: 0.65, width: 0.15, height: 0.15)
        controller.isPresented = true
        controller.focus(fixture.assets[0]); try await wait { await backend.requests.count == 1 }
        await backend.finish(0); try await wait { controller.preview != nil }
        controller.setRecipe { $0.exposureEV = 0.5 }
        try await wait { await backend.requests.count == 2 }
        await backend.finish(1); try await wait { !controller.previews.primary.rendering }
        controller.setDevelopmentOriginalHeld(true)
        try await wait { await backend.requests.count == 3 }
        await backend.finish(2); try await wait { !controller.previews.primary.rendering }
        controller.updateDetailVisibleWindow(origin)
        controller.setActualPixels(true)
        try await wait { await backend.requests.count == 4 }
        await backend.finish(3)
        let pane = controller.previews.primary
        try await wait { pane.frame?.window != nil && !pane.rendering }
        let original = try XCTUnwrap(pane.frame)
        XCTAssertNotEqual(pane.frameRecipe, controller.recipe)

        controller.updateDetailVisibleWindow(far)
        controller.updateDetailVisibleWindow(origin)
        try await Task.sleep(for: .milliseconds(180))
        let afterQueuedReturn = await backend.requests.count
        XCTAssertEqual(afterQueuedReturn, 4)
        XCTAssertEqual(controller.detailWindow, original.window)
        XCTAssertEqual(pane.frame?.id, original.id)

        controller.updateDetailVisibleWindow(far)
        try await wait { await backend.requests.count == 5 }
        let outsideRevision = pane.currentRevision
        controller.updateDetailVisibleWindow(origin)
        XCTAssertGreaterThan(pane.currentRevision, outsideRevision)
        await backend.finish(4) // Simulate a renderer that completes after cancellation.
        try await wait { await backend.requests.count == 6 }
        XCTAssertEqual(pane.frame?.id, original.id)
        let latest = await backend.requests.last
        XCTAssertEqual(latest?.viewport.window, original.window)
        await backend.finish(5)
        try await wait { pane.frame?.revision == pane.currentRevision && !pane.rendering }

        controller.updateDetailVisibleWindow(far)
        try await wait { await backend.requests.count == 7 }
        let heldFrameID = pane.frame?.id
        controller.setDevelopmentOriginalHeld(false)
        let draftOutsideRevision = pane.currentRevision
        controller.updateDetailVisibleWindow(origin)
        XCTAssertGreaterThan(pane.currentRevision, draftOutsideRevision)
        await backend.finish(6)
        try await wait { await backend.requests.count == 8 }
        XCTAssertEqual(pane.frame?.id, heldFrameID)
        let draft = await backend.requests.last
        XCTAssertEqual(draft?.viewport.window, original.window)
        XCTAssertEqual(draft?.recipe, controller.recipe)
        await backend.finish(7)
        try await wait { pane.frame?.revision == pane.currentRevision && !pane.rendering }
        XCTAssertEqual(pane.frameRecipe, controller.recipe)

        controller.updateDetailVisibleWindow(far)
        try await wait { await backend.requests.count == 9 }
        controller.previewInteractionChanged("exposure", active: true)
        let interactingOutsideRevision = pane.currentRevision
        controller.updateDetailVisibleWindow(origin)
        XCTAssertGreaterThan(pane.currentRevision, interactingOutsideRevision)
        controller.previewInteractionChanged("exposure", active: false)
        await backend.finish(8)
        try await wait { await backend.requests.count == 10 }
        let afterInteraction = await backend.requests.last
        XCTAssertEqual(afterInteraction?.viewport.window, original.window)
        await backend.finish(9)
        try await wait { pane.frame?.revision == pane.currentRevision && !pane.rendering }
        XCTAssertTrue(controller.actualPixels)
        await controller.shutdown()
    }

    @MainActor func testControllerSourceInvalidationDisablesDevelopmentUntilCoreAndServiceRevalidate() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let backend = ControllablePreviewBackend(hold: true)
        let controller = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults, previewBackend: backend)
        controller.focus(f.assets[0]); try await wait { await backend.requests.count == 1 }
        await backend.finish(0, error: DevelopmentPreviewError.sourceInvalidated)
        try await wait { controller.sourceNeedsRevalidation }
        XCTAssertFalse(controller.sourceReady); XCTAssertNil(controller.preview)
        controller.requestPreview(); await Task.yield()
        let opens = await backend.opens; XCTAssertEqual(opens, 1)
        controller.revalidatePreviewSource()
        try await wait { controller.sourceReady && !controller.sourceNeedsRevalidation && !controller.revalidatingSource }
        try await wait { await backend.requests.count == 2 }
        await backend.finish(1); try await wait { controller.preview != nil }
        let revalidations = await backend.revalidations; XCTAssertEqual(revalidations, 1)
        await controller.shutdown()
    }
}

actor ControllablePreviewBackend: EditingPreviewBackend {
    private(set) var requests: [DevelopmentPreviewRequest] = []
    private(set) var opens = 0
    private(set) var openedAssetIDs: [String] = []
    private(set) var openedLeaseIDs: [DevelopmentPreviewSessionID] = []
    private var shouldFailRevalidation = false
    private var shouldFailOpen: Bool
    private(set) var closed: [DevelopmentPreviewSessionID] = []
    private(set) var revalidations = 0
    private var generation: UInt64 = 0
    private var pending: [Int: CheckedContinuation<EditingPreviewBitmap, Error>] = [:]
    private var pendingOpen: CheckedContinuation<Void, Never>?
    private let canonicalGesture: Bool
    private let mismatchedGestureGeneration: Bool
    private(set) var cancelledRequests: [Int] = []
    private let hold: Bool
    private let holdOpen: Bool
    private let failCancelledOpen: Bool
    private let holdRevalidation: Bool
    private var pendingRevalidation: CheckedContinuation<Void, Error>?
    init(hold: Bool = false, holdOpen: Bool = false, holdRevalidation: Bool = false, initialOpenFails: Bool = false, failCancelledOpen: Bool = false, canonicalGesture:Bool = false, mismatchedGestureGeneration:Bool = false) {
        self.canonicalGesture=canonicalGesture;self.mismatchedGestureGeneration=mismatchedGestureGeneration
        self.hold = hold; self.holdOpen = holdOpen; self.holdRevalidation = holdRevalidation; self.shouldFailOpen = initialOpenFails; self.failCancelledOpen = failCancelledOpen
    }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease {
        opens += 1
        if case .raw(let snapshot) = source { openedAssetIDs.append(snapshot.assetID) }
        if shouldFailOpen { shouldFailOpen = false; throw DevelopmentPreviewError.sourceInvalidated }
        if holdOpen { await withCheckedContinuation { pendingOpen = $0 } }
        if failCancelledOpen { try Task.checkCancellation() }
        generation += 1; let id = DevelopmentPreviewSessionID(); openedLeaseIDs.append(id)
        let identity="coordination-fixture-\(generation)"
        let capability=canonicalGesture ? PreviewCanonicalGestureCapability(sessionID:id,
            sourceGeneration:generation+(mismatchedGestureGeneration ? 1:0),sourceIdentity:identity,nativeSize:.init(width:120,height:80)):nil
        return .init(id:id,generation:generation,sourceIdentity:identity,canonicalGesture:capability)
    }
    func finishOpen() { pendingOpen?.resume(); pendingOpen = nil }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap {
        let index = requests.count; requests.append(request)
        if hold {
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { pending[index] = $0 }
            },onCancel:{Task {await self.recordCancellation(index)}})
        }
        return bitmap(request)
    }
    private func recordCancellation(_ index:Int) { cancelledRequests.append(index) }
    func finishAll() { for index in Array(pending.keys) { finish(index) } }
    func finish(_ index: Int, error: Error? = nil, revisionOffset: UInt64 = 0) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: bitmap(requests[index], revisionOffset: revisionOffset)) }
    }
    private func bitmap(_ request: DevelopmentPreviewRequest, revisionOffset: UInt64 = 0) -> EditingPreviewBitmap {
        let size = request.quality == .detail ? CGSize(width: 3000, height: 2000) : CGSize(width: 120, height: 80)
        return .init(id: UUID(), image: NSImage(size: size), leaseID: request.sessionID,
            generation: request.sourceGeneration, consumerID: request.consumerID, revision: request.revision + revisionOffset,
            quality: request.quality, nativeSize: .init(width: 3000, height: 2000), outputSize: size,
            approximate: request.quality == .interactive, window: request.viewport.window)
    }
    func cancel(_ consumer: PreviewConsumerID) async {}
    func close(_ lease: DevelopmentPreviewSessionID) async { closed.append(lease) }
    func finishRevalidation(error: Error? = nil) {
        if let error { pendingRevalidation?.resume(throwing: error) } else { pendingRevalidation?.resume() }
        pendingRevalidation = nil
    }
    func failRevalidationOnce() { shouldFailRevalidation = true }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease {
        revalidations += 1
        if holdRevalidation { try await withCheckedThrowingContinuation { pendingRevalidation = $0 } }
        if shouldFailRevalidation { shouldFailRevalidation = false; throw DevelopmentPreviewError.sourceInvalidated }
        generation += 1; return .init(id: lease, generation: generation)
    }
}


extension EditingPreviewCoordinationTests {
    /// Capability injection proves scheduling only; real source-domain/output qualification is in Imaging tests.
    @MainActor func testCanonicalGestureDeduplicatesEndBeforeAndAfterActualFrame() async throws {
        for frameBeforeEnd in [false,true] {
            let backend=ControllablePreviewBackend(hold:true,canonicalGesture:true)
            let pane=EditingPreviewPane(role:.primary,backend:backend)
            let input=EditingPreviewInput.capture(control:"photos.color.saturation",phase:"change")
            let r=try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:0.2))))
            do {
                pane.submit(try .init(source:.raw(source()),recipe:.init(),quality:.settled),input:input)
                try await wait {await backend.requests.count == 1};await backend.finish(0)
                try await wait {pane.frame != nil}
                pane.submit(try .init(source:.raw(source()),recipe:r,quality:.interactive),input:input,allowCanonicalGesture:true)
                try await wait {await backend.requests.count == 2}
                let actual=await backend.requests[1];XCTAssertEqual(actual.quality,.settled);XCTAssertEqual(actual.recipe,r)
                XCTAssertTrue(pane.canonicalGestureRequestActive)
                if frameBeforeEnd {await backend.finish(1);try await wait {pane.frameRecipe == r}}
                let revision=pane.currentRevision
                pane.submit(try .init(source:.raw(source()),recipe:r,quality:.settled),input:input,allowCanonicalGesture:true)
                XCTAssertEqual(pane.currentRevision,revision)
                if !frameBeforeEnd {await backend.finish(1);try await wait {pane.frameRecipe == r}}
                let count=await backend.requests.count,cancelled=await backend.cancelledRequests
                XCTAssertEqual(count,2);XCTAssertFalse(cancelled.contains(1))
                XCTAssertEqual(pane.frame?.quality,.settled);XCTAssertFalse(try XCTUnwrap(pane.frame).approximate)
                XCTAssertEqual(pane.frame?.revision,revision)
            }catch {await backend.finishAll();await pane.shutdown();throw error}
            await backend.finishAll();await pane.shutdown();XCTAssertEqual(pane.ownedOperationCount,0)
        }
    }
    @MainActor func testCanonicalGestureLatestValueRetainsRealCancellationJoinAndScopeFence() async throws {
        let backend=ControllablePreviewBackend(hold:true,canonicalGesture:true)
        let pane=EditingPreviewPane(role:.primary,backend:backend)
        let input=EditingPreviewInput.capture(control:"photos.color.saturation",phase:"change")
        func r(_ v:Double)throws->DevelopmentRecipe {try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:v))))}
        do {
            pane.submit(try .init(source:.raw(source()),recipe:.init(),quality:.settled),input:input)
            try await wait {await backend.requests.count == 1};await backend.finish(0);try await wait {pane.frame != nil}
            pane.submit(try .init(source:.raw(source()),recipe:r(0.2),quality:.interactive),input:input,allowCanonicalGesture:true)
            try await wait {await backend.requests.count == 2}
            pane.submit(try .init(source:.raw(source()),recipe:r(0.4),quality:.interactive),input:input,allowCanonicalGesture:true)
            try await wait {await backend.requests.count == 3}
            try await wait {await backend.cancelledRequests.contains(1)}
            await backend.finish(2);try await wait {pane.frameRecipe == (try? r(0.4))}
            let current=pane.frame?.id
            await backend.finish(1);await Task.yield();XCTAssertEqual(pane.frame?.id,current)
            pane.submit(try .init(source:.raw(source()),recipe:r(0.6),quality:.interactive),input:input,allowCanonicalGesture:true)
            try await wait {await backend.requests.count == 4}
            pane.reset();XCTAssertFalse(pane.canonicalGestureRequestActive);XCTAssertNil(pane.frame)
            let joined=Task {await pane.joinRetirement()}
            try await wait {await backend.cancelledRequests.contains(3)}
            let before=await backend.closed;XCTAssertTrue(before.isEmpty,"Cancelled waiter still owns the source until it returns")
            await backend.finish(3);await joined.value
            let closed=await backend.closed;XCTAssertEqual(closed.count,1)
            XCTAssertNil(pane.frame);XCTAssertFalse(pane.canonicalGestureRequestActive)
        }catch {await backend.finishAll();await pane.shutdown();throw error}
        await backend.finishAll();await pane.shutdown();XCTAssertEqual(pane.ownedOperationCount,0)
    }
    @MainActor func testCanonicalGestureRejectsDefaultStaleCapabilityComparisonAndExcludedIntent() async throws {
        let r=try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled:true,saturation:0.2))))
        for mode in ["default","stale","comparison","detail","overlay","grain","geometry"] {
            let backend=ControllablePreviewBackend(canonicalGesture:mode != "default",mismatchedGestureGeneration:mode == "stale")
            let pane=EditingPreviewPane(role:mode == "comparison" ? .comparison:.primary,backend:backend)
            let input=EditingPreviewInput.capture(control:"fixture",phase:"change")
            pane.submit(try .init(source:.raw(source()),recipe:.init(),quality:.settled),input:input)
            try await wait {pane.frame != nil}
            var recipe=r
            if mode == "grain" {recipe.adjustmentsV3?.blackAndWhite.grain=0.3}
            if mode == "geometry" {recipe.adjustmentsV3?.geometry.crop = .init(x:0.1,y:0,width:0.9,height:1)}
            let quality:PreviewQuality=mode == "detail" ? .detail:.interactive
            pane.submit(try .init(source:.raw(source()),recipe:recipe,quality:quality),input:input,allowCanonicalGesture:mode != "overlay")
            try await wait {await backend.requests.count == 2}
            let actual=await backend.requests[1];XCTAssertEqual(actual.quality,quality,mode)
            XCTAssertFalse(pane.canonicalGestureRequestActive,mode)
            await pane.shutdown()
        }
    }
}

extension EditingPreviewCoordinationTests {
    func testPromptDispatchQAFlagRequiresExactIsolatedOptIn() {
        func enabled(_ bundle: String? = "io.robinqu.RAWMaster.preview022", _ value: String? = "1") -> Bool {
            EditingPreviewPromptDispatch.enabled(bundleIdentifier: bundle,
                environment: value.map { ["RAWMASTER_QA_PROMPT_CANONICAL_DISPATCH_V1": $0] } ?? [:])
        }
        XCTAssertTrue(enabled()); XCTAssertFalse(enabled(nil)); XCTAssertFalse(enabled("io.robinqu.RAWMaster"))
        XCTAssertFalse(enabled("io.robinqu.RAWMaster.preview022", nil))
        XCTAssertFalse(enabled("io.robinqu.RAWMaster.preview022", "true"))
    }
    @MainActor func testPromptRenderChildActuallyCallsBackendWhileMainActorCannotAdvance() async throws {
        let probe = PromptDispatchEntryProbe(), backend = PromptDispatchEntryBackend(probe: probe)
        let request = DevelopmentPreviewRequest(sessionID: .init(), sourceGeneration: 1,
            consumerID: .init(), role: .primary, revision: 1, recipe: .init(), quality: .settled, viewport: .init(maxPixel: 2400))
        let before = DispatchTime.now().uptimeNanoseconds
        let child = EditingPreviewPromptDispatch.start(backend: backend, request: request)
        // A bounded synchronous hold of this executor: the production helper must genuinely enter elsewhere.
        let status = probe.entered.wait(timeout: .now() + 2)
        if status != .success { child.cancel() }
        let result = await EditingPreviewPromptDispatch.join(child)
        XCTAssertEqual(status, .success)
        let began = try XCTUnwrap(result.requestBeganAt), actualEntry = try XCTUnwrap(probe.entryTime)
        XCTAssertGreaterThanOrEqual(began, before); XCTAssertLessThanOrEqual(began, actualEntry)
        XCTAssertThrowsError(try result.result.get())
        let count = await backend.calls; XCTAssertEqual(count, 1)
    }
    @MainActor func testPromptChildCancellationBeforeWaiterStartsStillWaitsForActualReturn() async throws {
        let probe = PromptDispatchEntryProbe(), backend = PromptDispatchEntryBackend(probe: probe, hold: true)
        let request = DevelopmentPreviewRequest(sessionID: .init(), sourceGeneration: 1,
            consumerID: .init(), role: .primary, revision: 1, recipe: .init(), quality: .settled, viewport: .init(maxPixel: 2400))
        let child = EditingPreviewPromptDispatch.start(backend: backend, request: request)
        let entered = probe.entered.wait(timeout: .now() + 2)
        var returned = false
        let waiter = Task { let value = await EditingPreviewPromptDispatch.join(child); returned = true; return value }
        waiter.cancel() // This MainActor waiter has not been allowed to execute yet.
        do {
            XCTAssertEqual(entered, .success)
            for _ in 0..<500 {
                if await backend.cancelled { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let cancelled = await backend.cancelled
            XCTAssertTrue(cancelled); XCTAssertFalse(returned, "Cancellation is not a completed backend join")
            await backend.release()
            let outcome = await waiter.value
            XCTAssertTrue(returned); XCTAssertNotNil(outcome.requestBeganAt)
            XCTAssertThrowsError(try outcome.result.get())
        } catch { child.cancel(); await backend.release(); _ = await waiter.value; throw error }
        _ = await child.value
    }
    @MainActor func testPromptCanonicalDispatchKeepsLateFrameAndRetirementJoined() async throws {
        let backend = ControllablePreviewBackend(hold: true, canonicalGesture: true)
        let pane = EditingPreviewPane(role: .primary, backend: backend, promptCanonicalDispatch: true)
        let input = EditingPreviewInput.capture(control: "photos.color.saturation", phase: "change")
        func recipe(_ value: Double) throws -> DevelopmentRecipe {
            try DevelopmentRecipe().applying(.promoteToV3).applying(.setParameters(.color(.init(enabled: true, saturation: value))))
        }
        weak var publishedImage: NSImage?
        var retirement: Task<Void, Never>?
        do {
            pane.submit(try .init(source: .raw(source()), recipe: .init(), quality: .settled), input: input)
            try await promptCoordinationWait { await backend.requests.count == 1 }; await backend.finish(0)
            try await promptCoordinationWait { pane.frame != nil }
            XCTAssertTrue(pane.supportsPromptCanonicalDispatch(try recipe(0.2)))
            pane.submit(try .init(source: .raw(source()), recipe: recipe(0.2), quality: .interactive), input: input, allowCanonicalGesture: true)
            try await promptCoordinationWait { await backend.requests.count == 2 }
            pane.submit(try .init(source: .raw(source()), recipe: recipe(0.4), quality: .interactive), input: input, allowCanonicalGesture: true)
            try await promptCoordinationWait { await backend.requests.count == 3 }
            try await promptCoordinationWait { await backend.cancelledRequests.contains(1) }
            await backend.finish(2); try await promptCoordinationWait { pane.frameRecipe == (try? recipe(0.4)) }
            publishedImage = pane.frame?.image
            let newest = pane.frame?.id
            await backend.finish(1, error: DevelopmentPreviewError.closed); await Task.yield()
            XCTAssertEqual(pane.frame?.id, newest); XCTAssertNil(pane.error)
            pane.submit(try .init(source: .raw(source()), recipe: recipe(0.6), quality: .interactive), input: input, allowCanonicalGesture: true)
            try await promptCoordinationWait { await backend.requests.count == 4 }
            pane.reset()
            var joined = false
            retirement = Task { await pane.joinRetirement(); joined = true }
            try await promptCoordinationWait { await backend.cancelledRequests.contains(3) }
            XCTAssertFalse(joined); XCTAssertNil(pane.frame)
            let closedBeforeReturn = await backend.closed; XCTAssertTrue(closedBeforeReturn.isEmpty)
            await backend.finish(3); await retirement?.value
            XCTAssertTrue(joined); XCTAssertFalse(pane.supportsPromptCanonicalDispatch(try recipe(0.2)))
            let closed = await backend.closed; XCTAssertEqual(closed.count, 1)
        } catch { await backend.finishAll(); await retirement?.value; await pane.shutdown(); throw error }
        await backend.finishAll(); await pane.shutdown(); XCTAssertEqual(pane.ownedOperationCount, 0)
        try await promptCoordinationWait { publishedImage == nil }
    }
}

private final class PromptDispatchEntryProbe: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timestamp: UInt64?
    var entryTime: UInt64? { lock.lock(); defer { lock.unlock() }; return timestamp }
    func mark() { lock.lock(); timestamp = DispatchTime.now().uptimeNanoseconds; lock.unlock(); entered.signal() }
}
private actor PromptDispatchEntryBackend: EditingPreviewBackend {
    let probe: PromptDispatchEntryProbe
    let hold: Bool
    private(set) var calls = 0
    private(set) var cancelled = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(probe: PromptDispatchEntryProbe, hold: Bool = false) { self.probe = probe; self.hold = hold }
    func open(_ source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { throw DevelopmentPreviewError.invalidRequest }
    func revalidate(_ lease: DevelopmentPreviewSessionID, source: DevelopmentPreviewSource) async throws -> EditingPreviewLease { throw DevelopmentPreviewError.invalidRequest }
    func render(_ request: DevelopmentPreviewRequest) async throws -> EditingPreviewBitmap {
        calls += 1; probe.mark()
        if hold {
            await withTaskCancellationHandler(operation: {
                if !released { await withCheckedContinuation { continuation = $0 } }
            }, onCancel: { Task { await self.noteCancellation() } })
        }
        throw DevelopmentPreviewError.closed
    }
    private func noteCancellation() { cancelled = true }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func cancel(_ consumer: PreviewConsumerID) async {}
    func close(_ lease: DevelopmentPreviewSessionID) async {}
}

extension EditingPreviewCoordinationTests {
    @MainActor func testPromptChildCancelledBeforeActualCallDoesNotInventRequestTimestamp() async throws {
        let gate = PromptDispatchStartGate(), backend = PromptDispatchEntryBackend(probe: .init())
        let request = DevelopmentPreviewRequest(sessionID: .init(), sourceGeneration: 1,
            consumerID: .init(), role: .primary, revision: 1, recipe: .init(), quality: .settled, viewport: .init(maxPixel: 2400))
        let child = EditingPreviewPromptDispatch.start(backend: backend, request: request,
            beforeCallForTesting: { await gate.hold() })
        do {
            try await promptCoordinationWait { await gate.entered }
            child.cancel(); await gate.release()
            let result = await EditingPreviewPromptDispatch.join(child)
            XCTAssertNil(result.requestBeganAt)
            XCTAssertThrowsError(try result.result.get())
            let calls = await backend.calls; XCTAssertEqual(calls, 0)
        } catch { child.cancel(); await gate.release(); _ = await child.value; throw error }
    }
    @MainActor private func promptCoordinationWait(_ condition: () async -> Bool) async throws {
        for _ in 0..<600 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Prompt coordination fixture timed out")
        throw PromptCoordinationFailure.timeout
    }
}
private enum PromptCoordinationFailure: Error { case timeout }
private actor PromptDispatchStartGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}


extension EditingPreviewCoordinationTests {
    @MainActor func testThumbnailFingerprintsReuseOnlyActualLocalAndDesiredValues() async throws {
        let recipes = [DevelopmentRecipe(), try DevelopmentRecipe().promotingToV2(), DevelopmentRecipe(adjustmentsV3: .init())]
        for recipe in recipes {
            var encodes = 0
            let backend = ControllablePreviewBackend()
            let pane = EditingPreviewPane(role: .primary, backend: backend, recipeFingerprintForTesting: {
                encodes += 1; return try EditingFingerprint.of($0)
            })
            do {
                pane.submit(try .init(source: .raw(source()), recipe: recipe, quality: .settled),
                    input: .capture(control: "memo", phase: "programmatic"))
                try await wait { pane.frame != nil }
                let actualFrame = try XCTUnwrap(pane.frame)
                let originalFP = try EditingFingerprint.of(recipe), promoted = try recipe.promotingToV3()
                let promotedFP = try EditingFingerprint.of(promoted)
                let one = DevelopmentThumbnailRegistration(visibleGeneration: 1)
                let two = DevelopmentThumbnailRegistration(visibleGeneration: 2)
                let a = try pane.thumbnailRequest(recipe: recipe, kind: .summary(.color), registration: one,
                    basis: .currentCanonical, resourceVersion: "resource-A")
                let b = try pane.thumbnailRequest(recipe: recipe, kind: .filters, registration: two,
                    basis: .currentCanonical, resourceVersion: "resource-B")
                for value in [a,b] {
                    XCTAssertEqual(value.expectedRecipeFingerprint, promotedFP)
                    XCTAssertEqual(value.presentedRecipeFingerprint, originalFP)
                    XCTAssertEqual(value.preview.recipe, promoted)
                    XCTAssertEqual(try EditingFingerprint.of(value.preview.recipe), promotedFP)
                    XCTAssertEqual(value.preview.sessionID, actualFrame.leaseID)
                    XCTAssertEqual(value.preview.sourceGeneration, actualFrame.generation)
                    XCTAssertEqual(value.preview.revision, pane.currentRevision)
                    XCTAssertEqual(value.preview.consumerID, pane.consumerID)
                    XCTAssertEqual(value.preview.role, .primary); XCTAssertEqual(value.preview.quality, .settled)
                    XCTAssertEqual(value.preview.viewport.maxPixel, 2400)
                    XCTAssertEqual(value.presentationMode, .managedImage); XCTAssertEqual(value.basis, .currentCanonical)
                }
                XCTAssertEqual(a.registration, one); XCTAssertEqual(b.registration, two)
                XCTAssertNotEqual(a.registration.operationID, b.registration.operationID)
                XCTAssertEqual(a.kind, .summary(.color)); XCTAssertEqual(b.kind, .filters)
                XCTAssertEqual(a.target, .summary128); XCTAssertEqual(b.target, .filters192)
                XCTAssertEqual(a.expectedPhotoFilterResourceVersion, "resource-A")
                XCTAssertEqual(b.expectedPhotoFilterResourceVersion, "resource-B")
                XCTAssertEqual(encodes, recipe.schemaVersion == 3 ? 3 : 5)
                // External callers still prove the actual recipe, even after desired FP is warm.
                XCTAssertThrowsError(try pane.developmentAnalysisRequest(operationID: UUID(), recipe: promoted,
                    expectedFingerprint: String(repeating: "0", count: 64), presentedFingerprint: originalFP,
                    stage: .workingImageBeforeGeometry, operation: .histogram))
                XCTAssertEqual(encodes, recipe.schemaVersion == 3 ? 4 : 6)
            } catch { await pane.shutdown(); throw error }
            await pane.shutdown()
        }
        // Equatable does not establish JSON identity. Cache is tied to actual immutable Desired only.
        var negative = DevelopmentRecipe(); negative.exposureEV = -0.0
        let positive = DevelopmentRecipe()
        XCTAssertEqual(negative, positive)
        var encodes = 0
        let pane = EditingPreviewPane(role: .primary, backend: ControllablePreviewBackend(), recipeFingerprintForTesting: {
            encodes += 1; return try EditingFingerprint.of($0)
        })
        do {
            let input = EditingPreviewInput.capture(control: "memo-zero", phase: "programmatic")
            pane.submit(try .init(source: .raw(source()), recipe: negative, quality: .settled), input: input)
            try await wait { pane.frame != nil }
            let expected = try EditingFingerprint.of(positive)
            for _ in 0..<2 {
                let value = try pane.developmentAnalysisRequest(operationID: UUID(), recipe: positive,
                    expectedFingerprint: expected, presentedFingerprint: expected,
                    stage: .workingImageBeforeGeometry, operation: .histogram)
                XCTAssertEqual(value.presentedRecipeFingerprint, try EditingFingerprint.of(negative))
            }
            XCTAssertEqual(encodes, 3)
            // Preserve the original deliberate uncropped-presentation exception.
            let neutral = DevelopmentRecipe(adjustmentsV3: .init())
            pane.submit(try .init(source: .raw(source()), recipe: neutral, quality: .settled), input: input)
            try await wait { pane.frame?.revision == pane.currentRevision }
            var cropped = neutral; cropped.adjustmentsV3?.geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            let croppedFP = try EditingFingerprint.of(cropped)
            let cropRequest = try pane.developmentAnalysisRequest(operationID: UUID(), recipe: cropped,
                expectedFingerprint: croppedFP, presentedFingerprint: croppedFP,
                stage: .workingImageBeforeGeometry, operation: .histogram)
            XCTAssertEqual(cropRequest.preview.recipe, cropped)
            XCTAssertEqual(cropRequest.presentedRecipeFingerprint, try EditingFingerprint.of(neutral))
            var different = neutral; different.adjustmentsV3?.color.saturation = 0.4
            let differentFP = try EditingFingerprint.of(different)
            XCTAssertThrowsError(try pane.developmentAnalysisRequest(operationID: UUID(), recipe: different,
                expectedFingerprint: differentFP, presentedFingerprint: differentFP,
                stage: .workingImageBeforeGeometry, operation: .histogram))
            var invalid = DevelopmentRecipe(); invalid.exposureEV = .nan
            pane.submit(try .init(source: .raw(source()), recipe: invalid, quality: .settled), input: input)
            try await wait { pane.frame?.revision == pane.currentRevision }
            let count = encodes
            for _ in 0..<2 {
                XCTAssertThrowsError(try pane.developmentAnalysisRequest(operationID: UUID(), recipe: positive,
                    expectedFingerprint: expected, presentedFingerprint: expected,
                    stage: .workingImageBeforeGeometry, operation: .histogram))
            }
            XCTAssertEqual(encodes-count, 4, "Failed actual Desired encoding is never memoized")
        } catch { await pane.shutdown(); throw error }
        await pane.shutdown()
    }

    @MainActor func testThumbnailFingerprintMemoNeverReplacesCurrentLeaseAndPublicationFences() async throws {
        var encodes = 0
        let backend = ControllablePreviewBackend()
        let pane = EditingPreviewPane(role: .primary, backend: backend, recipeFingerprintForTesting: {
            encodes += 1; return try EditingFingerprint.of($0)
        })
        let input = EditingPreviewInput.capture(control: "memo-fences", phase: "programmatic")
        var recipe = DevelopmentRecipe(adjustmentsV3: .init())
        @MainActor func request() throws -> DevelopmentThumbnailRequest {
            try pane.thumbnailRequest(recipe: recipe, kind: .summary(.color),
                registration: .init(visibleGeneration: 1), basis: .currentCanonical, resourceVersion: nil)
        }
        do {
            var intent = try EditingPreviewIntent(source: .raw(source()), recipe: recipe, quality: .settled)
            pane.submit(intent, input: input); try await wait { pane.frame != nil }
            let a = try request(); _ = try request(); XCTAssertEqual(encodes, 3)
            recipe.adjustmentsV3?.color.saturation = 0.3
            intent = try .init(source: .raw(source()), recipe: recipe, quality: .settled)
            pane.submit(intent, input: input); try await wait { pane.frame?.revision == pane.currentRevision }
            let b = try request(); XCTAssertEqual(encodes, 5)
            XCTAssertNotEqual(a.preview.revision, b.preview.revision)
            XCTAssertEqual(b.presentedRecipeFingerprint, try EditingFingerprint.of(recipe))
            pane.invalidateDisplayedSource()
            let before = encodes
            // Public analysis checks authority before evaluating actual caller FP.
            XCTAssertThrowsError(try pane.developmentAnalysisRequest(operationID: UUID(), recipe: recipe,
                expectedFingerprint: try EditingFingerprint.of(recipe), presentedFingerprint: try EditingFingerprint.of(recipe),
                stage: .workingImageBeforeGeometry, operation: .histogram))
            XCTAssertEqual(encodes, before)
            try await pane.revalidate(source: source())
            pane.submit(intent, input: input); try await wait { pane.frame != nil }
            let c = try request()
            XCTAssertEqual(c.preview.sessionID, b.preview.sessionID)
            XCTAssertNotEqual(c.preview.sourceGeneration, b.preview.sourceGeneration)
            XCTAssertEqual(encodes, before+2)
            pane.reset(); await pane.joinRetirement()
            XCTAssertThrowsError(try request())
            pane.submit(try .init(source: .raw(source("B")), recipe: recipe, quality: .settled), input: input)
            try await wait { pane.frame != nil }
            let d = try request(); XCTAssertNotEqual(d.preview.sessionID, c.preview.sessionID)
            XCTAssertEqual(d.presentedRecipeFingerprint, try EditingFingerprint.of(recipe))
        } catch { await pane.shutdown(); throw error }
        await pane.shutdown(); XCTAssertThrowsError(try request())
        let opens = await backend.opens, closed = await backend.closed.count
        XCTAssertEqual(opens, closed)
    }
}
