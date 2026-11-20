import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class DevelopmentGradingInteractionTests: XCTestCase {
    func testWheelMapsHueRadiusAndKeepsHueAtNeutralCenter() throws {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let current = DevelopmentGradingWheel(hueDegrees: 210, saturation: 30, luminance: -12)
        let center = DevelopmentGradingFeedback.wheel(at: .init(x: 100, y: 100), in: bounds, current: current)
        XCTAssertEqual(center.hueDegrees, 210); XCTAssertEqual(center.saturation, 0); XCTAssertEqual(center.luminance, -12)
        let right = DevelopmentGradingFeedback.wheel(at: .init(x: 250, y: 100), in: bounds, current: current)
        XCTAssertEqual(right.hueDegrees, 0); XCTAssertEqual(right.saturation, 100)
        let upper = DevelopmentGradingFeedback.wheel(at: .init(x: 100, y: 200), in: bounds, current: current)
        XCTAssertEqual(upper.hueDegrees, 90, accuracy: 1e-10); try upper.validate()
        let red = try XCTUnwrap(DevelopmentGradingFeedback.color(hue: 0, saturation: 100).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.redComponent, red.greenComponent)
        XCTAssertGreaterThan(red.redComponent, red.blueComponent)
        let neutral = try XCTUnwrap(DevelopmentGradingFeedback.color(hue: 270, saturation: 0).usingColorSpace(.sRGB))
        XCTAssertEqual(neutral.redComponent, 0.5, accuracy: 1e-6); XCTAssertEqual(neutral.greenComponent, neutral.blueComponent, accuracy: 1e-6)
    }
    @MainActor func testCustomControlsConsumeMenuUndoAndDoNotLeakPhotoKeyboardActions() async throws {
        _ = NSApplication.shared
        let f = try AppModelTests.Fixture(); defer { f.clean() }
        _ = try await f.populate(count: 1)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.select(try XCTUnwrap(model.assets.first)); model.decide(.keep)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let anchor = WorkbenchKeyAnchor(frame: CGRect(x: 0, y: 0, width: 10, height: 10)); window.contentView?.addSubview(anchor)
        let monitor = KeyboardMonitor.Coordinator(handler: { _ in XCTFail("Editing controls must keep their keys"); return true }); monitor.view = anchor
        func key(_ text: String, code: UInt16 = 6, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        for control in [DevelopmentCurveControl(frame: .zero), DevelopmentGradingControl(frame: .zero), PhotosScopedGradingControl(frame: .zero)] as [DevelopmentEditingControl] {
            window.contentView?.addSubview(control); XCTAssertTrue(window.makeFirstResponder(control))
            WorkbenchUndoRouting.undo(model: model, window: window)
            XCTAssertEqual(model.focusedAsset?.decision, .keep)
            for text in ["p", "x", "1", "5"] { XCTAssertFalse(monitor.shouldHandle(try key(text), keyWindow: window, isActive: true)) }
            XCTAssertTrue(control.performKeyEquivalent(with: try key("z", flags: .command)))
            XCTAssertTrue(control.performKeyEquivalent(with: try key("z", flags: [.command, .shift])))
        }
        window.makeFirstResponder(window.contentView)
        WorkbenchUndoRouting.undo(model: model, window: window)
        XCTAssertEqual(model.focusedAsset?.decision, .undecided, "Existing review undo is preserved outside adjustment-control focus")
        await model.editing?.shutdown()
    }
    @MainActor func testTwoDimensionalWheelDragEmitsOneValidMutationAndCancellationEndsInteraction() throws {
        let control = DevelopmentGradingControl(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        var changes = 0, phases: [(Bool, Bool)] = []
        control.onChange = { wheel in changes += 1; do { try wheel.validate() } catch { XCTFail("Wheel emitted invalid controls") } }
        control.interaction = { phases.append(($0, $1)) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 160, y: 100), modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        control.mouseDown(with: event)
        XCTAssertEqual(changes, 1); XCTAssertTrue(control.interacting)
        control.cancelOperation(nil)
        XCTAssertFalse(control.interacting); XCTAssertEqual(phases.map(\.0), [true, false])
        control.endInteraction(nativeEvent: false); XCTAssertEqual(phases.count, 2, "Duplicate cleanup does not create a second release")
        control.mouseDown(with: event)
        control.cancelTracking()
        let previous = changes
        control.mouseDragged(with: event)
        XCTAssertEqual(changes, previous, "Retired controls cannot continue a drag after focus/source removal")
    }
}
