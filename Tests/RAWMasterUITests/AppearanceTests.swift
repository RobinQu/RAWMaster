import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster
@testable import RAWMasterImaging

final class AppearanceTests: XCTestCase {
    @MainActor func testApplicationLaunchUsesDarkAqua() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = try XCTUnwrap(NSAppearance(named: .aqua))

        let delegate = ApplicationDelegate()
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification, object: app))

        XCTAssertEqual(app.appearance?.name, .darkAqua)
        XCTAssertEqual(AppAppearance.colorScheme, .dark)
    }

    @MainActor func testSemanticSurfacesStayDarkInEitherSystemAppearance() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var sample: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                sample = AppPalette.canvasNSColor.usingColorSpace(.deviceRGB)
            }
            let color = try XCTUnwrap(sample)
            XCTAssertLessThan(color.redComponent, 0.20)
            XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.001)
            XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.001)
        }
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
        let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: workbench.windowNumber, context: nil, characters: "m", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46))
        XCTAssertTrue(monitor.ownsWindowEvent(release, keyWindow: workbench, isActive: true), "Releasing original comparison must survive a change to text-field focus")
        XCTAssertFalse(monitor.ownsWindowEvent(release, keyWindow: settings, isActive: true))
        XCTAssertFalse(monitor.ownsWindowEvent(release, keyWindow: workbench, isActive: false))
    }
    @MainActor func testKeyboardMonitorAttachmentSynchronizesCurrentWindowFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = WorkbenchKeyAnchor(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let synchronized = expectation(description: "current focus synchronized on monitor attachment")
        var values: [Bool] = []
        let monitor = KeyboardMonitor.Coordinator(handler: { _ in false }, focusChanged: { focused in
            values.append(focused)
            if values.count == 1 { synchronized.fulfill() }
        })
        monitor.view = anchor
        monitor.install()
        defer { monitor.remove() }
        await fulfillment(of: [synchronized], timeout: 2)
        XCTAssertEqual(values.first, window.isKeyWindow)
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
    @MainActor func testNativeDevelopmentEmptyHistoryCannotUndoReviewOrApplyReviewKeys() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.autoAdvance = false
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.setMode(.single); model.select(fixture.assets[0]); model.decide(.keep)
        model.openNativeEditing(); XCTAssertTrue(model.isNativeEditing)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentView?.addSubview(WorkbenchKeyAnchor(frame: .zero))
        window.makeFirstResponder(window.contentView)
        WorkbenchUndoRouting.undo(model: model, window: window)
        WorkbenchUndoRouting.redo(model: model, window: window)
        XCTAssertEqual(model.focusedAsset?.decision, .keep, "An empty adjustment history must never consume a review decision")
        for (text, code) in [("x", UInt16(7)), ("1", UInt16(18))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            _ = model.handleKey(event)
        }
        XCTAssertEqual(model.focusedAsset?.decision, .keep)
        XCTAssertEqual(model.focusedAsset?.rating, fixture.assets[0].rating)
        await model.editing?.shutdown()
    }
    @MainActor func testNativeDevelopmentMenuUndoRedoUsesControlCallbacksAndIgnoresSettings() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.autoAdvance = false
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.setMode(.single); model.select(fixture.assets[0]); model.decide(.keep); model.openNativeEditing()
        XCTAssertTrue(model.isNativeEditing)
        let workbench = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        workbench.isReleasedWhenClosed = false; settings.isReleasedWhenClosed = false
        defer { workbench.close(); settings.close() }
        workbench.contentView?.addSubview(WorkbenchKeyAnchor(frame: .zero))
        let control = DevelopmentEditingControl(frame: CGRect(x: 0, y: 0, width: 60, height: 40))
        var undoCount = 0, redoCount = 0
        control.undoAction = { undoCount += 1 }; control.redoAction = { redoCount += 1 }
        workbench.contentView?.addSubview(control); XCTAssertTrue(workbench.makeFirstResponder(control))
        WorkbenchUndoRouting.undo(model: model, window: workbench); WorkbenchUndoRouting.redo(model: model, window: workbench)
        XCTAssertEqual(undoCount, 1); XCTAssertEqual(redoCount, 1)
        control.removeFromSuperview(); settings.contentView?.addSubview(control); XCTAssertTrue(settings.makeFirstResponder(control))
        WorkbenchUndoRouting.undo(model: model, window: settings); WorkbenchUndoRouting.redo(model: model, window: settings)
        XCTAssertEqual(undoCount, 1); XCTAssertEqual(redoCount, 1)
        XCTAssertEqual(model.focusedAsset?.decision, .keep)
        await model.editing?.shutdown()
    }
}
