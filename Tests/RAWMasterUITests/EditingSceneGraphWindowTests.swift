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
        let host = NSHostingView(rootView: ZStack(alignment: .topTrailing) {
            EditingImageCanvas(editing: editing).environmentObject(model)
            NativeEditingInspector(editing: editing).frame(width: EditingLayout.sidebarWidth)
        })
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            editing.isPresented = true; editing.focus(asset)
            try await wait("original admitted") { editing.sourceReady && !editing.loading }
            editing.enterSceneDraft(ticket: try XCTUnwrap(editing.sceneTicket))
            try await wait("live HDR frame") { editing.sceneGraphScope != nil && editing.sceneFrame != nil && !editing.scenePreviewBusy }
            let initialRecipe = editing.recipe, originalFrame = editing.sceneFrame?.id
            let first = try XCTUnwrap(editing.sceneGraphState.single)
            let transform = editing.canvasCommand?.id
            try await press("editing.scene.graph.toggle", within: window)
            try await wait("nonmodal hover window") { editing.sceneGraphState.open && window.childWindows?.contains(where: { $0.title == "工作流 Graph" }) == true }
            let graphWindow = try XCTUnwrap(window.childWindows?.first(where: { $0.title == "工作流 Graph" }))
            XCTAssertTrue(window.isVisible); XCTAssertTrue(graphWindow.isVisible); XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(editing.recipe, initialRecipe); XCTAssertEqual(editing.sceneFrame?.id, originalFrame)
            XCTAssertGreaterThanOrEqual(graphWindow.frame.width, 520)
            XCTAssertGreaterThanOrEqual(graphWindow.frame.height, 392)
            try await press("scene.graph.fit", within: graphWindow)
            editing.addSceneGraphNode(.serial, ticket: try XCTUnwrap(editing.sceneGraphTicket))
            let second = try XCTUnwrap(editing.sceneGraphState.single)
            XCTAssertNotEqual(first, second)
            editing.changeSceneGraphNode(second, ticket: try XCTUnwrap(editing.sceneGraphTicket)) { node in
                guard case let .corrector(image, mask, _, curve, strength, enabled) = node.operation else { return node }
                return .init(id: node.id, name: node.name, operation: .corrector(image: image, mask: mask,
                    exposureEV: 1.5, curve: curve, strength: strength, enabled: enabled))
            }
            try await wait("two-node final") { editing.sceneFrame != nil && !editing.scenePreviewBusy }
            let finalPixels = try sample(XCTUnwrap(editing.sceneFrame).texture)
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
            editing.monitorSceneGraph(.node(first), ticket: try XCTUnwrap(editing.sceneGraphTicket))
            try await wait("fenced group node preview") { editing.sceneGraphMonitorText != nil && editing.sceneFrame != nil && !editing.scenePreviewBusy }
            let monitored = editing.sceneFrame?.id
            let previewPixels = try sample(XCTUnwrap(editing.sceneFrame).texture)
            XCTAssertNotEqual(previewPixels, finalPixels, "intermediate and final are visibly different")
            editing.selectSceneNodes([second], ticket: try XCTUnwrap(editing.sceneGraphTicket))
            XCTAssertEqual(editing.sceneFrame?.id, monitored, "selecting another node does not retarget monitor")
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
            // Group view is transient. Save reads the complete graph, not the preview's prefix.
            let expected = try XCTUnwrap(editing.recipe.sceneGraph)
            editing.saveDevelopment()
            try await wait("frozen version with group") { !editing.saving && editing.versions.contains(where: { $0.recipe.sceneGraph == expected }) }
            let candidate = try XCTUnwrap(editing.versions.first { $0.recipe.sceneGraph == expected })
            let store = try LibraryStore(databaseURL: database)
            let frozen = try store.freezeSceneDelivery(versionID: candidate.id, format: .avif10)
            XCTAssertEqual(try frozen.program.fingerprint(), try EditingFingerprint.of(DevelopmentRecipe(sceneGraph: expected)))
            XCTAssertEqual(editing.canvasCommand?.id, transform)
            (graphWindow as? NSPanel)?.cancelOperation(nil) // first Escape exits monitor
            XCTAssertNil(editing.sceneGraphMonitorText)
            XCTAssertTrue(editing.sceneGraphState.open)
            (graphWindow as? NSPanel)?.cancelOperation(nil) // second Escape closes panel only
            try await wait("graph closes without altering owner") { !editing.sceneGraphState.open && window.childWindows?.contains(where: { $0.title == "工作流 Graph" }) != true }
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(editing.recipe.sceneGraph, expected)
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
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
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

    @MainActor private func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LibraryError.invalid("Timed out: " + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private func press(_ identifier: String, within window: NSWindow) async throws {
        var match: NSObject?
        var latest: [String] = []
        let label = NSSelectorFromString("accessibilityLabel")
        let attr = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
        defer { if match == nil { print("Graph AX missing \(identifier): \(latest)") } }
        try await wait(identifier) {
            window.contentView?.layoutSubtreeIfNeeded()
            latest.removeAll(keepingCapacity: true)
            var pending: [NSObject] = [window], visited = Set<ObjectIdentifier>()
            while let value = pending.popLast(), visited.count < 2048 {
                guard visited.insert(ObjectIdentifier(value)).inserted else { continue }
                let currentID = value.responds(to: attr) ? value.perform(attr)?.takeUnretainedValue() as? String : nil
                let name = value.responds(to: label) ? value.perform(label)?.takeUnretainedValue() as? String : nil
                if let currentID { latest.append(currentID + " " + (name ?? "")) }
                if currentID == identifier || (identifier == "editing.scene.graph.toggle" && name == "Graph 窗口") { match = value; return true }
                if value.responds(to: children), let nested = value.perform(children)?.takeUnretainedValue() as? [NSObject] { pending += nested }
            }
            return false
        }
        let button = try XCTUnwrap(match)
        let action = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(button.responds(to: action))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(try XCTUnwrap(button.method(for: action)), to: Press.self)(button, action))
    }
}
