import AppKit
import Metal
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class EditingSceneGraphWindowTests: XCTestCase {
    @MainActor func testOptInEditableGraphWindowScopedCommandsAndSaveWhileMonitoring() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Use fixed snow.ARW") }
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let priorAccessibility = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(priorAccessibility, forAttribute: enhanced) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneGraphWindow-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = photos.appendingPathComponent("snow.ARW")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: fixture)
        let database = root.appendingPathComponent("library.sqlite")
        let asset = try NativePresentedCanvasTests.register(source: fixture, library: database)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let model = AppModel(libraryURL: database, defaults: defaults), editing = try XCTUnwrap(model.editing)
        let window = NSWindow(contentRect: CGRect(x: 50, y: 100, width: 1200, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = AppAppearance.native
        let host = NSHostingView(rootView: ZStack(alignment: .topTrailing) {
            EditingImageCanvas(editing: editing).environmentObject(model)
            NativeEditingInspector(editing: editing).frame(width: EditingLayout.sidebarWidth)
        })
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            let store = try LibraryStore(databaseURL: database)
            let source = try store.captureEditingSourceSnapshot(assetID: asset.id)
            editing.isPresented = true; editing.focus(asset, admissionFingerprint: source.admissionFingerprint)
            try await wait("original admitted") { editing.sourceReady && !editing.loading }
            try await press("editing.scene.mode.HDR", within: window)
            try await wait("one-click HDR and live frame") {
                editing.sceneGraphScope != nil && editing.sceneFrame != nil && !editing.scenePreviewBusy
            }
            XCTAssertNil(window.attachedSheet)
            let initialRecipe = editing.recipe, originalFrame = editing.sceneFrame?.id
            let originalPixels = try sample(XCTUnwrap(editing.sceneFrame).texture)
            let first = try XCTUnwrap(editing.sceneGraphState.single)
            let transform = editing.canvasCommand?.id
            try await press("editing.scene.graph.toggle", within: window)
            try await wait("nonmodal hover window") { editing.sceneGraphState.open && window.childWindows?.contains(where: { $0.title == "工作流 Graph" }) == true }
            let graphWindow = try XCTUnwrap(window.childWindows?.first(where: { $0.title == "工作流 Graph" }))
            XCTAssertTrue(graphWindow.styleMask.isSuperset(of: [.titled, .utilityWindow, .closable, .resizable, .fullSizeContentView]))
            XCTAssertTrue(graphWindow.titlebarAppearsTransparent)
            XCTAssertTrue(graphWindow.isMovable)
            XCTAssertFalse(graphWindow.isMovableByWindowBackground)
            XCTAssertEqual(graphWindow.standardWindowButton(.closeButton)?.isEnabled, true)
            XCTAssertTrue(graphWindow.canBecomeKey)
            XCTAssertLessThan(graphWindow.contentLayoutRect.height, graphWindow.frame.height)
            XCTAssertTrue(window.isVisible); XCTAssertTrue(graphWindow.isVisible); XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(editing.recipe, initialRecipe); XCTAssertEqual(editing.sceneFrame?.id, originalFrame)
            XCTAssertGreaterThanOrEqual(graphWindow.frame.width, 520)
            XCTAssertGreaterThanOrEqual(graphWindow.frame.height, 392)
            let geometry = graphWindow.frame
            editing.cropEditing = true
            try await wait("photo tool owns the canvas") { !graphWindow.isVisible }
            editing.cropEditing = false
            try await wait("same Graph returns after the tool") { graphWindow.isVisible }
            XCTAssertEqual(graphWindow.frame, geometry)
            XCTAssertTrue(editing.sceneGraphState.open)
            try await press("scene.graph.fit", within: graphWindow)
            editing.setSceneExposure(0.75, node: first, ticket: try XCTUnwrap(editing.sceneTicket))
            try await press("scene.graph.add.serial", within: graphWindow)
            let second = try XCTUnwrap(editing.sceneGraphState.single)
            XCTAssertNotEqual(first, second)
            editing.changeSceneGraphNode(second, ticket: try XCTUnwrap(editing.sceneGraphTicket)) { node in
                guard case let .corrector(image, mask, _, curve, strength, enabled) = node.operation else { return node }
                return .init(id: node.id, name: node.name, operation: .corrector(image: image, mask: mask,
                    exposureEV: 1.5, curve: curve, strength: strength, enabled: enabled))
            }
            try await wait("two-node final") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            let finalPixels = try sample(XCTUnwrap(editing.sceneFrame).texture)
            let serialRecipe = editing.recipe
            try await wait("separate photo and node panels") {
                let ids = Set(accessibleControls(in: window).map(\.identifier))
                return ids.isSuperset(of: ["editing.rail.photo", "editing.rail.parameters", "editing.scene.exposure"])
            }
            let undoAvailable = editing.sceneCanUndo
            try await press("scene.graph.node." + first.uuidString, within: graphWindow)
            try await press("scene.graph.solo", within: graphWindow)
            try await wait("first Solo frame") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            let firstSolo = try XCTUnwrap(editing.sceneFrame)
            let firstSoloPixels = try sample(firstSolo.texture)
            XCTAssertNotEqual(firstSoloPixels, originalPixels)
            XCTAssertNotEqual(firstSoloPixels, finalPixels)
            try await press("scene.graph.node." + second.uuidString, within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.preview, .solo(first))
            XCTAssertEqual(editing.sceneFrame?.id, firstSolo.id)
            try await press("scene.graph.solo", within: graphWindow)
            try await wait("second Solo frame") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            XCTAssertEqual(try sample(XCTUnwrap(editing.sceneFrame).texture), finalPixels, "Solo evaluates the selected node and its upstream")
            try await press("scene.graph.bypass", within: graphWindow)
            try await wait("all-grading bypass frame") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            XCTAssertEqual(editing.sceneGraphState.preview, .bypass)
            XCTAssertEqual(try sample(XCTUnwrap(editing.sceneFrame).texture), originalPixels)
            try await press("scene.graph.bypass", within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.preview, .final)
            XCTAssertEqual(editing.recipe, serialRecipe)
            XCTAssertEqual(editing.sceneCanUndo, undoAvailable)
            try await press("editing.scene.graph.ignore", within: window)
            XCTAssertEqual(editing.sceneGraphNode?.operation.sceneEnabled, false)
            XCTAssertTrue(editing.stepSceneHistory(redo: false))
            XCTAssertEqual(editing.recipe, serialRecipe)

            try await press("scene.graph.add.parallel", within: graphWindow)
            let parallel = try XCTUnwrap(editing.sceneGraphScope?.nodes.first { $0.operation.sceneTypeName == "Parallel" })
            try await press("scene.graph.node." + parallel.id.uuidString, within: graphWindow)
            try await wait("Parallel inspector") {
                let ids = Set(accessibleControls(in: window).map(\.identifier))
                return ids.contains("editing.scene.graph.weight.0") && !ids.contains("editing.scene.exposure")
            }
            if ProcessInfo.processInfo.environment["RAWMASTER_EDITOR_REPAIR_EVIDENCE"] != nil {
                try await wait("rendered photo and scopes for the capture") {
                    editing.sceneScopes.report != nil && editing.sceneFrame != nil && !editing.scenePreviewBusy
                }
                try recordWindow(window, named: "native-parallel")
            }
            try await press("scene.graph.port." + parallel.id.uuidString + ".base", within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.edge?.port, .base(parallel.id))
            try await wait("edge inspector") {
                let ids = Set(accessibleControls(in: window).map(\.identifier))
                return !ids.contains("editing.scene.graph.weight.0") && ids.contains("editing.rail.photo")
            }
            try await press("scene.graph.port." + parallel.id.uuidString + ".layer.0", within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.edge?.port, .layer(parallel.id, 0))
            editing.selectSceneNodes([parallel.id], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            try await press("scene.graph.add.layer", within: graphWindow)
            let layer = try XCTUnwrap(editing.sceneGraphScope?.nodes.first { $0.operation.sceneTypeName == "Layer" })
            editing.selectSceneNodes([layer.id], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            editing.addSceneLayer(layer.id, ticket: try XCTUnwrap(editing.sceneGraphTicket))
            try await press("scene.graph.organize", within: graphWindow)
            try await press("scene.graph.port." + layer.id.uuidString + ".layer.1", within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.edge?.port, .layer(layer.id, 1))
            for _ in 0..<3 { XCTAssertTrue(editing.stepSceneHistory(redo: false)) }
            XCTAssertEqual(editing.recipe, serialRecipe)

            let stale = try XCTUnwrap(editing.sceneGraphTicket)
            try await press("scene.graph.node." + first.uuidString, within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.single, first)
            let prior = editing.recipe
            editing.changeSceneGraphNode(second, ticket: stale) { .init(id: $0.id, name: "wrong", operation: $0.operation) }
            XCTAssertEqual(editing.recipe, prior, "delayed callbacks cannot write a deselected node")
            editing.selectSceneNodes([first, second], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            XCTAssertNil(editing.sceneGraphNode)
            editing.changeSceneGraphNode(first, ticket: try XCTUnwrap(editing.sceneGraphTicket)) { .init(id: $0.id, name: "broadcast", operation: $0.operation) }
            XCTAssertEqual(editing.recipe, prior)
            editing.groupSceneSelection(ticket: try XCTUnwrap(editing.sceneGraphTicket))
            let group = try XCTUnwrap(editing.sceneGraphState.single)
            editing.moveSceneGraphPath([group], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            XCTAssertEqual(editing.sceneGraphScope?.nodes.map(\.id), [first, second])
            editing.selectSceneNodes([first], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            try await press("scene.graph.bypass", within: graphWindow)
            XCTAssertEqual(editing.sceneGraphState.viewing, .init(target: .bypass), "bypass targets the photo input even inside a group")
            editing.monitorSceneGraph(.node(first), ticket: try XCTUnwrap(editing.sceneGraphTicket))
            try await wait("fenced group node preview") { editing.sceneGraphMonitorText != nil && editing.sceneFrame != nil && !editing.scenePreviewBusy }
            let monitored = editing.sceneFrame?.id
            let previewPixels = try sample(XCTUnwrap(editing.sceneFrame).texture)
            XCTAssertNotEqual(previewPixels, finalPixels, "intermediate and final are visibly different")
            editing.selectSceneNodes([second], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            XCTAssertEqual(editing.sceneFrame?.id, monitored, "selecting another node does not retarget monitor")
            try await verifyRepair(editing: editing, window: window, graphWindow: graphWindow)
            let edge = try XCTUnwrap(editing.sceneGraphScope?.imageEdges.first { $0.port == .image(second) })
            let graphBeforeDraft = editing.recipe
            editing.beginSceneConnection(edge, ticket: try XCTUnwrap(editing.sceneGraphTicket))
            editing.proposeSceneConnection(.node(second))
            XCTAssertNil(editing.sceneGraphState.connection?.candidate)
            XCTAssertTrue(editing.sceneGraphState.connection?.reason?.contains("回路") == true)
            editing.applySceneConnection()
            editing.saveDevelopment()
            XCTAssertTrue(editing.message?.contains("连接草稿") == true)
            XCTAssertFalse(editing.saving)
            XCTAssertFalse(editing.beginWorkbenchExport(asset: asset, admissionFingerprint: try XCTUnwrap(editing.work?.source.admissionFingerprint)))
            XCTAssertEqual(editing.recipe, graphBeforeDraft)
            try await press("scene.graph.connection.cancel", within: graphWindow)
            XCTAssertNil(editing.sceneGraphState.connection)
            if let report = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_GRAPH_MONITOR_REPORT"] {
                try await measureMonitor(editing, first: first, in: host, report: report)
            }
            // The normal 032 input freezes the complete DAG even while an intermediate node is monitored.
            let expected = try XCTUnwrap(editing.recipe.sceneGraph)
            XCTAssertTrue(editing.beginWorkbenchExport(asset: asset, admissionFingerprint: source.admissionFingerprint))
            let input = try await editing.workbenchExportInput(for: asset.id)
            let (work, version) = try XCTUnwrap(input)
            let frozen = try DevelopmentSceneDeliveryV1(work: work, version: version, format: .avif10)
            XCTAssertEqual(try frozen.program.fingerprint(), try EditingFingerprint.of(DevelopmentRecipe(sceneGraph: expected)))
            XCTAssertEqual(try store.loadEditingVersions(workID: work.id).count, 1)
            XCTAssertEqual(editing.canvasCommand?.id, transform)
            (graphWindow as? NSPanel)?.cancelOperation(nil) // first Escape exits monitor
            XCTAssertNil(editing.sceneGraphMonitorText)
            XCTAssertTrue(editing.sceneGraphState.open)
            (graphWindow as? NSPanel)?.cancelOperation(nil) // second Escape closes panel only
            try await wait("graph closes without altering owner") { !editing.sceneGraphState.open && window.childWindows?.contains(where: { $0.title == "工作流 Graph" }) != true }
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(editing.recipe.sceneGraph, expected)

            let original = try XCTUnwrap(editing.work?.source.sourceLocation)
            guard original.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw LibraryError.invalid("Only disconnect the test's copied fixture")
            }
            let offline = original.deletingLastPathComponent().appendingPathComponent("disconnected.ARW")
            try await press("editing.scene.graph.toggle", within: window)
            let reopened = try XCTUnwrap(window.childWindows?.first { $0.title == "工作流 Graph" })
            try FileManager.default.moveItem(at: original, to: offline)
            defer { if FileManager.default.fileExists(atPath: offline.path) { try? FileManager.default.moveItem(at: offline, to: original) } }
            try await press("scene.graph.bypass", within: reopened)
            try await wait("offline preview fails without changing the graph") { editing.scenePreviewError != nil && !editing.scenePreviewBusy }
            XCTAssertEqual(editing.recipe.sceneGraph, expected)
            try FileManager.default.moveItem(at: offline, to: original)
            try await press("editing.scene.retry", within: window)
            try await wait("retry restores the bypass preview") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            XCTAssertEqual(editing.sceneGraphState.preview, .bypass)
            XCTAssertNil(editing.scenePreviewError)
            XCTAssertEqual(editing.recipe.sceneGraph, expected)
            reopened.close()
            await editing.shutdown()
        } catch {
            XCTFail(error.localizedDescription + " · state open=\(editing.sceneGraphState.open), monitor=\(editing.sceneGraphMonitorText ?? "none"), message=\(editing.message ?? "none")")
            await editing.shutdown(); throw error
        }
    }

    @MainActor private func measureMonitor(_ editing: EditingController, first: UUID, in root: NSView, report: String) async throws {
        func find(_ view: NSView) -> SceneMetalView? {
            if let canvas = view as? SceneMetalView { return canvas }
            return view.subviews.lazy.compactMap(find).first
        }
        let canvas = try XCTUnwrap(find(root))
        editing.setSceneViewingHDR(false)
        editing.selectSceneNodes([first], ticket: try XCTUnwrap(editing.sceneGraphTicket))
        var nodeSamples: [Double] = [], finalSamples: [Double] = []
        var sceneExecutors = Set<String>()
        let strictWGPU = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() == "wgpu"
        func elapsed(node: Bool) async throws -> Double {
            let previous = editing.sceneFrame?.id
            let start = DispatchTime.now().uptimeNanoseconds
            if node { editing.monitorSceneGraph(.node(first), ticket: try XCTUnwrap(editing.sceneGraphTicket)) }
            else { editing.stopSceneGraphMonitor() }
            let timeout = ContinuousClock.now + .seconds(5)
            while editing.scenePreviewBusy || editing.sceneFrame?.id == nil || editing.sceneFrame?.id == previous || canvas.presentedFrameID != editing.sceneFrame?.id {
                guard ContinuousClock.now < timeout else { throw LibraryError.invalid("Timed out: Graph monitor drawable") }
                try await Task.sleep(for: .milliseconds(2))
            }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            let execution = editing.sceneFrame?.execution
            if let execution { sceneExecutors.insert(execution.backend.rawValue) }
            if strictWGPU {
                XCTAssertEqual(execution?.backend, .wgpu)
                XCTAssertNil(execution?.fallbackReason)
            }
            return milliseconds
        }
        editing.stopSceneGraphMonitor()
        try await wait("starting final drawable") { canvas.presentedFrameID == editing.sceneFrame?.id && editing.sceneFrame != nil && !editing.scenePreviewBusy }
        for index in 0..<35 {
            let node = try await elapsed(node: true), final = try await elapsed(node: false)
            if index >= 5 { nodeSamples.append(node); finalSamples.append(final) }
        }
        func stats(_ data: [Double]) -> (Double, Double) { let sorted = data.sorted(); return ((sorted[14] + sorted[15]) / 2, sorted[28]) }
        let (nodeP50, nodeP95) = stats(nodeSamples), (finalP50, finalP95) = stats(finalSamples)
        let json: [String: Any] = ["scope": "open floating Graph: warm interim Corrector and final grouped serial output monitor switching to joined SDR drawable",
            "asset": editing.work?.source.contentSHA256 ?? "unknown", "device": editing.sceneFrame?.texture.device.name ?? "unknown",
            "executors": sceneExecutors.sorted(), "warmups": 5, "measuredSamplesPerRoot": nodeSamples.count,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "pixels": [canvas.bounds.width, canvas.bounds.height], "backingScale": canvas.window?.backingScaleFactor ?? 0,
            "nodeP50Ms": nodeP50, "nodeP95Ms": nodeP95, "finalP50Ms": finalP50, "finalP95Ms": finalP95, "nodeSamplesMs": nodeSamples, "finalSamplesMs": finalSamples]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: [.withoutOverwriting])
        XCTAssertLessThanOrEqual(max(nodeP50, finalP50), 25.92)
        XCTAssertLessThanOrEqual(max(nodeP95, finalP95), 210.23)
        _ = try await elapsed(node: true)  // Save while still monitoring.
    }

    private func sample(_ texture: MTLTexture) throws -> SIMD4<Float> {
        let size = MemoryLayout<SIMD4<Float>>.stride
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: size, options: .storageModeShared))
        let queue = try XCTUnwrap(texture.device.makeCommandQueue()), cmd = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(cmd.makeBlitCommandEncoder())
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: .init(x: texture.width / 2, y: texture.height / 2, z: 0), sourceSize: .init(width: 1, height: 1, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: size, destinationBytesPerImage: size)
        encoder.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        XCTAssertEqual(cmd.status, .completed)
        return buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self).pointee
    }

    @MainActor private func verifyRepair(editing: EditingController, window: NSWindow, graphWindow: NSWindow) async throws {
        let baseline = editing.recipe, monitor = editing.sceneGraphState.preview
        let selection = editing.sceneGraphState.selection, path = editing.sceneGraphState.path
        try await wait("repair capability") {
            if editing.developmentToolsPaused { editing.beginDevelopmentInterface() }
            return editing.repairEntryReason == nil
        }
        let context = try XCTUnwrap(editing.developmentContext)
        try await press("editing.repair", within: window)
        try await wait("repair replaces both cards") {
            let ids = Set(accessibleControls(in: window).map(\.identifier))
            return editing.repairEditing && !graphWindow.isVisible && ids.contains("editing.rail.repair")
                && !ids.contains("editing.rail.photo") && !ids.contains("editing.rail.parameters")
        }
        XCTAssertNil(editing.sceneGraphMonitorText)
        XCTAssertNil(editing.sceneGraphTicket)
        editing.developmentLocalInput.retouchMode = .clone

        func clone(_ x: Double, _ donor: DevelopmentSourcePoint, count: Int) async throws {
            try await wait("settled repair canvas") {
                guard let frame = editing.developmentLocalFrame(context: context) else { return false }
                return editing.developmentLocalInput.viewport?.frameID == frame.frameID
            }
            let frame = try XCTUnwrap(editing.developmentLocalFrame(context: context))
            let viewport = try XCTUnwrap(editing.developmentLocalInput.viewport)
            let pointer = try XCTUnwrap(editing.scenePhotographicPointer)
            func click(_ source: DevelopmentSourcePoint, option: Bool = false) throws {
                let output = try XCTUnwrap(try frame.mapping.outputPoint(fromSource: source))
                let location = CGPoint(x: viewport.imageRect.minX + output.x * viewport.imageRect.width,
                                       y: viewport.imageRect.minY + output.y * viewport.imageRect.height)
                let id = UUID(), modifiers = option ? UInt64(NSEvent.ModifierFlags.option.rawValue) : 0
                for phase: ImageCanvasPointerPhase in [.began, .ended] {
                    XCTAssertTrue(pointer(.init(phase: phase, gestureID: id, beganFrameID: frame.frameID, viewport: viewport,
                        locationInView: location, pressure: 0, supportsPressure: false, modifiersRawValue: modifiers, eventTimestamp: 1)))
                }
            }
            try click(donor, option: true)
            try click(.init(x: x, y: 0.5))
            XCTAssertTrue(editing.developmentAnalysisBusy, "The displayed source accepts this stroke")
            try await wait("repair analysis joined") { !editing.developmentAnalysisBusy }
            XCTAssertNil(editing.repairFailure?.message ?? editing.message, "Real RAW clone should resolve")
            XCTAssertEqual(editing.developmentSession.parameters.localEdits.operations.count, count)
            try await wait("scene displays the tool draft") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
        }

        try await clone(0.5, .init(x: 0.36, y: 0.35), count: 1)
        try recordWindow(window, named: "native-repair")
        XCTAssertEqual(editing.recipe, baseline)
        XCTAssertEqual(editing.visibleSceneGraph?.graph, baseline.sceneGraph?.graph)
        XCTAssertEqual(editing.visibleSceneGraph?.photographic?.localEdits.operations.count, 1)
        try await press("editing.repair.cancel", within: window)
        try await wait("same graph and monitored output return after cancellation") {
            !editing.repairEditing && graphWindow.isVisible && editing.sceneFrame != nil && !editing.scenePreviewBusy
        }
        XCTAssertEqual(editing.recipe, baseline)
        XCTAssertEqual(editing.sceneGraphState.preview, monitor)
        XCTAssertEqual(editing.sceneGraphState.selection, selection)
        XCTAssertEqual(editing.sceneGraphState.path, path)

        try await press("editing.repair", within: window)
        try await clone(0.5, .init(x: 0.36, y: 0.35), count: 1)
        try await clone(0.53, .init(x: 0.39, y: 0.38), count: 2)
        let staged = editing.developmentSession.parameters.localEdits.operations
        try await press("editing.repair.done", within: window)
        try await wait("one repair commit with the same inspector context") {
            !editing.repairEditing && graphWindow.isVisible && !editing.scenePreviewBusy
        }
        XCTAssertEqual(editing.recipe.sceneGraph?.photographic?.localEdits.operations, staged)
        XCTAssertEqual(editing.sceneGraphState.preview, monitor)
        XCTAssertEqual(editing.sceneGraphState.path, path)
        XCTAssertEqual(editing.sceneGraphState.selection, selection)
        XCTAssertTrue(editing.stepSceneHistory(redo: false))
        XCTAssertEqual(editing.recipe, baseline, "One photo undo removes both repair strokes")
    }

    @MainActor private func recordWindow(_ window: NSWindow, named name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["RAWMASTER_EDITOR_REPAIR_EVIDENCE"] else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let output = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        try capture.run()
        capture.waitUntilExit()
        XCTAssertEqual(capture.terminationStatus, 0)
    }

    @MainActor private func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LibraryError.invalid("Timed out: " + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private func accessibleControls(in window: NSWindow) -> [(element: NSObject, identifier: String, label: String)] {
        window.contentView?.layoutSubtreeIfNeeded()
        var result: [(NSObject, String, String)] = []
        let label = NSSelectorFromString("accessibilityLabel")
        let attr = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
        var pending: [NSObject] = [window], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast(), visited.count < 2048 {
            guard visited.insert(ObjectIdentifier(value)).inserted else { continue }
            let currentID = value.responds(to: attr) ? value.perform(attr)?.takeUnretainedValue() as? String : nil
            let name = value.responds(to: label) ? value.perform(label)?.takeUnretainedValue() as? String : nil
            if currentID != nil || name != nil { result.append((value, currentID ?? "", name ?? "")) }
            if value.responds(to: children), let nested = value.perform(children)?.takeUnretainedValue() as? [NSObject] { pending += nested }
        }
        return result
    }
    @MainActor private func press(_ identifier: String, within window: NSWindow) async throws {
        var match: NSObject?
        var latest: [String] = []
        defer { if match == nil { print("Graph AX missing \(identifier): \(latest)") } }
        try await wait(identifier) {
            let controls = accessibleControls(in: window)
            latest = controls.map(\.identifier)
            match = controls.first { $0.identifier == identifier || (identifier == "editing.scene.graph.toggle" && $0.label == "Graph 窗口") }?.element
            return match != nil
        }
        let button = try XCTUnwrap(match)
        let action = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(button.responds(to: action))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(try XCTUnwrap(button.method(for: action)), to: Press.self)(button, action))
    }
}
