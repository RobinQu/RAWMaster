import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster
@testable import RAWMasterImaging

final class AppearanceTests: XCTestCase {
    @MainActor final class HostSystem {
        var appearance = NSAppearance(named: .aqua)
        var appliedAppearances: [NSAppearance.Name?] = []
        var dock: [NSImage?] = []
        let lightIcon = NSImage(size: CGSize(width: 8, height: 8))
        let darkIcon = NSImage(size: CGSize(width: 9, height: 9))
        func controller(_ defaults: UserDefaults) -> AppearanceController {
            AppearanceController(defaults: defaults, systemAppearance: { self.appearance },
                applyAppearance: { self.appliedAppearances.append($0?.name) },
                applyDockIcon: { self.dock.append($0) },
                icon: { $0 == .dark ? self.darkIcon : self.lightIcon }, observeSystem: false)
        }
    }
    @MainActor func testPreferencePersistsIntentAndSystemResolutionRemainsIndependent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RAWMasterAppearance-" + UUID().uuidString))
        let system = HostSystem(), controller = system.controller(defaults)
        XCTAssertEqual(controller.preference, .system); XCTAssertEqual(controller.resolved, .light)
        XCTAssertNil(defaults.string(forKey: AppearanceController.preferenceKey))
        XCTAssertNil(system.dock.last!)
        system.appearance = NSAppearance(named: .darkAqua); controller.refreshSystemAppearance()
        XCTAssertEqual(controller.preference, .system); XCTAssertEqual(controller.resolved, .dark)
        controller.setPreference(.light)
        XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "light")
        XCTAssertTrue(system.dock.last! === system.lightIcon)
        system.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua); controller.refreshSystemAppearance()
        XCTAssertEqual(controller.resolved, .light, "Manual preference must not be overwritten by system changes")
        let reopened = system.controller(defaults)
        XCTAssertEqual(reopened.preference, .light); XCTAssertEqual(reopened.resolved, .light)
        controller.setPreference(.dark)
        XCTAssertTrue(system.dock.last! === system.darkIcon)
        controller.setPreference(.system)
        XCTAssertEqual(defaults.string(forKey: AppearanceController.preferenceKey), "system")
        XCTAssertNil(system.appliedAppearances.last!); XCTAssertNil(system.dock.last!)
        XCTAssertEqual(controller.resolved, .dark)
    }
    @MainActor func testUnknownPreferenceAndHighContrastResolveConservatively() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RAWMasterAppearance-" + UUID().uuidString))
        defaults.set("future-unknown-preference", forKey: AppearanceController.preferenceKey)
        let system = HostSystem(); system.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        let controller = system.controller(defaults)
        XCTAssertEqual(controller.preference, .system); XCTAssertEqual(controller.resolved, .dark)
        XCTAssertNil(controller.preference.preferredColorScheme)
        XCTAssertEqual(ResolvedAppearance.resolve(NSAppearance(named: .accessibilityHighContrastAqua)), .light)
        XCTAssertEqual(ResolvedAppearance.resolve(NSAppearance(named: .accessibilityHighContrastDarkAqua)), .dark)
        XCTAssertEqual(ResolvedAppearance.resolve(nil), .light)
    }
    @MainActor func testSemanticNeutralSurfacesResolveForBothAppearances() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua)), dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var a: NSColor?, b: NSColor?
        light.performAsCurrentDrawingAppearance { a = AppPalette.canvasNSColor.usingColorSpace(.deviceRGB) }
        dark.performAsCurrentDrawingAppearance { b = AppPalette.canvasNSColor.usingColorSpace(.deviceRGB) }
        let first = try XCTUnwrap(a), second = try XCTUnwrap(b)
        XCTAssertGreaterThan(first.redComponent, second.redComponent)
        for color in [first, second] {
            XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.001)
            XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.001)
        }
    }
    struct WorkbenchHost: View {
        @ObservedObject var model: AppModel
        @ObservedObject var appearance: AppearanceController
        var body: some View {
            WorkbenchView().environmentObject(model)
                .preferredColorScheme(appearance.preference.preferredColorScheme)
                .environment(\.resolvedAppAppearance, appearance.resolved)
                .frame(width: 1440, height: 900)
        }
    }
    @MainActor func testThemeChangePreservesBusinessStateViewportTasksAndDecodeCounts() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 6)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.select(model.assets[1]); model.select(model.assets[2], modifiers: .command); model.setMode(.compare)
        model.actualPixels = true
        model.progress = TaskProgress(title: "主题测试中的任务", completed: 1, total: 4, message: "保留任务状态", isRunning: true)
        let system = HostSystem(), appearance = system.controller(fixture.defaults)
        let host = NSHostingView(rootView: WorkbenchHost(model: model, appearance: appearance))
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 900); host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let counters = await ImagePipeline.shared.testingSnapshot()
        let selected = model.selectedIDs, focus = model.focusedID, scope = model.scope, scopeID = model.scopeID
        let viewports = descendants(host).compactMap { $0 as? NSScrollView }.map { $0.contentView.bounds.origin }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let records = try encoder.encode(fixture.store.loadAssets())
        for preference in [AppearancePreference.dark, .light, .system] {
            appearance.setPreference(preference)
            try await Task.sleep(nanoseconds: 30_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.selectedIDs, selected); XCTAssertEqual(model.focusedID, focus)
            XCTAssertEqual(model.scope, scope); XCTAssertEqual(model.scopeID, scopeID)
            XCTAssertEqual(model.mode, .compare); XCTAssertTrue(model.actualPixels)
            XCTAssertEqual(model.progress?.completed, 1); XCTAssertEqual(model.progress?.isRunning, true)
            XCTAssertEqual(descendants(host).compactMap { $0 as? NSScrollView }.map { $0.contentView.bounds.origin }, viewports)
        }
        let after = await ImagePipeline.shared.testingSnapshot()
        XCTAssertEqual(counters.previewRequests, after.previewRequests)
        XCTAssertEqual(counters.detailRequests, after.detailRequests)
        XCTAssertEqual(counters.previewDecodeStarts, after.previewDecodeStarts)
        XCTAssertEqual(counters.detailDecodeStarts, after.detailDecodeStarts)
        XCTAssertEqual(try encoder.encode(fixture.store.loadAssets()), records)
    }
    @MainActor func testKeyboardMonitorIsScopedToItsOwnWindowAndRespectsTextEditing() throws {
        _ = NSApplication.shared
        let workbench = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        workbench.isReleasedWhenClosed = false; settings.isReleasedWhenClosed = false
        defer { workbench.close(); settings.close() }
        let anchor = NSView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        workbench.contentView?.addSubview(anchor)
        let monitor = KeyboardMonitor.Coordinator(handler: { _ in XCTFail("Routing predicate must not consume events"); return true })
        monitor.view = anchor
        func key(_ window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        }
        let event = try key(workbench)
        XCTAssertTrue(monitor.shouldHandle(event, keyWindow: workbench, isActive: true))
        XCTAssertFalse(monitor.shouldHandle(try key(settings), keyWindow: settings, isActive: true))
        XCTAssertFalse(monitor.shouldHandle(event, keyWindow: settings, isActive: true))
        XCTAssertFalse(monitor.shouldHandle(event, keyWindow: workbench, isActive: false))
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 80, height: 50))
        workbench.contentView?.addSubview(editor); workbench.makeFirstResponder(editor)
        XCTAssertFalse(monitor.shouldHandle(try key(workbench, flags: .command), keyWindow: workbench, isActive: true), "Native text editing / undo must keep its key events")
    }
    @MainActor final class EditorWithUndo: NSTextView {
        let localUndo = UndoManager()
        override var undoManager: UndoManager? { localUndo }
    }
    @MainActor func testMenuUndoRoutesToNativeEditorAndNeverToPhotosFromSettings() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 1)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.select(try XCTUnwrap(model.assets.first)); model.decide(.keep)
        let workbench = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        workbench.isReleasedWhenClosed = false; settings.isReleasedWhenClosed = false
        defer { workbench.close(); settings.close() }
        let anchor = WorkbenchKeyAnchor(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        workbench.contentView?.addSubview(anchor)
        XCTAssertTrue(WorkbenchWindowContext.contains(workbench))
        WorkbenchUndoRouting.undo(model: model, window: settings)
        XCTAssertEqual(model.focusedAsset?.decision, .keep)
        let editor = EditorWithUndo(frame: CGRect(x: 0, y: 0, width: 100, height: 70))
        settings.contentView?.addSubview(editor); settings.makeFirstResponder(editor)
        var textUndoExecuted = false
        editor.localUndo.groupsByEvent = false
        editor.localUndo.beginUndoGrouping()
        editor.localUndo.registerUndo(withTarget: editor) { _ in textUndoExecuted = true }
        editor.localUndo.endUndoGrouping()
        WorkbenchUndoRouting.undo(model: model, window: settings)
        XCTAssertTrue(textUndoExecuted)
        XCTAssertEqual(model.focusedAsset?.decision, .keep, "Settings undo must not consume a pending photo decision")
        workbench.makeFirstResponder(workbench.contentView)
        WorkbenchUndoRouting.undo(model: model, window: workbench)
        XCTAssertEqual(model.focusedAsset?.decision, .undecided)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
