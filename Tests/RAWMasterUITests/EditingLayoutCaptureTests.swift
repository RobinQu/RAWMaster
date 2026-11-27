import AppKit
import SwiftUI
import XCTest
@testable import RAWMaster

/// Deterministic visual evidence, separate from the packaged application's WindowServer smoke.
final class EditingLayoutCaptureTests: XCTestCase {
    @MainActor func testOptionalNativeEditingLayouts() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_EDITING_LAYOUT_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_EDITING_LAYOUT_OUTPUT for native production layout captures")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: fixture.assets[0].projectID); model.select(fixture.assets[0]); model.setMode(.single)
        model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        for _ in 0..<500 { if editing.work != nil && editing.preview != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(editing.work); XCTAssertNotNil(editing.preview)
        var evidence: [[String: String]] = []
        for size in [NSSize(width: 1100, height: 720), NSSize(width: 1480, height: 940)] {
            for dark in [false, true] {
                let suffix = "\(Int(size.width))-" + (dark ? "dark" : "light")
                editing.stage = .development; editing.cropEditing = true
                editing.setRecipe { $0.exposureEV = 0.35; $0.crop = .init(x: 0.05, y: 0.1, width: 0.9, height: 0.8) }
                evidence.append(try await capture(WorkbenchView().environmentObject(model), size: size, dark: dark, output: output, name: "development-" + suffix))
                editing.cropEditing = false; editing.requestPreview(); editing.openQuickPrompt()
                evidence.append(try await capture(WorkbenchView().environmentObject(model), size: size, dark: dark, output: output, name: "quick-prompt-" + suffix))
                editing.closeQuickPrompt()
            }
        }
        editing.stage = .development; editing.saveDevelopment()
        for _ in 0..<500 { if !editing.saving && editing.versions.count >= 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(editing.versions.count, 2)
        editing.stage = .versions; editing.setComparisonMode(.wipeHorizontal)
        for dark in [false, true] {
            for size in [NSSize(width: 1100, height: 720), NSSize(width: 1480, height: 940)] {
                evidence.append(try await capture(WorkbenchView().environmentObject(model), size: size, dark: dark, output: output, name: "candidate-compare-\(Int(size.width))-" + (dark ? "dark" : "light")))
            }
            evidence.append(try await capture(EditingSettingsSheet(editing: editing), size: NSSize(width: 650, height: 590), dark: dark, output: output, name: "settings-" + (dark ? "dark" : "light")))
            evidence.append(try await capture(EditingRuntimeSettings(editing: editing), size: NSSize(width: 650, height: 590), dark: dark, output: output, name: "runtime-setup-" + (dark ? "dark" : "light")))
            editing.exportVersionID = editing.selectedVersionID
            evidence.append(try await capture(EditingExportSheet(editing: editing), size: NSSize(width: 520, height: 530), dark: dark, output: output, name: "render-export-" + (dark ? "dark" : "light")))
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("capture-dimensions.json"))
        await editing.shutdown()
    }
    @MainActor private func capture<V: View>(_ view: V, size: NSSize, dark: Bool, output: URL, name: String) async throws -> [String: String] {
        let root = view.background(AppPalette.panel).preferredColorScheme(dark ? .dark : .light).environment(\.resolvedAppAppearance, dark ? .dark : .light).frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root); host.sizingOptions = []; host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.setContentSize(size)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.bounds.size, size)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        return ["file": name + ".png", "logical": "\(Int(size.width))x\(Int(size.height))", "pixels": "\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)", "appearance": dark ? "dark" : "light"]
    }
}
