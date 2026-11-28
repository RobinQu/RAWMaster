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
    @MainActor func testWorkspaceNoticesStayWithThePhotoUntilIndividuallyDismissed() async throws {
        let fixture = try ProjectReviewUITests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate("Notices")
        let assets = try fixture.store.loadAssets()
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        let editing = try XCTUnwrap(model.editing)
        editing.isPresented = true; editing.focus(assets[0])
        editing.postNotice("已完成")
        let info = try XCTUnwrap(editing.activeNotice)
        XCTAssertEqual(info.duration, 3.5)
        editing.message = "无法应用"; editing.message = "无法应用"
        let error = try XCTUnwrap(editing.activeNotice)
        XCTAssertEqual(error.duration, 6)
        XCTAssertEqual(editing.photoNotices, [info, error])
        editing.dismissNotice(info.id)
        XCTAssertEqual(editing.activeNotice, error, "An old presenter must not dismiss its replacement")
        editing.focus(assets[1])
        XCTAssertNil(editing.activeNotice)
        editing.postNotice("后台结果已归档", for: assets[0].id)
        XCTAssertNil(editing.activeNotice)
        XCTAssertNil(editing.message)
        XCTAssertEqual(editing.activity.notices.last?.photoName, assets[0].filename)
        editing.focus(assets[0])
        XCTAssertNil(editing.activeNotice, "Returning to a photo must not replay a toast")
        XCTAssertEqual(editing.photoNotices.count, 3)
        editing.postNotice("现在可查看")
        let current = try XCTUnwrap(editing.activeNotice)
        editing.dismissNotice(current.id)
        XCTAssertNil(editing.activeNotice)
        let reopened = WorkbenchLibraryActivity(libraryURL: fixture.library,
            libraryID: try fixture.store.catalogLibraryIdentity(), defaults: fixture.defaults)
        XCTAssertEqual(reopened.notices, editing.photoNotices)
        let other = WorkbenchLibraryActivity(libraryURL: fixture.root.appendingPathComponent("other.sqlite"),
            libraryID: UUID().uuidString, defaults: fixture.defaults)
        XCTAssertTrue(other.notices.isEmpty)
        await editing.shutdown()
    }

    @MainActor private func fixtureVersions(model: AppModel, workID: String) throws -> [EditingVersion] {
        try XCTUnwrap(model.store).loadEditingVersions(workID: workID)
    }

    @MainActor func testOptIn60MPEditorAndPublishedBatchReceipts() async throws {
        try await verify60MPEditorAndPublishedBatchReceipts(photographic: false)
    }

    @MainActor func testOptIn60MPPhotographicPublishedBatchReceipts() async throws {
        let environment = ProcessInfo.processInfo.environment
        let repeats = Int(environment["RAWMASTER_SCENE_DELIVERY_PROFILE_REPEATS"] ?? "1") ?? 0
        guard (1...64).contains(repeats) else { return XCTFail("Profile repeats must be from 1 through 64") }
        try await verify60MPEditorAndPublishedBatchReceipts(photographic: true, repeats: repeats)
    }

    @MainActor private func verify60MPEditorAndPublishedBatchReceipts(photographic: Bool, repeats: Int = 1) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["RAWMASTER_SCENE_60MP_ARW"] else { throw XCTSkip("Requires the 9504×6336 Bayer fixture") }
        let useWGSL = environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() == "wgpu"
        let retained = environment["RAWMASTER_EDITOR_ACCEPTANCE_DIR"].map { path in
            let root = URL(fileURLWithPath: path)
            return photographic ? root.appendingPathComponent("photographic", isDirectory: true) : root
        }
        let directory = retained ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if retained == nil { try? FileManager.default.removeItem(at: directory) } }
        let db = directory.appendingPathComponent("library.sqlite")
        let asset = try NativePresentedCanvasTests.register(source: URL(fileURLWithPath: path), library: db)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "editor-" + asset.id))
        defer { defaults.removePersistentDomain(forName: "editor-" + asset.id) }
        let model = AppModel(libraryURL: db, defaults: defaults)
        let editing = try XCTUnwrap(model.editing)
        do {
            model.selectScope(.project, id: asset.projectID)
            model.select(asset); model.setMode(.single)
            model.openNativeEditing()
            try await wait("60 MP source") { editing.sourceReady && !editing.loading }
            XCTAssertEqual(editing.work?.source.contentSHA256, "7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89")
            editing.enterSceneDraft(ticket: try XCTUnwrap(editing.sceneTicket))
            try await wait("60 MP scene") { editing.sceneFrame != nil || (!editing.sceneStarting && editing.message != nil) }
            try await wait("60 MP rendered preview") { editing.sceneFrame?.execution != nil }
            XCTAssertTrue(editing.photoNotices.contains { $0.kind == .information })
            XCTAssertFalse(editing.photoNotices.contains { $0.kind == .error }, editing.message ?? "")
            if photographic {
                // Match the 60 MP component's coverage → corrector → ordered Layer workload.
                typealias Graph = DevelopmentSceneGraphV1
                let mask = Graph.Node(name: "Snow to dusk", operation: .linearCoverage(start: .init(0.15, 0), end: .init(0.85, 0)))
                let lift = Graph.Node(name: "Lift", operation: .corrector(image: .input, mask: mask.id, exposureEV: 0.5,
                    curve: [], strength: 1, enabled: true))
                let layer = Graph.Node(name: "Layer", operation: .layer(base: .input,
                    layers: [.init(.node(lift.id), weight: 0.5)], enabled: true))
                let template = try SceneWorkflowTemplate(name: "60 MP scene baseline", kind: .whole,
                    scope: .init(nodes: [lift, layer, mask], output: .node(layer.id)))
                XCTAssertTrue(editing.applySceneWorkflowTemplate(template, ticket: try XCTUnwrap(editing.sceneGraphTicket)))
                XCTAssertEqual(editing.recipe.sceneGraph?.graph.nodes.count, 3)
            }
            let node = try XCTUnwrap(editing.recipe.sceneGraph?.graph.nodes.first?.id)
            editing.setSceneExposure(photographic ? 1 : 0.5, node: node, ticket: try XCTUnwrap(editing.sceneTicket))
            try await wait("60 MP exposure dispatch") {
                !editing.scenePreviewBusy && (editing.sceneFrame?.execution?.dispatches ?? 0) > 0
            }
            if photographic {
                editing.beginDevelopmentInterface()
                try await wait("60 MP photographic controls") { editing.developmentContext != nil }
                let session = editing.developmentSession
                let light = DevelopmentLightV3(enabled: true, exposure: 0.25)
                XCTAssertTrue(try session.apply(.setParameters(.light(light)),
                    event: .init(context: try XCTUnwrap(editing.developmentContext), control: .init(group: .light, name: "曝光"))))
                let color = DevelopmentColorV3(enabled: true, saturation: 0.32, vibrance: -0.15)
                XCTAssertTrue(try session.apply(.setParameters(.color(color)),
                    event: .init(context: try XCTUnwrap(editing.developmentContext), control: .init(group: .color, name: "饱和度"))))
                XCTAssertEqual(editing.recipe.sceneGraph?.photographic?.light.exposure, 0.25)
                XCTAssertEqual(editing.recipe.sceneGraph?.photographic?.color.saturation, 0.32)
                XCTAssertEqual(editing.recipe.sceneGraph?.photographic?.color.vibrance, -0.15)
                try await wait("60 MP photographic preview") {
                    !editing.scenePreviewBusy && editing.sceneFrame?.execution?.photographicEngine != nil
                }
            }
            let captured = editing.recipe
            editing.createSceneSnapshot(ticket: try XCTUnwrap(editing.sceneTicket))
            let snapshot = try XCTUnwrap(editing.sceneSnapshots.first)
            editing.setSceneExposure(0.75, node: node, ticket: try XCTUnwrap(editing.sceneTicket))
            editing.restoreSceneSnapshot(snapshot.id, ticket: try XCTUnwrap(editing.sceneTicket))
            XCTAssertEqual(editing.recipe, captured)
            XCTAssertTrue(editing.sceneCanUndo)
            editing.setSceneScopesOpen(true)
            try await wait("60 MP scope receipt") { editing.sceneScopes.report?.execution != nil }
            editing.setSceneScopesOpen(false)
            let recipe = editing.recipe
            let workID = try XCTUnwrap(editing.work?.id)
            let before = try fixtureVersions(model: model, workID: workID)
            XCTAssertEqual(before.count, 1)
            let original = try XCTUnwrap(before.first)
            let frozen = try original.freezingSceneAppearance(recipe)
            XCTAssertTrue(frozen.isLiveSceneDelivery)
            XCTAssertEqual(frozen.parentVersionID, original.id)
            XCTAssertNotEqual(frozen.id, original.id)
            model.activateWorkflow(.export)
            var deliveries: [(batchID: String, file: URL)] = []
            let deliveryRoot = directory.appendingPathComponent("delivery", isDirectory: true)
            let memoryDevice = repeats > 1 ? MTLCreateSystemDefaultDevice() : nil
            func memoryCheckpoint() -> [String: UInt64] {
                var bytes: [String: UInt64] = [:]
                if let memoryDevice { bytes["metalAllocatedBytes"] = UInt64(memoryDevice.currentAllocatedSize) }
                if let footprint = SceneDeliveryTrace.physicalFootprint() { bytes["processPhysFootprintBytes"] = footprint }
                return bytes
            }
            var memoryCheckpoints = repeats > 1 ? [memoryCheckpoint()] : []
            for run in 0..<repeats {
                let destination = repeats == 1 ? deliveryRoot : deliveryRoot.appendingPathComponent("run-\(run)", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for format in [PhotoRenderFormat.avif10, .jpeg8] {
                    let review = format == .avif10 ? try await model.reviewWorkbenchPQ([asset]) : nil
                    if let review {
                        XCTAssertNil(review.lines.first?.reason, "Saved parent \(String(describing: editing.draftParentID)); selected \(String(describing: editing.selectedVersionID))")
                    }
                    model.submitWorkbenchPhotoDelivery(directory: destination, naming: "{name}",
                        configuration: .init(format: format, jpegQuality: 0.95), ids: [asset.id], collision: "rename", pqReview: review)
                    let id = try XCTUnwrap(model.workbenchPhotoDelivery?.id)
                    await model.workbenchPhotoDeliveryTask?.value
                    let completed = try XCTUnwrap(model.workbenchPhotoDelivery)
                    let file = try XCTUnwrap(completed.files.first, completed.message ?? "")
                    deliveries.append((id.uuidString.lowercased(), file))
                }
                if repeats > 1 { memoryCheckpoints.append(memoryCheckpoint()) }
            }
            try await wait("live HDR persisted") {
                (try? model.store?.photoWork(id: workID).liveRecipe) == recipe
            }
            model.activateWorkflow(.library)
            model.setMode(.grid)
            let gridReview = try await model.reviewWorkbenchPQ([asset])
            XCTAssertTrue(gridReview.canSubmit)
            XCTAssertEqual(gridReview.lines.first?.version, frozen.id)
            XCTAssertEqual(try fixtureVersions(model: model, workID: workID).map(\.id), [original.id])
            XCTAssertEqual(try XCTUnwrap(model.store).photoWork(id: workID).adoptedVersionID, original.id)
            await model.closeLibraryReads()
            await editing.shutdown()
            await model.editingServices?.shutdown()
            model.releaseLibraryConnections()
            if repeats > 1 {
                memoryCheckpoints.append(memoryCheckpoint())
                try JSONEncoder().encode(memoryCheckpoints).write(to: directory.appendingPathComponent("memory-checkpoints.json"))
            }

            let queue = WorkbenchDeliveryCatalog(database: db)
            for (batchID, file) in deliveries {
                let receipt = try await queue.receipt(batchID: batchID)
                XCTAssertEqual(receipt.batch.phase, .done)
                let item = try XCTUnwrap(receipt.items.items.first)
                let execution = try XCTUnwrap(item.sceneExecution)
                XCTAssertEqual(item.sha256, try FileSafety.hash(file))
                XCTAssertEqual(item.state, .delivered)
                XCTAssertGreaterThan(execution.tiles, 1)
                XCTAssertGreaterThan(execution.dispatches, 0)
                XCTAssertLessThanOrEqual(execution.peakBytes, execution.budgetBytes)
                if photographic {
                    XCTAssertEqual(execution.backend, .mixed)
                    XCTAssertEqual(execution.photographicEngine, "scene-photographic-v1-f32-metal")
                    XCTAssertEqual(execution.dagBackend, useWGSL ? .wgpu : .rust)
                    XCTAssertNil(execution.fallbackReason)
                } else {
                    XCTAssertNil(execution.photographicEngine)
                    XCTAssertNil(execution.dagBackend)
                    if useWGSL {
                        XCTAssertEqual(execution.backend, .wgpu)
                        XCTAssertNil(execution.fallbackReason)
                    }
                }
                let input = try await queue.input(batchID: batchID, ordinal: 1)
                XCTAssertEqual(input.version.id, frozen.id)
                XCTAssertEqual(input.version.recipe, recipe)
                XCTAssertTrue(input.version.isLiveSceneDelivery)
                let image = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
                let facts = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
                XCTAssertEqual(facts[kCGImagePropertyPixelWidth] as? Int, 9504)
                XCTAssertEqual(facts[kCGImagePropertyPixelHeight] as? Int, 6336)
            }
        } catch { await editing.shutdown(); throw error }
    }

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
            XCTAssertFalse(editing.photoNotices.contains { $0.kind == .error }, editing.message ?? "")
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
            editing.setSceneVisualizeHDR(true)
            try await wait("HDR zones drawn on the SDR preview surface") {
                editing.sceneVisualizeHDR && editing.sceneFrame?.id != nil && view.presentedFrameID == editing.sceneFrame?.id
            }
            XCTAssertFalse(editing.sceneRequestedHDR)
            XCTAssertEqual(try EditingFingerprint.of(editing.recipe), before)
            editing.setSceneViewingHDR(false)
            XCTAssertFalse(editing.sceneVisualizeHDR, "Reselecting the current derivative leaves visualization")
            let bandTicket = try XCTUnwrap(editing.sceneTicket)
            editing.previewSceneBandExposure(0.12, band: .third, ticket: bandTicket)
            XCTAssertEqual(editing.recipe.sceneGraph, first)
            XCTAssertEqual(try XCTUnwrap(editing.visibleSceneGraph?.output.exposure(in: .third)), 0.12, accuracy: 0.0001)
            let previousSnapshots = editing.sceneSnapshots
            editing.createSceneSnapshot(ticket: bandTicket)
            XCTAssertEqual(editing.sceneSnapshots, previousSnapshots)
            XCTAssertNotNil(editing.sceneModeBlockReason)
            XCTAssertFalse(editing.beginWorkbenchExport(asset: asset, admissionFingerprint: try XCTUnwrap(editing.work?.source.admissionFingerprint)))
            editing.cancelSceneBandPreview(bandTicket)
            XCTAssertEqual(editing.visibleSceneGraph, first)
            editing.previewSceneBandExposure(-0.08, band: .third, ticket: bandTicket)
            editing.setSceneBandExposure(-0.08, band: .third, ticket: bandTicket)
            let output = try XCTUnwrap(editing.recipe.sceneGraph?.output)
            XCTAssertEqual(output.exposure(in: .third), -0.08, accuracy: 0.0001)
            XCTAssertEqual(output.exposure(in: .second), 0)
            XCTAssertEqual(output.hdrHighlightLimitEV, first.output.hdrHighlightLimitEV)
            XCTAssertTrue(editing.stepSceneHistory(redo: false))
            XCTAssertEqual(editing.recipe.sceneGraph, first)
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
        let screen = NSScreen.screens.first { $0.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 }
        let origin = screen?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: CGRect(x: origin.x + 10, y: origin.y + 60, width: 160, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SceneMetalView()
        window.contentView = view; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        let hdr = DevelopmentScenePreviewFrameV1(id: UUID(), texture: texture, target: .hdr2020, nativeSize: .init(width: 2, height: 2), window: nil)
        let size = view.bounds.size
        let sdr = DevelopmentScenePreviewFrameV1(id: UUID(), texture: texture, target: .sdr709, nativeSize: hdr.nativeSize, window: nil)
        view.submit(sdr, target: .sdr709, requestHDR: true, transform: .init(), insets: .zero)
        try await wait("initial SDR drawable") { view.presentedFrameID == sdr.id }
        XCTAssertEqual(view.photoLayer?.wantsExtendedDynamicRangeContent, screen != nil)
        XCTAssertEqual(view.photoLayer?.colorspace?.name, CGColorSpace.extendedLinearSRGB)
        guard screen != nil else { return }
        view.submit(hdr, target: .hdr2020, requestHDR: true, transform: .init(), insets: .zero)
        try await wait("floating HDR drawable") { view.presentedFrameID == hdr.id }
        XCTAssertTrue(view.photoLayer?.wantsExtendedDynamicRangeContent == true)
        XCTAssertEqual(view.photoLayer?.colorspace?.name, CGColorSpace.extendedLinearITUR_2020)
        XCTAssertEqual(view.bounds.size, size)
        view.submit(nil, target: .sdr709, requestHDR: true, transform: .init(), insets: .zero)
        XCTAssertNil(view.presentedFrameID); XCTAssertNil(view.photoLayer, "the previous layer may not be relabelled SDR")
    }

    @MainActor func testOptInDisplayMoveReissuesTheResidentFrameForThePhysicalScreen() async throws {
        guard ProcessInfo.processInfo.environment["RAWMASTER_SCENE_PHYSICAL_DISPLAYS"] == "1",
              let first = NSScreen.screens.first, let second = NSScreen.screens.dropFirst().first else {
            throw XCTSkip("Use two connected displays and opt in to a physical window move")
        }
        let screenID: (NSScreen) throws -> UInt32 = { screen in
            try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        }
        let firstID = try screenID(first), secondID = try screenID(second)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let color = [SIMD4<Float>](repeating: .init(0.3, 0.4, 0.5, 1), count: 4)
        color.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 32)
        }
        let window = NSWindow(contentRect: CGRect(x: first.visibleFrame.midX - 100, y: first.visibleFrame.midY - 80,
            width: 200, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SceneMetalView()
        var display: SceneDisplayEnvironment?, presentedOnSecondBeforeDraw: UUID?
        view.changedDisplay = { next in
            if next?.id == secondID && display?.id != secondID { presentedOnSecondBeforeDraw = view.presentedFrameID }
            display = next
        }
        window.contentView = view
        window.orderFront(nil)
        defer { view.changedDisplay = nil; window.contentView = nil; window.close() }
        let frame = DevelopmentScenePreviewFrameV1(id: UUID(), texture: texture, target: .sdr709,
            nativeSize: .init(width: 2, height: 2), window: nil)
        view.submit(frame, target: .sdr709, requestHDR: false, transform: .init(), insets: .zero)
        try await wait("presented on first display") { display?.id == firstID && view.presentedFrameID == frame.id }
        window.setFrameOrigin(.init(x: second.visibleFrame.midX - 100, y: second.visibleFrame.midY - 80))
        try await wait("same frame presented on second display") { display?.id == secondID && view.presentedFrameID == frame.id }
        XCTAssertNil(presentedOnSecondBeforeDraw)
        XCTAssertEqual(display?.colorProfile, second.colorSpace?.iccProfileData)
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
