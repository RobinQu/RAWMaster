import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class SequenceFlowCaptureTests: XCTestCase {
    @MainActor func testOptionalSequenceFlowCaptures() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["RAWMASTER_SEQUENCE_FLOW_OUTPUT"],
              let imageDirectory = environment["RAWMASTER_SEQUENCE_FLOW_IMAGES"] else {
            throw XCTSkip("Set RAWMASTER_SEQUENCE_FLOW_OUTPUT and RAWMASTER_SEQUENCE_FLOW_IMAGES for packed sequence layout evidence")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: destination, isDirectory: true)
        let source = output.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let images = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: imageDirectory), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.path < $1.path }
        XCTAssertFalse(images.isEmpty)
        guard !images.isEmpty else { return }
        for index in 0..<12 {
            try FileManager.default.copyItem(at: images[index % images.count], to: source.appendingPathComponent(String(format: "PHOTO-%02d.jpg", index)))
        }
        let library = output.appendingPathComponent("native-library.sqlite")
        let store = try LibraryStore(databaseURL: library)
        let session = try await ImportService(store: store).importDirectory(source: source, destination: nil,
            projectName: "连续排布 · 布局验证", mode: .reference, initialScreening: false, progress: { _ in })
        let suite = "SequenceFlowCapture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        model.selectScope(.project, id: session.projectID)
        let photos = model.browserAssets
        XCTAssertEqual(photos.count, 12)
        guard photos.count == 12 else { return }
        let a = try store.previewGroupCommand(.create(assetIDs: [1, 2, 3, 4, 10].map { photos[$0].id }, name: "跨行连拍", kind: "连拍"))
        _ = try store.commitGroupCommand(a)
        let b = try store.previewGroupCommand(.create(assetIDs: [6, 7].map { photos[$0].id }, name: "短延时序列", kind: "延时"))
        _ = try store.commitGroupCommand(b)
        model.reload(); model.showSidebar = true; model.showInspector = false
        model.selectedIDs = [photos[0].id]; model.focusedID = photos[0].id; model.setMode(.grid)
        for (width, dark) in [(1100.0, false), (1280.0, false), (1100.0, true)] {
            try await capture(model, output: output, width: width, dark: dark, name: "grid-\(Int(width))-\(dark ? "dark" : "light")")
        }
        model.setMode(.single)
        try await capture(model, output: output, width: 1100, dark: false, name: "single-filmstrip")
        model.setMode(.grid); model.saveBrowse(); model.flushProjectReviewState()
        try JSONSerialization.data(withJSONObject: ["projectID": session.projectID, "photoIDs": photos.map(\.id),
            "library": library.path], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("fixture.json"))
    }

    @MainActor private func capture(_ model: AppModel, output: URL, width: Double, dark: Bool, name: String) async throws {
        let size = NSSize(width: width, height: 900)
        let host = NSHostingView(rootView: WorkbenchView().environmentObject(model)
            .preferredColorScheme(dark ? .dark : .light).environment(\.resolvedAppAppearance, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
