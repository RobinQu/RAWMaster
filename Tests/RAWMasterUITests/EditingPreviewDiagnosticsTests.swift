import AppKit
import CoreImage
import Metal
import SwiftUI
import XCTest
@testable import RAWMaster
import RAWMasterCore
@testable import RAWMasterImaging

final class EditingPreviewDiagnosticsTests: XCTestCase {
    @MainActor func testCanvasRawDrawPrecedesQueuedAcknowledgementAcrossReplacement() async throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }
        let ip = UUID(), settled = UUID()
        var raw: [(UUID, UInt64, UInt64)] = []
        let sink: @MainActor (ImageCanvasDiagnosticEvent) -> Void = { event in
            if case let .drawn(_, frame, began, returned) = event { raw.append((frame, began, returned)) }
        }
        let ack = expectation(description: "original callback arrives after replacement")
        canvas.onFrameDrawn = { event in
            XCTAssertEqual(event.frameID, ip)
            XCTAssertEqual(canvas.frameID, settled)
            ack.fulfill()
        }
        canvas.frameID = ip
        canvas.update(image: image, actualPixels: false, transform: .init())
        canvas.updateCanvasDiagnostic(sink, installedFrame: ip)
        do {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            canvas.draw(canvas.bounds)
        }
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first?.0, ip)
        if let first = raw.first { XCTAssertLessThanOrEqual(first.1, first.2) }
        canvas.frameID = settled
        canvas.update(image: image, actualPixels: false, transform: .init())
        canvas.updateCanvasDiagnostic(sink, installedFrame: settled)
        XCTAssertEqual(raw.map { $0.0 }, [ip])
        await fulfillment(of: [ack], timeout: 2)
        canvas.onFrameDrawn = nil
        canvas.endCanvasDiagnostic()
    }

    @MainActor func testActualCanvasDismantleDropsManagedImageButKeepsExternalAliasCharged() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        let ledger = PreviewPresentationLedger()
        let scope = PreviewPresentationScope(ledgerForTesting: ledger)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = CIContext(mtlDevice: device)
        defer { context.clearCaches(); scope.closeAndRetire() }
        let layout = try PreviewInteractiveLayout.make(width: 8, height: 8, float: false)
        weak var displayed: NSImage?
        var escaped: NSImage?
        let frame = UUID()
        var dismantled = 0
        try autoreleasepool {
            let ticket = try scope.reserveSharedSurface(bytes: layout.bytes)
            let output = PreviewInteractiveManagedOutput(layout: layout, ticket: ticket, device: device)
            let image = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
                .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            let result = try output.materialize(image, context: context, nativeSize: CGSize(width: 8, height: 8), check: {})
            let owned = result.image
            displayed = owned
            escaped = owned
            canvas.frameID = frame
            canvas.onTransform = { _ in withExtendedLifetime(owned) {} }
            canvas.onActualPixelsChange = { _ in withExtendedLifetime(owned) {} }
            canvas.onRequestDetail = { withExtendedLifetime(owned) {} }
            canvas.onFrameDrawn = { _ in XCTFail("Dismantle must not create a frame draw") }
            canvas.update(image: owned, actualPixels: false, transform: .init())
            canvas.updateCanvasDiagnostic({ event in
                if case .dismantled = event { dismantled += 1 }
            }, installedFrame: frame)
        }

        scope.closeAndRetire()
        let held = ledger.statistics
        XCTAssertGreaterThan(held.chargedCPUBytes, 0)
        XCTAssertEqual(held.chargedCPUBytes, held.retiredCPUBytes)
        XCTAssertEqual(held.chargedGPUBytes, held.retiredGPUBytes)
        ZoomableImageView.dismantleNSView(canvas, coordinator: ())
        XCTAssertEqual(dismantled, 1)
        XCTAssertFalse(canvas.hasCanvasDiagnostic)
        XCTAssertNil(canvas.frameID)
        XCTAssertNil(canvas.onFrameDrawn)
        XCTAssertNil(canvas.onTransform)
        XCTAssertNil(canvas.onActualPixelsChange)
        XCTAssertNil(canvas.onRequestDetail)
        XCTAssertEqual(ledger.statistics.chargedCPUBytes, held.chargedCPUBytes)
        XCTAssertEqual(ledger.statistics.retiredCPUBytes, held.retiredCPUBytes)
        XCTAssertEqual(ledger.statistics.chargedGPUBytes, held.chargedGPUBytes)
        XCTAssertEqual(ledger.statistics.retiredGPUBytes, held.retiredGPUBytes)
        try autoreleasepool {
            XCTAssertNotNil(displayed)
            let image = try XCTUnwrap(escaped)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(cg.width, 8); XCTAssertEqual(cg.height, 8)
            let bytes = try XCTUnwrap(cg.dataProvider?.data)
            XCTAssertGreaterThan(CFDataGetLength(bytes), 0)
        }
        escaped = nil
        autoreleasepool {}
        XCTAssertNil(displayed, "The retained canvas no longer owns the NSImage or a callback that captured it")
        let closed = ledger.statistics
        XCTAssertEqual(closed.chargedCPUBytes + closed.chargedGPUBytes, 0)
        XCTAssertEqual(closed.retiredCPUBytes + closed.retiredGPUBytes, 0)
        XCTAssertEqual(closed.cleanupFailures, 0)
        withExtendedLifetime(canvas) {}
    }

    @MainActor func testRetainedBorrowedCanvasValueDoesNotHoldGrainPresentationAfterDismantle() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 8, height: 8)
        let canvas = ImageCanvas(frame: NSRect(origin: .zero, size: size))
        let ledger = PreviewPresentationLedger()
        let scope = PreviewPresentationScope(ledgerForTesting: ledger)
        let context = DevelopmentColorEngineV3.makeContext()
        defer { scope.closeAndRetire() }
        weak var displayed: NSImage?
        var published: NSImage?
        var external: NSImage?
        var oldView: ZoomableImageView?
        let frameID = UUID()
        var drawn: UUID?
        try autoreleasepool {
            let source = CIImage(color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
                .cropped(to: CGRect(origin: .zero, size: size))
            let graph = DevelopedV3Graph(image: source, sourceDepth: 32, sourceSize: size, canonicalSize: size,
                                         graphDescriptor: "test-actual-grain-transport-backing")
            let actual = try PreviewGrainFinalTransportV1.materializeBands(graph, context: context,
                maxPixel: 64, scope: scope, check: {})
            published = actual.image
            displayed = actual.image
            let view = ZoomableImageView(image: nil, actualPixels: false, transform: .constant(.init()),
                frameID: frameID, onCanvasDiagnostic: { event in
                    if case let .drawn(_, id, _, _) = event { drawn = id }
                }).borrowingImage(published)
            oldView = view
            view.updateCanvas(canvas)
        }
        published = nil
        try autoreleasepool {
            // The installed canvas can still draw after the coordinator drops its own image.
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = graphics
            canvas.draw(canvas.bounds)
            XCTAssertEqual(drawn, frameID)
            external = try XCTUnwrap(displayed)
        }
        scope.closeAndRetire()
        let held = ledger.statistics.retiredCPUBytes
        XCTAssertGreaterThan(held, 0)
        ZoomableImageView.dismantleNSView(canvas, coordinator: ())
        try autoreleasepool {
            let image = try XCTUnwrap(external)
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(cg.width, 8)
            XCTAssertEqual(cg.height, 8)
            XCTAssertGreaterThan(CFDataGetLength(try XCTUnwrap(cg.dataProvider?.data)), 0)
            XCTAssertEqual(ledger.statistics.chargedCPUBytes, held)
            XCTAssertEqual(ledger.statistics.retiredCPUBytes, held)
        }
        external = nil
        XCTAssertNil(displayed)
        XCTAssertEqual(ledger.statistics.chargedCPUBytes + ledger.statistics.chargedGPUBytes, 0)
        XCTAssertEqual(ledger.statistics.retiredCPUBytes + ledger.statistics.retiredGPUBytes, 0)
        XCTAssertEqual(ledger.statistics.cleanupFailures, 0)
        withExtendedLifetime((oldView, canvas)) {}
    }

    @MainActor func testHostingUnmountSeparatesManagedCanvasFromEscapedCGAlias() async throws {
        _ = NSApplication.shared
        for keepCGAlias in [false, true] {
            let ledger = PreviewPresentationLedger(), scope = PreviewPresentationScope(ledgerForTesting: ledger)
            let store = PreviewQAMainPresentationWitness.Store(ledger: ledger)
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let context = CIContext(mtlDevice: device)
            let layout = try PreviewInteractiveLayout.make(width: 8, height: 8, float: false)
            var published: NSImage?, escapedCG: CGImage?
            weak var imageWitness: NSImage?
            let ticket = try scope.reserveSharedSurface(bytes: layout.bytes)
            let model = ManagedOwnerHostModel(store: store)
            defer {
                published = nil; escapedCG = nil
                context.clearCaches(); scope.closeAndRetire(); autoreleasepool {}
                XCTAssertEqual(ledger.statistics.chargedCPUBytes + ledger.statistics.chargedGPUBytes, 0)
                XCTAssertEqual(ledger.statistics.cleanupFailures, 0)
            }
            try autoreleasepool {
                let output = PreviewInteractiveManagedOutput(layout: layout, ticket: ticket, device: device,
                    qaMainOwnerStoreForTesting: store)
                let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
                    .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
                let pixels = try output.materialize(source, context: context, nativeSize: CGSize(width: 8, height: 8), check: {})
                published = pixels.image; imageWitness = pixels.image; model.image = pixels.image
                if keepCGAlias {
                    escapedCG = try XCTUnwrap(pixels.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                }
            }
            let host = NSHostingView(rootView: ManagedOwnerHost(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                // Cleanup also covers a throw while the real hosting tree is still mounted.
                if let canvas = model.canvas, canvas.hasCanvasDiagnostic {
                    ZoomableImageView.dismantleNSView(canvas, coordinator: ())
                }
                window.contentView = nil; window.close()
            }
            window.contentView = host
            try await wait { host.layoutSubtreeIfNeeded(); return model.canvas?.frameID == model.frameID }
            let canvas = try XCTUnwrap(model.canvas)
            // Model and representable borrow weakly. Only the real canvas and optional CG own pixels now.
            published = nil
            try autoreleasepool {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0))
                let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = graphics
                canvas.draw(canvas.bounds)
                XCTAssertEqual(model.drawnFrame, model.frameID)
            }
            XCTAssertTrue(store.contains(ticket.id))
            scope.closeAndRetire()
            XCTAssertEqual(ledger.statistics.retiredCPUBytes, layout.bytes)
            model.visible = false
            try await wait { host.layoutSubtreeIfNeeded(); return model.dismantledCount == 1 }
            autoreleasepool {}
            let after = store.snapshot("after-host-unmount", controller: nil, primary: nil, comparison: nil)
            let state = try XCTUnwrap(after.images.first)
            XCTAssertEqual(state.canvasDetachCount, 1); XCTAssertEqual(state.canvasFieldsCleared, true)
            XCTAssertFalse(canvas.hasCanvasDiagnostic); XCTAssertNil(canvas.frameID)
            XCTAssertNil(canvas.onFrameDrawn); XCTAssertNil(canvas.onTransform)
            XCTAssertNil(canvas.onActualPixelsChange); XCTAssertNil(canvas.onRequestDetail)
            XCTAssertNil(imageWitness); XCTAssertFalse(state.weakImageAlive)
            if keepCGAlias {
                XCTAssertTrue(state.ledger.present)
                XCTAssertEqual(state.managedUnlockCount, 0); XCTAssertEqual(state.managedStorageReleaseCount, 0)
                XCTAssertEqual(ledger.statistics.retiredCPUBytes, layout.bytes)
                try autoreleasepool {
                    let cg = try XCTUnwrap(escapedCG)
                    let data = try XCTUnwrap(cg.dataProvider?.data)
                    let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
                    XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0, 0, 255, 255])
                }
                withExtendedLifetime(escapedCG) {}
                escapedCG = nil
                autoreleasepool {}
            }
            let final = try XCTUnwrap(store.snapshot("all-aliases-dropped", controller: nil, primary: nil, comparison: nil).images.first)
            XCTAssertFalse(final.ledger.present)
            XCTAssertEqual(final.managedUnlockCount, 1); XCTAssertEqual(final.managedUnlockStatus, 0)
            XCTAssertEqual(final.managedStorageReleaseCount, 1); XCTAssertEqual(final.providerCallbackCount, 0)
            XCTAssertEqual(final.canvasDetachCount, 1)
            XCTAssertEqual(ledger.statistics.chargedCPUBytes + ledger.statistics.chargedGPUBytes, 0)
            XCTAssertEqual(ledger.statistics.retiredCPUBytes + ledger.statistics.retiredGPUBytes, 0)
            withExtendedLifetime((canvas, host, model)) {}
        }
    }

    func testCanvasTraceBufferKeepsOrderedImmutableFrameEvidenceAndSignalsOverflow() {
        let canvas = UUID(), ip = UUID(), settled = UUID()
        var buffer = CanvasDiagnosticBuffer(limit: 3)
        buffer.append("canvas.install", at: 10, canvas: canvas, frame: ip)
        buffer.append("canvas.raw-draw", at: 13, canvas: canvas, frame: ip, began: 12)
        buffer.append("canvas.ack", at: 15, frame: ip, current: settled, reason: .replacedFrame)
        XCTAssertEqual(buffer.rows.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(buffer.rows[1].began, 12)
        XCTAssertEqual(buffer.rows[2].frame, ip)
        XCTAssertEqual(buffer.rows[2].current, settled)
        XCTAssertEqual(buffer.rows[2].reason, .replacedFrame)
        buffer.append("canvas.detach", at: 16, canvas: canvas)
        XCTAssertTrue(buffer.overflow)
        XCTAssertEqual(buffer.rows.count, 3)
        buffer.sealed = true
        buffer.append("canvas.install", at: 17, canvas: canvas, frame: settled)
        XCTAssertEqual(buffer.rows.count, 3)
    }
    func testLateNativeEventKeepsItsTimestampAndAgeInsteadOfBecomingProgrammatic() {
        let direct = EditingPreviewInput.classified(control: "EV", phase: "change", committedAt: 1_000_000_000,
            eventAt: 900_000_000, nativeEvent: true)
        let aged = EditingPreviewInput.classified(control: "EV", phase: "change", committedAt: 1_000_000_000,
            eventAt: 100_000_000, nativeEvent: true)
        XCTAssertEqual(direct.association, .direct); XCTAssertEqual(direct.origin, .nativeAction)
        XCTAssertEqual(aged.association, .aged); XCTAssertEqual(aged.origin, .nativeAction)
        XCTAssertEqual(aged.eventAt, 100_000_000); XCTAssertEqual(aged.eventAgeNanoseconds, 900_000_000)
    }
    func testProgrammaticEntryIgnoresEvenAFreshSuppliedNativeTimestamp() {
        let input = EditingPreviewInput.classified(control: "fixture", phase: "discrete", committedAt: 1_000,
            eventAt: 999, nativeEvent: false)
        XCTAssertEqual(input.origin, .programmatic); XCTAssertEqual(input.association, .programmatic)
        XCTAssertNil(input.eventAt); XCTAssertNil(input.eventAgeNanoseconds)
    }
    func testUnattributedNativeActionKeepsNativeOriginAndAnExplicitReason() {
        let cases: [(UInt64?, Bool, EditingPreviewInput.Association)] = [
            (nil, true, .missingEvent), (1_001, true, .futureTimestamp), (999, false, .unsupportedEvent)
        ]
        for (timestamp, relevant, expected) in cases {
            let input = EditingPreviewInput.classified(control: "EV", phase: "change", committedAt: 1_000,
                eventAt: timestamp, nativeEvent: true, relevantEvent: relevant)
            XCTAssertEqual(input.origin, .nativeAction); XCTAssertEqual(input.association, expected)
            XCTAssertNil(input.eventAt)
        }
    }
    func testSettledFrameInheritsOriginalOperationAndTimestampWithoutSamplingAnotherEvent() {
        let gesture = UUID()
        let original = EditingPreviewInput.classified(control: "EV", phase: "change", committedAt: 1_000_000_000,
            eventAt: 100_000_000, nativeEvent: true, gestureID: gesture)
        let release = EditingPreviewInput.classified(control: "EV", phase: "end", committedAt: 2_000_000_000,
            eventAt: 1_999_000_000, nativeEvent: true, gestureID: gesture)
        let settled = original.settling(after: release)
        XCTAssertEqual(settled.id, original.id); XCTAssertEqual(settled.eventAt, original.eventAt)
        XCTAssertEqual(settled.committedAt, original.committedAt); XCTAssertEqual(settled.association, .aged)
        XCTAssertEqual(settled.gestureID, gesture); XCTAssertEqual(settled.phase, "settled")
        XCTAssertEqual(settled.settleTriggeredAt, release.committedAt); XCTAssertEqual(settled.releaseEventAt, release.eventAt)
        let programmatic = EditingPreviewInput.classified(control: "fixture", phase: "change", committedAt: 1_000,
            eventAt: nil, nativeEvent: false).settling(after: release)
        XCTAssertEqual(programmatic.origin, .programmatic); XCTAssertNil(programmatic.eventAt); XCTAssertNil(programmatic.releaseEventAt)
    }
    func testTerminalWatermarkRejectsArbitrarilyLateDuplicatesWhileNoRenderHistoryStaysBounded() {
        var ledger = EditingPreviewTerminalLedger(capacity: 8)
        for revision in 1...5_000 { XCTAssertTrue(ledger.acceptRenderedTerminal(revision: UInt64(revision))) }
        XCTAssertFalse(ledger.acceptRenderedTerminal(revision: 1)); XCTAssertFalse(ledger.acceptRenderedTerminal(revision: 5_000))
        for _ in 0..<5_000 { XCTAssertTrue(ledger.acceptNoRender(operation: UUID(), quality: .settled, outcome: "overlay-only")) }
        XCTAssertEqual(ledger.retainedOperationCount, 8)
        let same = UUID()
        XCTAssertTrue(ledger.acceptNoRender(operation: same, quality: .settled, outcome: "deduplicated"))
        XCTAssertFalse(ledger.acceptNoRender(operation: same, quality: .settled, outcome: "deduplicated"))
        XCTAssertTrue(ledger.acceptRenderedTerminal(revision: 5_001), "No-render diagnostics never suppress a real render ending")
    }
    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 { if await condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Diagnostic fixture timed out")
    }
    private func intent(exposure: Double = 0) throws -> EditingPreviewIntent {
        let source = EditingSourceSnapshot(projectID: "fixture", assetID: "A", contentSHA256: String(repeating: "a", count: 64),
            byteCount: 1, admissionFingerprint: "fixture", sourceLocation: URL(fileURLWithPath: "/fixture/A.raw"))
        var recipe = DevelopmentRecipe(); recipe.exposureEV = exposure
        return try .init(source: .raw(source), recipe: recipe, quality: .settled)
    }
    @MainActor func testSupersededRenderHasOneTerminalEvenAfterLateErrorAndAcceptedFrameCanDrawOnce() async throws {
        let backend = ControllablePreviewBackend(hold: true)
        // Use a separate held pane so callback timing stays explicit, without native rendering or latency claims.
        let held = EditingPreviewPane(role: .primary, backend: backend)
        var events: [EditingPreviewDiagnosticEvent] = []
        held.diagnosticSink = { events.append($0) }
        let first = EditingPreviewInput.capture(control: "fixture", phase: "change")
        let next = EditingPreviewInput.capture(control: "fixture", phase: "change")
        held.submit(try intent(), input: first); try await wait { await backend.requests.count == 1 }
        held.submit(try intent(exposure: 1), input: next); try await wait { await backend.requests.count == 2 }
        await backend.finish(1); try await wait { held.frame != nil }
        await backend.finish(0, error: NSError(domain: "LateFixture", code: 1)); await Task.yield()
        XCTAssertEqual(events.filter { $0.operationID == first.id }.map(\.outcome), ["superseded"])
        XCTAssertEqual(events.filter { $0.operationID == next.id }.map(\.outcome), ["accepted"])
        let frame = try XCTUnwrap(held.frame)
        let event = ImageFrameDrawEvent(frameID: frame.id, drawBeganUptimeNanoseconds: 1, drawReturnedUptimeNanoseconds: 2,
            imagePixelWidth: 120, imagePixelHeight: 80)
        XCTAssertTrue(held.didDraw(event)); XCTAssertFalse(held.didDraw(event))
        held.reset(); await held.joinRetirement()
        XCTAssertEqual(events.filter { $0.operationID == next.id }.map(\.outcome), ["accepted", "drawn"])
        await held.shutdown()
    }
    @MainActor func testDedupAndOverlayOnlyOperationsAreCountedWithoutFakePixelFrames() async throws {
        let backend = ControllablePreviewBackend()
        let active = EditingPreviewPane(role: .primary, backend: backend)
        var events: [EditingPreviewDiagnosticEvent] = []
        active.diagnosticSink = { events.append($0) }
        active.submit(try intent(), input: .capture(control: "fixture", phase: "discrete"))
        try await wait { active.frame != nil }
        let duplicate = EditingPreviewInput.capture(control: "fixture", phase: "discrete")
        active.submit(try intent(), input: duplicate); active.submit(try intent(), input: duplicate)
        let overlay = EditingPreviewInput.capture(control: "crop", phase: "change")
        active.submit(try intent(), input: overlay, duplicateReason: "overlay-only")
        XCTAssertEqual(events.filter { $0.operationID == duplicate.id }.map(\.outcome), ["deduplicated"])
        XCTAssertEqual(events.filter { $0.operationID == overlay.id }.map(\.outcome), ["overlay-only"])
        let renderCount = await backend.requests.count; XCTAssertEqual(renderCount, 1)
        await active.shutdown()
    }
    @MainActor func testContextCancellationIsCountedOnceWhenBackendLaterReportsClosed() async throws {
        let backend = ControllablePreviewBackend(hold: true)
        let active = EditingPreviewPane(role: .comparison, backend: backend)
        var events: [EditingPreviewDiagnosticEvent] = []
        active.diagnosticSink = { events.append($0) }
        let input = EditingPreviewInput.capture(control: "fixture", phase: "discrete")
        active.submit(try intent(), input: input); try await wait { await backend.requests.count == 1 }
        active.reset(); await backend.finish(0, error: DevelopmentPreviewError.closed); await active.joinRetirement()
        XCTAssertEqual(events.map(\.outcome), ["cancelled"])
        XCTAssertEqual(events.first?.operationID, input.id)
        await active.shutdown()
    }
    @MainActor func testCropNumberAndAspectPropagateExplicitNativeFlagWhileProgrammaticDefaultsStayProgrammatic() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let controller = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults,
            previewBackend: ControllablePreviewBackend())
        var events: [EditingPreviewDiagnosticEvent] = []
        controller.previews.primary.diagnosticSink = { events.append($0) }
        controller.focus(f.assets[0]); try await wait { controller.preview != nil }
        controller.setCropValue(\.width, value: 0.8)
        try await wait { controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
        XCTAssertEqual(events.last { $0.control == "crop-number" }?.inputOrigin, .programmatic)
        controller.setCropValue(\.height, value: 0.8, nativeEvent: true)
        try await wait { controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
        XCTAssertEqual(events.last { $0.control == "crop-number" }?.inputOrigin, .nativeAction)
        controller.applyCropAspect(1)
        try await wait { controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
        XCTAssertEqual(events.last { $0.control == "crop-aspect" }?.inputOrigin, .programmatic)
        controller.applyCropAspect(16.0 / 9, nativeEvent: true)
        try await wait { controller.previews.primary.frame?.revision == controller.previews.primary.currentRevision }
        XCTAssertEqual(events.last { $0.control == "crop-aspect" }?.inputOrigin, .nativeAction)
        // Only declaration/classification is under test; no timestamp or synthetic operation is a native latency sample.
        await controller.shutdown()
    }
    @MainActor func testControllerSettledDiagnosticRetainsLatestParameterOperationID() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let controller = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults,
            previewBackend: ControllablePreviewBackend())
        var events: [EditingPreviewDiagnosticEvent] = []
        controller.previews.primary.diagnosticSink = { events.append($0) }
        controller.focus(f.assets[0]); try await wait { controller.preview != nil }
        controller.previewInteractionChanged("exposure", active: true)
        controller.setRecipe { $0.exposureEV = 0.4 }
        try await wait { events.contains { $0.quality == .interactive && $0.outcome == "accepted" } }
        let parameterID = try XCTUnwrap(events.last { $0.quality == .interactive && $0.outcome == "accepted" }?.operationID)
        controller.previewInteractionChanged("exposure", active: false)
        try await wait { events.contains { $0.operationID == parameterID && $0.quality == .settled && $0.outcome == "accepted" } }
        await controller.shutdown()
    }
}

// The SwiftUI tree and retained representable own only this model; its image slot is weak.
@MainActor private final class ManagedOwnerHostModel: ObservableObject {
    @Published var visible = true
    weak var image: NSImage?
    weak var canvas: ImageCanvas?
    let store: PreviewQAMainPresentationWitness.Store
    let frameID = UUID()
    var dismantledCount = 0
    var drawnFrame: UUID?
    init(store: PreviewQAMainPresentationWitness.Store) { self.store = store }
}
@MainActor private struct ManagedOwnerHost: View {
    @ObservedObject var model: ManagedOwnerHostModel
    var body: some View {
        if model.visible { ManagedOwnerCanvas(model: model) } else { Color.clear }
    }
}
@MainActor private struct ManagedOwnerCanvas: NSViewRepresentable {
    let model: ManagedOwnerHostModel
    func makeNSView(context: Context) -> ImageCanvas {
        let canvas = ImageCanvas()
        canvas.qaMainOwnerStoreForTesting = model.store
        model.canvas = canvas
        return canvas
    }
    func updateNSView(_ canvas: ImageCanvas, context: Context) {
        ZoomableImageView(image: nil, actualPixels: false, transform: .constant(.init()),
            frameID: model.frameID, onCanvasDiagnostic: { event in
                switch event {
                case .dismantled: model.dismantledCount += 1
                case let .drawn(_, frame, _, _): model.drawnFrame = frame
                default: break
                }
            }).borrowingImage(model.image).updateCanvas(canvas)
    }
    static func dismantleNSView(_ view: ImageCanvas, coordinator: ()) {
        ZoomableImageView.dismantleNSView(view, coordinator: ())
    }
}
