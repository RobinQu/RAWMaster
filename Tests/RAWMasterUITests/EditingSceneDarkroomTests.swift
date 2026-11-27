import AppKit
import Foundation
import ImageIO
import Metal
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class EditingSceneDarkroomTests: XCTestCase {
    @MainActor func testOptInRealRAWOpenEditUndoSaveReopenAndPresentResidentFrame() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Use fixed snow.ARW") }
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeScene-\(UUID().uuidString)")
        let rawDirectory = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = rawDirectory.appendingPathComponent("snow.ARW")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: raw)
        let db = root.appendingPathComponent("catalog.sqlite")
        let asset = try NativePresentedCanvasTests.register(source: raw, library: db)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let model = AppModel(libraryURL: db, defaults: defaults), editing = try XCTUnwrap(model.editing)
        let window = NSWindow(contentRect: CGRect(x: 30, y: 50, width: 1240, height: 660), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ZStack(alignment: .topTrailing) {
            EditingImageCanvas(editing: editing).environmentObject(model)
            NativeEditingInspector(editing: editing).frame(width: EditingLayout.sidebarWidth)
        })
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            editing.isPresented = true; editing.focus(asset)
            try await wait("loaded ARW") { editing.sourceReady && !editing.loading }
            XCTAssertEqual(editing.work?.source.contentSHA256, "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2")
            let legacy = editing.recipe, ticket = try XCTUnwrap(editing.sceneTicket)
            editing.enterSceneDraft(ticket: ticket)
            try await wait("scene enters and preview finishes") {
                (editing.recipe.sceneGraph != nil && editing.sceneFrame != nil && !editing.scenePreviewBusy)
                    || (!editing.sceneStarting && (editing.scenePreviewError != nil || editing.message != nil))
            }
            XCTAssertNil(editing.scenePreviewError)
            XCTAssertNil(editing.message)
            let first = try XCTUnwrap(editing.recipe.sceneGraph)
            XCTAssertEqual(editing.versions.count, 1, "entering only creates a draft")
            let view = try await waitForCanvas(in: host)
            try await wait("drawable presented") { view.presentedFrameID != nil }
            let layerFormat = try XCTUnwrap(view.photoLayer?.pixelFormat)
            XCTAssertEqual(layerFormat, .rgba16Float)
            let before = try EditingFingerprint.of(editing.recipe)
            editing.setSceneViewingHDR(false)
            try await wait("SDR derivative drawable and compositor mode") {
                editing.sceneFrame?.target == .sdr709 && view.presentedFrameID == editing.sceneFrame?.id &&
                    view.presentedFrameID != nil && view.photoLayer?.wantsExtendedDynamicRangeContent == false
            }
            XCTAssertEqual(view.photoLayer?.colorspace?.name, CGColorSpace.extendedLinearSRGB)
            XCTAssertEqual(try EditingFingerprint.of(editing.recipe), before)
            XCTAssertFalse(view.photoLayer?.wantsExtendedDynamicRangeContent ?? true)
            let node = try XCTUnwrap(first.graph.nodes.first?.id)
            editing.setSceneExposure(8, node: node, ticket: ticket)
            XCTAssertEqual(editing.recipe.sceneGraph, first, "stale legacy control cannot edit the scene graph")
            editing.setSceneExposure(2, node: node, ticket: try XCTUnwrap(editing.sceneTicket))
            XCTAssertNotEqual(editing.recipe.sceneGraph, first)
            XCTAssertTrue(editing.stepSceneHistory(redo: false))
            XCTAssertEqual(editing.recipe.sceneGraph, first)
            XCTAssertTrue(editing.stepSceneHistory(redo: false)); XCTAssertEqual(editing.recipe, legacy)
            XCTAssertTrue(editing.stepSceneHistory(redo: true)); XCTAssertEqual(editing.recipe.sceneGraph, first)
            XCTAssertTrue(editing.stepSceneHistory(redo: true)); XCTAssertNotEqual(editing.recipe.sceneGraph, first)
            editing.setSceneViewingHDR(false)
            try await wait("latest frame can be saved") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            if let report = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DARKROOM_REPORT"] {
                try await measureWarmFIT(editing, node: node, view: try await waitForCanvas(in: host), report: report)
            }
            let scopesRecipe = editing.recipe
            let scopesFrame = editing.sceneFrame?.id
            editing.setSceneScopesOpen(true)
            try await wait("resident RAW scopes") { editing.sceneScopes.report != nil || editing.sceneScopes.failure != nil }
            let report = try XCTUnwrap(editing.sceneScopes.report, editing.sceneScopes.failure ?? "missing scopes")
            XCTAssertTrue(report.canMeasureSensor); XCTAssertTrue(report.canMeasureTarget)
            editing.sceneScopes.toggle(.sensor, headroom: Float(editing.sceneHeadroom))
            editing.sceneScopes.startPick()
            let sampler = try await waitForCanvas(in: host)
            try await wait("photo sampler armed") { sampler.pickedPoint != nil }
            let frameSize = try XCTUnwrap(editing.sceneFrame?.nativeSize)
            let imageRect = ImageViewportGeometry.imageRect(pixelSize: frameSize, viewport: sampler.bounds.size,
                transform: .init(), backingScale: window.backingScaleFactor, fitInsets: EditingLayout.fitInsets)
            let hit = sampler.convert(NSPoint(x: imageRect.minX + imageRect.width*0.35, y: imageRect.minY + imageRect.height*0.6), to:nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown, location:hit, modifierFlags:[], timestamp:0,
                windowNumber:window.windowNumber, context:nil, eventNumber:1, clickCount:1, pressure:1))
            sampler.mouseDown(with:event)
            let selected = try XCTUnwrap(editing.sceneScopes.point)
            XCTAssertEqual(selected.x,0.35,accuracy:1e-3); XCTAssertEqual(selected.y,0.6,accuracy:1e-3)
            XCTAssertFalse(editing.sceneScopes.picking)
            XCTAssertTrue(editing.sceneScopes.escape()); XCTAssertTrue(editing.sceneScopes.overlays.isEmpty)
            XCTAssertEqual(editing.recipe, scopesRecipe); XCTAssertEqual(editing.sceneFrame?.id, scopesFrame)
            editing.setSceneScopesOpen(false)
            let current = editing.recipe
            editing.saveDevelopment()
            try await wait("saved candidate") { !editing.saving && editing.versions.contains { $0.recipe == current } }
            let saved = try XCTUnwrap(editing.versions.first { $0.recipe == current })
            XCTAssertNil(saved.artifact, "a display proxy is not the scene master")
            let store = try LibraryStore(databaseURL: db)
            let reopened = try store.editingVersion(id: saved.id)
            XCTAssertEqual(reopened.recipe, current)
            let frozen = try store.freezeSceneDelivery(versionID: saved.id, format: .avif10)
            XCTAssertEqual(try frozen.program.fingerprint(), try EditingFingerprint.of(current))
            try await wait("live state reconciled with the saved parent") {
                (try? store.photoWork(id: saved.workID).liveParentVersionID) == saved.id
            }
            editing.focus(nil)
            try await wait("focus change revokes old frame") { editing.sceneFrame == nil && editing.sceneTicket == nil }
            model.workbenchExportContext = .selection(ids: [asset.id])
            model.activateWorkflow(.export)
            let preview = try await model.workbenchExportPreview(for: asset, maxPixel: 600)
            XCTAssertEqual(preview.image.width, 400); XCTAssertEqual(preview.image.height, 600)
            let destination = root.appendingPathComponent("delivery")
            model.submitWorkbenchPhotoDelivery(directory: destination, naming: "{name}-{index}",
                configuration: .init(format: .jpeg8, maximumLongEdge: 600), ids: [asset.id], collision: "rename")
            let batch = try XCTUnwrap(model.workbenchPhotoDelivery?.id)
            await model.workbenchPhotoDeliveryTask?.value
            let completed = try XCTUnwrap(model.workbenchPhotoDelivery)
            XCTAssertEqual(completed.files.count, 1, completed.message ?? "missing result")
            let file = try XCTUnwrap(completed.files.first)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(image) as String?, "public.jpeg")
            let facts = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            XCTAssertEqual(facts[kCGImagePropertyPixelHeight] as? Int, 600)
            let queue = WorkbenchDeliveryCatalog(database: db)
            let body = try await queue.input(batchID: batch.uuidString.lowercased(), ordinal: 1)
            XCTAssertEqual(body.version.id, saved.id)
            XCTAssertEqual(body.version.recipe, current)
            let receipt = try await queue.receipt(batchID: batch.uuidString.lowercased())
            XCTAssertEqual(receipt.items.items.first?.state, .delivered)
            await editing.shutdown()
        } catch { await editing.shutdown(); throw error }
    }

    @MainActor func testNativeFloatingLayerCanPresentBothProfilesWithoutChangingTexture() async throws {
        _ = NSApplication.shared
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 2, mipmapped: false)
        d.storageMode = .shared; d.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: d))
        let values = [SIMD4<Float>(2, 1.4, 0.5, 1), .init(0.1, 0.2, 0.3, 1), .init(1, 1, 1, 1), .init(0, 0, 0, 1)]
        values.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 32)
        }
        let window = NSWindow(contentRect: CGRect(x: 10, y: 60, width: 160, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SceneMetalView()
        window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let hdr = DevelopmentScenePreviewFrameV1(id: UUID(), texture: texture, target: .hdr2020, nativeSize: .init(width: 2, height: 2), window: nil)
        let size = view.bounds.size
        view.submit(hdr, target: .hdr2020, requestHDR: true, transform: .init(), insets: .zero)
        try await wait("floating HDR drawable") { view.presentedFrameID == hdr.id }
        XCTAssertTrue(view.photoLayer?.wantsExtendedDynamicRangeContent == true)
        XCTAssertEqual(view.photoLayer?.colorspace?.name, CGColorSpace.extendedLinearITUR_2020)
        XCTAssertEqual(view.bounds.size, size)
        view.submit(nil, target: .sdr709, requestHDR: true, transform: .init(), insets: .zero)
        XCTAssertNil(view.presentedFrameID); XCTAssertNil(view.photoLayer, "the previous layer may not be relabelled SDR")
    }

    @MainActor private func measureWarmFIT(_ editing: EditingController, node: UUID, view: SceneMetalView, report: String) async throws {
        let oldTarget = editing.sceneRequestedHDR
        editing.setSceneViewingHDR(false)
        var samples: [Double] = []
        for index in 0..<35 {
            let id = editing.sceneFrame?.id, ticket = try XCTUnwrap(editing.sceneTicket)
            let start = DispatchTime.now().uptimeNanoseconds
            editing.setSceneExposure(index % 2 == 0 ? 2.25 : 1.75, node: node, ticket: ticket)
            let deadline = ContinuousClock.now + .seconds(5)
            while editing.scenePreviewBusy || editing.sceneFrame?.id == id || editing.sceneFrame?.id == nil || view.presentedFrameID != editing.sceneFrame?.id {
                guard ContinuousClock.now < deadline else { throw LibraryError.invalid("Timed out: warm scene drawable") }
                try await Task.sleep(for: .milliseconds(2))
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            if index >= 5 { samples.append(elapsed) }
        }
        let sorted = samples.sorted(), p50 = (sorted[14] + sorted[15]) / 2, p95 = sorted[28]
        let output: [String: Any] = ["scope": "live scene exposure command to joined AppKit Metal drawable; warm FIT SDR derivative, no HID or photon readback",
            "window": [view.bounds.width, view.bounds.height], "backingScale": view.window?.backingScaleFactor ?? 0,
            "sourceSHA256": editing.work?.source.contentSHA256 ?? "unknown", "currentHeadroom": editing.sceneHeadroom,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "device": editing.sceneFrame?.texture.device.name ?? "unknown",
            "p50Ms": p50, "p95Ms": p95, "samplesMs": samples]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: [.withoutOverwriting])
        editing.setSceneViewingHDR(oldTarget)
        XCTAssertLessThanOrEqual(p50, 25.92)
        XCTAssertLessThanOrEqual(p95, 210.23)
    }

    @MainActor private func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LibraryError.invalid("Timed out: " + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private func waitForCanvas(in host: NSView) async throws -> SceneMetalView {
        func find(_ view: NSView) -> SceneMetalView? {
            if let scene = view as? SceneMetalView { return scene }
            return view.subviews.lazy.compactMap(find).first
        }
        try await wait("native scene canvas") { find(host) != nil }
        return try XCTUnwrap(find(host))
    }
}
