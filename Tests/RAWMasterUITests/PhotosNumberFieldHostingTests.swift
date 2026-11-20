import AppKit
import SwiftUI
import XCTest
@testable import RAWMaster

final class PhotosNumberFieldHostingTests: XCTestCase {
    @MainActor private final class Model: ObservableObject {
        @Published var value: Double
        var writes = 0
        let reject: Bool
        let canonicalizeHue: Bool
        init(_ value: Double, reject: Bool = false, canonicalizeHue: Bool = false) {
            self.value = value; self.reject = reject; self.canonicalizeHue = canonicalizeHue
        }
        func apply(_ number: Double) {
            writes += 1
            if !reject { value = canonicalizeHue && number == 360 ? 0 : number }
        }
    }
    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            // Match the product row: an immutable getter snapshot, not a live model getter.
            let snapshot = model.value
            DevelopmentNumberField(title: "测试数值", value: .init(get: { snapshot }, set: { model.apply($0) }),
                range: 0...360, fractionDigits: 1).frame(width: 160).padding()
        }
    }
    @MainActor func testReturnRefreshesAcceptedRejectedCanonicalAndRoundedValuesWithoutAnotherClick() async throws {
        let application = NSApplication.shared, previousPolicy = NSApp.activationPolicy()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        defer { _ = application.setActivationPolicy(previousPolicy) }
        for mode in 0..<4 {
            let model = Model(mode == 2 ? 123.456789 : 0, reject: mode == 1, canonicalizeHue: mode == 3)
            let initial = model.value
            let host = NSHostingView(rootView: Host(model: model))
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            let modeName = ["accepted", "rejected", "rounded", "canonical"][mode]
            window.title = "RAWMaster NumberField test " + modeName
            window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            func fields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
            }
            func diagnostic(_ stage: String) {
                let actual = fields(host).first(where: { $0.isEditable })
                print("NumberField host", modeName, stage, "active", application.isActive, "key", window.isKeyWindow,
                      "ownKey", NSApp.keyWindow === window, "visible", window.isVisible,
                      "responder", String(describing: window.firstResponder.map { type(of: $0) }),
                      "display", actual?.stringValue ?? "<no field>",
                      "editor", (actual?.currentEditor() as? NSTextView)?.string ?? "<no editor>",
                      "model", model.value, "writes", model.writes)
            }
            do {
                try await eventually(modeName + ": actual application and own key window", diagnostics: { diagnostic("key readiness failed") }) {
                    application.isActive && NSApp.keyWindow === window && window.isKeyWindow && window.isVisible
                }
            } catch {
                if !application.isActive { throw XCTSkip("WindowServer did not activate the xctest host; run native window acceptance for this axis") }
                throw error
            }
            XCTAssertTrue(NSApp.keyWindow === window, modeName)
            var field: NSTextField?
            try await eventually(modeName + ": native editable field materialized") {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                field = fields(host).first(where: { $0.isEditable })
                return field != nil
            }
            let native = try XCTUnwrap(field)
            XCTAssertTrue(window.makeFirstResponder(native), modeName); native.selectText(nil)
            try await eventually(modeName + ": actual field editor owns key focus", diagnostics: { diagnostic("editor readiness failed") }) {
                NSApp.keyWindow === window && native.currentEditor() is NSTextView && window.firstResponder === native.currentEditor()
            }
            let editor = try XCTUnwrap(native.currentEditor() as? NSTextView)
            XCTAssertTrue(editor.isFieldEditor, modeName)
            diagnostic("ready")
            let input = mode == 2 ? "123.5" : mode == 3 ? "360" : "5"
            editor.selectAll(nil); editor.insertText(input, replacementRange: editor.selectedRange())
            try await eventually(modeName + ": native input visible before Return", diagnostics: { diagnostic("input readiness failed") }) {
                window.firstResponder === editor && editor.string == input
            }
            diagnostic("before Return")
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(enter)
            let expected = mode == 0 ? "5" : mode == 2 ? "123.5" : "0"
            try await eventually(modeName + ": Return displays the actual accepted value and leaves field focus", diagnostics: { diagnostic("Return failed") }) {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard let actual = fields(host).first(where: { $0.isEditable }) else { return false }
                return actual.stringValue == expected && actual.currentEditor() == nil && window.firstResponder !== editor
            }
            diagnostic("after Return")
            XCTAssertEqual(model.value, mode == 0 ? 5 : initial)
            XCTAssertEqual(model.writes, mode == 2 ? 0 : 1)
            if mode == 2 { XCTAssertEqual(model.value.bitPattern, initial.bitPattern, "Rounded confirmation must not quantize the saved value") }

            let actual = try XCTUnwrap(fields(host).first(where: { $0.isEditable }))
            XCTAssertTrue(window.makeFirstResponder(actual), modeName); actual.selectText(nil)
            try await eventually(modeName + ": invalid-input editor owns actual focus", diagnostics: { diagnostic("invalid focus readiness failed") }) {
                NSApp.keyWindow === window && actual.currentEditor() is NSTextView && window.firstResponder === actual.currentEditor()
            }
            let invalidEditor = try XCTUnwrap(actual.currentEditor() as? NSTextView)
            invalidEditor.breakUndoCoalescing()
            invalidEditor.selectAll(nil); invalidEditor.insertText("361", replacementRange: invalidEditor.selectedRange())
            try await eventually(modeName + ": invalid input visible before Return", diagnostics: { diagnostic("invalid input readiness failed") }) {
                invalidEditor.string == "361" && window.firstResponder === invalidEditor
            }
            window.sendEvent(enter)
            try await eventually(modeName + ": invalid Return retains text and editor focus", diagnostics: { diagnostic("invalid Return failed") }) {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return invalidEditor.string == "361" && window.firstResponder === invalidEditor && actual.currentEditor() === invalidEditor
            }
            XCTAssertTrue(window.firstResponder === invalidEditor, "Invalid Return preserves text-editor focus and undo ownership")
            XCTAssertEqual(invalidEditor.string, "361", modeName)
            XCTAssertEqual(model.writes, mode == 2 ? 0 : 1, modeName)
            let undo = try XCTUnwrap(invalidEditor.undoManager)
            XCTAssertTrue(undo.canUndo, "Invalid text must retain the native editor's Undo")
            invalidEditor.breakUndoCoalescing(); undo.undo()
            try await eventually(modeName + ": field-editor Undo restores its own text", diagnostics: { diagnostic("editor Undo failed") }) {
                invalidEditor.string == expected && window.firstResponder === invalidEditor
            }
            XCTAssertEqual(model.value, mode == 0 ? 5 : initial, modeName)
            XCTAssertEqual(model.writes, mode == 2 ? 0 : 1, "Text Undo must not edit the recipe model")
            diagnostic("invalid text Undo complete")
        }
    }
    private enum HostError: Error { case readiness(String) }
    @MainActor private func eventually(_ name: String, diagnostics: @escaping @MainActor () -> Void = {},
                                      condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        diagnostics(); throw HostError.readiness(name)
    }
}
