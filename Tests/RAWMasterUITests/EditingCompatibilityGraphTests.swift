import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class EditingCompatibilityGraphTests: XCTestCase {
    @MainActor func testCompatibilityGraphPanelKeepsOwnerNonmodalAndClosesOnContextChange() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 640, height: 480), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        owner.orderFront(nil)
        let presenter = EditingCompatibilityGraphPanel()
        presenter.anchor = owner.contentView
        let source = EditingSourceSnapshot(projectID: "p", assetID: "a", contentSHA256: String(repeating: "a", count: 64),
            byteCount: 1024, admissionFingerprint: String(repeating: "b", count: 64), sourceLocation: URL(fileURLWithPath: "/sample.ARW"))
        let version = EditingVersion(workID: "w", parentVersionID: nil, kind: .original, source: source)
        let projection = try DevelopmentCompatibilityGraphV1(version)
        let ownerFrame = owner.frame
        var restored = 0
        presenter.show(projection, photoName: "sample.ARW", returnFocus: { restored += 1 })
        let panel = try XCTUnwrap(presenter.panel)
        XCTAssertTrue(panel.isVisible && owner.isVisible)
        XCTAssertTrue(panel.parent === owner)
        XCTAssertNil(owner.attachedSheet)
        XCTAssertEqual(owner.frame, ownerFrame)
        XCTAssertEqual(presenter.openWorkID, version.workID)
        let expanded = panel.frame
        XCTAssertGreaterThanOrEqual(expanded.height, 392)
        XCTAssertGreaterThanOrEqual(expanded.width, 520)
        presenter.toggleFold()
        XCTAssertLessThan(panel.frame.height, 90)
        presenter.toggleFold()
        XCTAssertEqual(panel.frame, expanded)
        presenter.resetPosition()
        if let visible = panel.screen?.visibleFrame { XCTAssertTrue(visible.contains(panel.frame)) }
        panel.cancelOperation(nil)
        XCTAssertEqual(restored, 1)
        XCTAssertNil(presenter.openWorkID)
        XCTAssertTrue(owner.childWindows?.isEmpty ?? true)
        presenter.show(projection, photoName: "sample.ARW", returnFocus: { restored += 1 })
        presenter.fitToContext("next-work")
        XCTAssertNil(presenter.panel)
        XCTAssertEqual(restored, 1, "context changes must not focus the old photo's control")
        XCTAssertEqual(owner.frame, ownerFrame)
    }

    @MainActor func testCompatibilityGraphButtonUsesPrototypePhotoAndRetainsDarkroomState() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/dji187-context376/files/asset0000.jpg")
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("compatibility.sqlite")
        let sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("sunset.jpg")
        try FileManager.default.copyItem(at: fixture, to: source)
        let asset = try NativePresentedCanvasTests.register(source: source, library: library, requiresRAW: false)
        let name = "RAWMaster-compatibility-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        let editing = try XCTUnwrap(model.editing, model.errorMessage ?? "Editor unavailable")
        let window = NSWindow(contentRect: NSRect(x: 70, y: 120, width: 900, height: 610), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ZStack(alignment: .topTrailing) {
            EditingImageCanvas(editing: editing).environmentObject(model)
            EditingCompatibilityGraphToolbar(editing: editing).frame(width: 304)
        })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await wait { editing.sourceReady && editing.previews.primary.frame != nil }
            let before = editing.recipe, version = editing.selectedVersionID, workID = editing.work?.id
            let frame = editing.previews.primary.frame?.id, command = editing.canvasCommand?.id
            func trigger() -> NSObject? {
                element(in: window, selector: "accessibilityIdentifier", equals: "editing.compatibilityGraph")
            }
            try await wait {
                host.layoutSubtreeIfNeeded()
                return trigger() != nil
            }
            let button = try XCTUnwrap(trigger())
            try press(button)
            try await wait { window.childWindows?.contains(where: { $0.title == "只读兼容图" }) == true }
            let panel = try XCTUnwrap(window.childWindows?.first(where: { $0.title == "只读兼容图" }))
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(window.isVisible && panel.isVisible)
            XCTAssertNotNil(element(in: panel, selector: "accessibilityLabel", equals: "关闭 Graph"))
            panel.cancelOperation(nil)
            try await wait { window.childWindows?.contains(where: { $0.title == "只读兼容图" }) != true }
            XCTAssertEqual(editing.recipe, before)
            XCTAssertEqual(editing.selectedVersionID, version)
            XCTAssertEqual(editing.work?.id, workID)
            XCTAssertEqual(editing.canvasCommand?.id, command)
            XCTAssertEqual(editing.previews.primary.frame?.id, frame)
            XCTAssertFalse(editing.isDirty)
            await editing.shutdown()
        } catch { await editing.shutdown(); throw error }
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < limit else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case timedOut }

    @MainActor private func element(in root: NSObject, selector: String, equals expected: String) -> NSObject? {
        let children = NSSelectorFromString("accessibilityChildren"), field = NSSelectorFromString(selector)
        var pending = [root], visited: [ObjectIdentifier: NSObject] = [:]
        while let node = pending.popLast(), visited.count < 2048 {
            guard visited.updateValue(node, forKey: ObjectIdentifier(node)) == nil else { continue }
            if node.responds(to: field), node.perform(field)?.takeUnretainedValue() as? String == expected { return node }
            if node.responds(to: children), let list = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                pending.append(contentsOf: list)
            }
        }
        return nil
    }

    @MainActor private func press(_ button: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(button.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(button, selector))
    }
}
