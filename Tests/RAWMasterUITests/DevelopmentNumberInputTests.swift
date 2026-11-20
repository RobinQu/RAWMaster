import AppKit
import XCTest
@testable import RAWMaster

final class DevelopmentNumberInputTests: XCTestCase {
    @MainActor private func presentation(_ value: Double = 0, enabled: Bool = true,
                                        write: @escaping (Double) -> Void,
                                        invalid: @escaping (Bool) -> Void = { _ in }) -> DevelopmentNumberEditSession.Presentation {
        .init(value: value, range: 0...360, digits: 1, enabled: enabled, write: write, invalid: invalid)
    }
    @MainActor func testInvalidNativeReturnConsumesWithoutChangingEditorSelectionOrUndoOwnership() throws {
        _ = NSApplication.shared
        var writes = 0, invalid = false
        let owner = DevelopmentNumberInput.Coordinator(presentation(write: { _ in writes += 1 }, invalid: { invalid = $0 }))
        let field = NSTextField(), editor = NSTextView(frame: .init(x: 0, y: 0, width: 160, height: 30))
        owner.field = field; field.delegate = owner; owner.refreshDisplay()
        owner.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: field))
        editor.string = "361"; editor.setSelectedRange(.init(location: 3, length: 0))
        let manager = editor.undoManager, canUndo = manager?.canUndo, allowsUndo = editor.allowsUndo
        let selected = editor.selectedRange(), text = editor.string, controlText = field.stringValue
        XCTAssertTrue(owner.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(invalid); XCTAssertEqual(writes, 0); XCTAssertTrue(owner.session.isEditing)
        XCTAssertEqual(editor.string, text); XCTAssertEqual(editor.selectedRange(), selected)
        XCTAssertEqual(field.stringValue, controlText, "Invalid Return must not rewrite the control or its editor")
        XCTAssertTrue(manager === editor.undoManager); XCTAssertEqual(editor.undoManager?.canUndo, canUndo)
        XCTAssertEqual(editor.allowsUndo, allowsUndo)
        // This is a delegate-consumption unit contract, not a claim that an inactive BNDL host
        // has a usable native Undo stack. The separate APPL harness must start with canUndo=true.
    }
    @MainActor func testMarkedInputPassesThroughAndValidReturnWritesOnlyOnceThenBlurDoesNotWrite() throws {
        var values: [Double] = [], invalid: [Bool] = []
        let session = DevelopmentNumberEditSession(presentation(write: { values.append($0) }, invalid: { invalid.append($0) }))
        let token = try XCTUnwrap(session.begin())
        XCTAssertEqual(session.submit("三", markedText: true, token: token), .passThrough)
        XCTAssertEqual(invalid, [false]); XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(session.submit("5", markedText: false, token: token), .finish(token))
        XCTAssertEqual(values, [5])
        XCTAssertEqual(session.submit("6", markedText: false, token: token), .consumed)
        XCTAssertEqual(values, [5]); XCTAssertTrue(session.end(token)); XCTAssertFalse(session.end(token))
        XCTAssertEqual(values, [5]); XCTAssertEqual(session.displayText, "0", "Only an actual model update can publish a new accepted value")
        session.update(presentation(5, write: { values.append($0) }))
        XCTAssertEqual(session.displayText, "5")
        let discard = try XCTUnwrap(session.begin())
        XCTAssertTrue(session.end(discard), "Session cleanup alone does not synthesize a submit; native blur submits before this cleanup")
        XCTAssertEqual(values, [5])
    }
    @MainActor func testRoundedConfirmationPreservesExactBitsAndRejectedOrCanonicalValuesRemainModelOwned() throws {
        let exact = 123.456789
        let bits = exact.bitPattern
        var writes = 0
        let rounded = DevelopmentNumberEditSession(presentation(exact, write: { _ in writes += 1 }))
        let token = try XCTUnwrap(rounded.begin())
        XCTAssertEqual(rounded.submit("123.5", markedText: false, token: token), .finish(token))
        XCTAssertTrue(rounded.end(token)); XCTAssertEqual(writes, 0)
        XCTAssertEqual(rounded.presentation.value.bitPattern, bits)
        for input in ["5", "360"] {
            let unchanged = DevelopmentNumberEditSession(presentation(write: { _ in writes += 1 }))
            let edit = try XCTUnwrap(unchanged.begin())
            XCTAssertEqual(unchanged.submit(input, markedText: false, token: edit), .finish(edit))
            XCTAssertTrue(unchanged.end(edit)); XCTAssertEqual(unchanged.displayText, "0")
        }
        XCTAssertEqual(writes, 2)
    }
    @MainActor func testSetterCaptureLateTokensDisableAndDismantleNeverRebindAnOldEdit() throws {
        _ = NSApplication.shared
        var oldWrites: [Double] = [], newWrites: [Double] = []
        let session = DevelopmentNumberEditSession(presentation(write: { oldWrites.append($0) }))
        let old = try XCTUnwrap(session.begin())
        session.update(presentation(write: { newWrites.append($0) }))
        XCTAssertEqual(session.submit("5", markedText: false, token: old), .finish(old))
        XCTAssertEqual(oldWrites, [5]); XCTAssertTrue(newWrites.isEmpty)
        XCTAssertTrue(session.end(old))
        let current = try XCTUnwrap(session.begin())
        XCTAssertEqual(session.submit("9", markedText: false, token: old), .consumed)
        XCTAssertFalse(session.end(old)); XCTAssertTrue(session.isEditing)
        XCTAssertTrue(session.update(presentation(enabled: false, write: { newWrites.append($0) })))
        XCTAssertEqual(session.submit("8", markedText: false, token: current), .consumed)
        XCTAssertFalse(session.end(current)); XCTAssertTrue(newWrites.isEmpty)
        session.update(presentation(write: { newWrites.append($0) }))
        let last = try XCTUnwrap(session.begin()); session.revoke()
        XCTAssertEqual(session.submit("7", markedText: false, token: last), .consumed)
        XCTAssertNil(session.begin()); XCTAssertTrue(newWrites.isEmpty)

        let owner = DevelopmentNumberInput.Coordinator(presentation(write: { newWrites.append($0) }))
        let field = NSTextField(); owner.field = field; field.delegate = owner
        owner.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: field))
        let captured = try XCTUnwrap(owner.token)
        DevelopmentNumberInput.dismantleNSView(field, coordinator: owner)
        XCTAssertTrue(owner.session.revoked); XCTAssertNil(field.delegate); XCTAssertNil(owner.token)
        XCTAssertEqual(owner.session.submit("11", markedText: false, token: captured), .consumed)
        XCTAssertFalse(owner.session.end(captured)); XCTAssertTrue(newWrites.isEmpty)
    }
    @MainActor func testReentrantRevocationBeforeOrDuringSetterNeverFinishesOrAdmitsAnotherWrite() throws {
        var session: DevelopmentNumberEditSession!, falseEvents = 0, writes = 0
        defer { session = nil }
        session = DevelopmentNumberEditSession(presentation(write: { _ in writes += 1 }, invalid: { flag in
            if !flag { falseEvents += 1; if falseEvents == 2 { session.revoke() } }
        }))
        let token = try XCTUnwrap(session.begin())
        XCTAssertEqual(session.submit("5", markedText: false, token: token), .consumed)
        XCTAssertEqual(writes, 0); XCTAssertFalse(session.isFinishing(token))
        session = DevelopmentNumberEditSession(presentation(write: { _ in writes += 1; session.revoke() }))
        let second = try XCTUnwrap(session.begin())
        XCTAssertEqual(session.submit("5", markedText: false, token: second), .consumed)
        XCTAssertEqual(session.submit("6", markedText: false, token: second), .consumed)
        XCTAssertEqual(writes, 1); XCTAssertFalse(session.end(second))
    }
}


/// A real AppKit field editor. No direct delegate/notification fallback is permitted here.
@MainActor final class DevelopmentNumberNativeEditorFixture {
    let window: NSWindow
    let field = NSTextField(frame: .init(x: 20, y: 70, width: 180, height: 24))
    let other = NSTextField(frame: .init(x: 20, y: 20, width: 180, height: 24))
    let coordinator: DevelopmentNumberInput.Coordinator
    init(_ presentation: DevelopmentNumberEditSession.Presentation, owner: DevelopmentNumberInputOwner? = nil) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 130),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        coordinator = .init(presentation, owner: owner)
        field.delegate = coordinator; coordinator.field = field
        field.isEditable = true; field.isSelectable = true
        field.cell?.usesSingleLineMode = true
        other.isEditable = true; other.isSelectable = true
        window.contentView?.addSubview(field); window.contentView?.addSubview(other)
        field.nextKeyView = other; other.nextKeyView = field
        window.initialFirstResponder = field
        coordinator.refreshDisplay()
        window.makeKeyAndOrderFront(nil)
    }
    func enter(_ text: String) throws -> NSTextView {
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "Actual native field editor is required")
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText(text, replacementRange: .init(location: 0, length: (editor.string as NSString).length))
        XCTAssertNotNil(coordinator.token, "Native insertText must have delivered begin editing")
        XCTAssertTrue(coordinator.session.isEditing)
        return editor
    }
    func close() {
        coordinator.session.revoke(); coordinator.forgetToken(); field.delegate = nil
        window.makeFirstResponder(nil); window.orderOut(nil); window.close()
    }
}

extension DevelopmentNumberInputTests {
    @MainActor func testRealNativeTabBacktabAndBlurCommitOnceAndReturnDoesNotDoubleCommit() throws {
        for movement in ["tab", "backtab", "blur", "return"] {
            var values: [Double] = []
            let owner = DevelopmentNumberInputOwner()
            let host = DevelopmentNumberNativeEditorFixture(presentation(write: { values.append($0) }), owner: owner)
            defer { host.close() }
            let editor = try host.enter("74.25")
            switch movement {
            case "tab": editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
            case "backtab": editor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            case "return": editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            default: XCTAssertTrue(host.window.makeFirstResponder(host.other))
            }
            XCTAssertEqual(values, [74.25], movement)
            XCTAssertFalse(host.coordinator.session.isEditing, movement)
            XCTAssertNil(host.coordinator.token, movement)
            XCTAssertFalse(host.field.currentEditor() === editor, "The original field must really end editing")
            XCTAssertTrue(host.window.makeFirstResponder(host.other))
            owner.finishCurrentEdit()
            XCTAssertEqual(values, [74.25], "Return/blur and later navigation cannot write again")
        }
    }
    @MainActor func testRealNativeInvalidMarkedEscapeAndRevokedEditorsDoNotWriteOnBlur() throws {
        for scenario in ["invalid", "marked", "owned-invalid", "owned-marked", "escape", "revoked", "rebind"] {
            var values: [Double] = [], rebound: [Double] = []
            let owner = DevelopmentNumberInputOwner()
            let host = DevelopmentNumberNativeEditorFixture(presentation(write: { values.append($0) }), owner: owner)
            defer { host.close() }
            let editor = try host.enter(scenario.hasSuffix("invalid") ? "361" : "74.25")
            let token = try XCTUnwrap(host.coordinator.token)
            switch scenario {
            case "marked", "owned-marked":
                editor.setMarkedText("75", selectedRange: .init(location: 2, length: 0),
                                     replacementRange: .init(location: 0, length: (editor.string as NSString).length))
                XCTAssertTrue(editor.hasMarkedText())
            case "escape": editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            case "revoked": owner.cancelCurrentEdit()
            case "rebind":
                let replacement = DevelopmentNumberInputOwner()
                host.coordinator.updateOwner(replacement)
                host.coordinator.session.update(presentation(write: { rebound.append($0) }))
            default: break
            }
            if scenario.hasPrefix("owned-") { owner.finishCurrentEdit() }
            XCTAssertTrue(host.window.makeFirstResponder(host.other))
            owner.finishCurrentEdit()
            XCTAssertTrue(values.isEmpty, scenario); XCTAssertTrue(rebound.isEmpty, scenario)
            XCTAssertNil(host.coordinator.token, scenario)
            XCTAssertEqual(host.coordinator.session.submit("99", markedText: false, token: token), .consumed)
        }
    }
    @MainActor func testRealNativeOwnedFlushPreservesRoundedValueAndReentrantRevocation() throws {
        let exact = 123.456789
        var writes: [Double] = []
        let owner = DevelopmentNumberInputOwner()
        let rounded = DevelopmentNumberNativeEditorFixture(presentation(exact, write: { writes.append($0) }), owner: owner)
        defer { rounded.close() }
        _ = try rounded.enter("123.5")
        owner.finishCurrentEdit()
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(rounded.coordinator.session.presentation.value.bitPattern, exact.bitPattern)
        let active = DevelopmentNumberNativeEditorFixture(presentation(write: { value in
            writes.append(value); owner.cancelCurrentEdit()
        }), owner: owner)
        defer { active.close() }
        let editor = try active.enter("42")
        owner.finishCurrentEdit()
        XCTAssertEqual(writes, [42]); XCTAssertNil(active.coordinator.token)
        XCTAssertTrue(active.window.makeFirstResponder(active.other))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:))); owner.finishCurrentEdit()
        XCTAssertEqual(writes, [42], "A reentrant cancellation closes the frozen setter before late native callbacks")
    }
}
