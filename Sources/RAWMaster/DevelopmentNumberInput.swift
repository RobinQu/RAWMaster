import AppKit
import SwiftUI

/// Metadata-only input ownership. The setter is frozen at begin, and never rebound while editing.
/// There is deliberately no text storage, Undo manager, selection or native editor mutation here.
@MainActor final class DevelopmentNumberEditSession {
    struct Presentation {
        let value: Double
        let range: ClosedRange<Double>
        let digits: Int
        let enabled: Bool
        let write: (Double) -> Void
        let invalid: (Bool) -> Void
        var requiresInteger = false
    }
    enum ReturnAction: Equatable { case passThrough, consumed, invalid, finish(UUID) }
    private struct Edit {
        let id: UUID
        let presentation: Presentation
        var finishing = false
    }
    private(set) var presentation: Presentation
    private var edit: Edit?
    private(set) var revoked = false
    var isEditing: Bool { edit != nil }
    init(_ presentation: Presentation) { self.presentation = presentation }
    /// Returns whether disabling revoked an active edit. No callback during a SwiftUI update.
    @discardableResult func update(_ presentation: Presentation) -> Bool {
        guard !revoked else { return false }
        self.presentation = presentation
        if !presentation.enabled, edit != nil { edit = nil; return true }
        return false
    }
    func begin() -> UUID? {
        guard !revoked, presentation.enabled, edit == nil else { return nil }
        let id = UUID(); edit = .init(id: id, presentation: presentation)
        presentation.invalid(false)
        return id
    }
    func submit(_ text: String, markedText: Bool, token: UUID) -> ReturnAction {
        guard !revoked, presentation.enabled, let current = edit, current.id == token else { return .consumed }
        // Let the input method finish composition; do not parse an unfinished marked segment.
        guard !markedText else { return .passThrough }
        guard !current.finishing else { return .consumed }
        let format = DevelopmentNumericText.format(presentation.value, fractionDigits: current.presentation.digits)
        let number: Double?
        if text == format { number = nil }
        else {
            guard let parsed = DevelopmentNumericText.parse(text, range: current.presentation.range),
                  !current.presentation.requiresInteger || parsed.rounded() == parsed else {
                current.presentation.invalid(true); return .invalid
            }
            number = parsed
        }
        edit?.finishing = true // close repeated/reentrant Return admission before invoking the setter
        current.presentation.invalid(false)
        guard isFinishing(token) else { return .consumed }
        if let number { current.presentation.write(number) }
        return isFinishing(token) ? .finish(token) : .consumed
    }
    func isFinishing(_ token: UUID) -> Bool { !revoked && edit?.id == token && edit?.finishing == true }
    @discardableResult func end(_ token: UUID) -> Bool {
        guard !revoked, let current = edit, current.id == token else { return false }
        edit = nil; current.presentation.invalid(false)
        return true // Submission, if any, happened while the real field editor was still present.
    }
    func discardForUpdate() { edit = nil } // no SwiftUI callback from an update/rebind
    func revoke() { revoked = true; edit = nil }
    var displayText: String { DevelopmentNumericText.format(presentation.value, fractionDigits: presentation.digits) }
}

/// One editing controller owns only its currently registered native numeric edit.
/// Neither the editor nor the coordinator is retained; no global responder lookup is used.
@MainActor final class DevelopmentNumberInputOwner {
    private weak var current: DevelopmentNumberInput.Coordinator?
    private var token: UUID?
    func register(_ coordinator: DevelopmentNumberInput.Coordinator, token: UUID) {
        if current !== coordinator || self.token != token { cancelCurrentEdit() }
        current = coordinator; self.token = token
    }
    func clear(_ coordinator: DevelopmentNumberInput.Coordinator, token: UUID) {
        guard current === coordinator, self.token == token else { return }
        current = nil; self.token = nil
    }
    func finishCurrentEdit() {
        guard let current, let token else { return }
        current.finishOwnedEdit(token)
    }
    func cancelCurrentEdit() {
        let previous = current, previousToken = token
        current = nil; token = nil
        if let previous, let previousToken { previous.cancelOwnedEdit(previousToken) }
    }
}
private struct DevelopmentNumberInputOwnerKey: EnvironmentKey {
    static let defaultValue: DevelopmentNumberInputOwner? = nil
}
extension EnvironmentValues {
    var developmentNumberInputOwner: DevelopmentNumberInputOwner? {
        get { self[DevelopmentNumberInputOwnerKey.self] }
        set { self[DevelopmentNumberInputOwnerKey.self] = newValue }
    }
}

/// A privately owned native field lets invalid insertNewline be consumed BEFORE default editing
/// completion clears NSCellUndoManager. No SwiftUI/private delegate interception or event monitor.
struct DevelopmentNumberInput: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let fractionDigits: Int
    let disabled: Bool
    var integrated = false
    var requiresInteger = false
    let invalidChanged: (Bool) -> Void
    @Environment(\.developmentNumberInputOwner) private var inputOwner
    @Environment(\.isEnabled) private var environmentEnabled
    @Environment(\.font) private var font
    @Environment(\.controlSize) private var controlSize
    private var presentation: DevelopmentNumberEditSession.Presentation {
        let binding = _value
        return .init(value: value, range: range, digits: fractionDigits, enabled: !disabled && environmentEnabled,
            write: { binding.wrappedValue = $0 }, invalid: invalidChanged, requiresInteger: requiresInteger)
    }
    func makeCoordinator() -> Coordinator { Coordinator(presentation, owner: inputOwner) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = !integrated
        if integrated {
            field.drawsBackground = false
            field.focusRingType = .none
            field.cell?.focusRingType = .none
        } else {
            field.bezelStyle = .roundedBezel
        }
        field.alignment = .right; field.isEditable = true; field.isSelectable = true
        field.maximumNumberOfLines = 1; field.cell?.usesSingleLineMode = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        context.coordinator.field = field
        updateNSView(field, context: context)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.session.revoked else { return }
        coordinator.updateOwner(inputOwner)
        let disabledEdit = coordinator.session.update(presentation)
        if disabledEdit {
            coordinator.forgetToken() // revoke before native end-editing notifications can arrive
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        }
        if field.isEnabled != presentation.enabled { field.isEnabled = presentation.enabled }
        if field.placeholderString != title { field.placeholderString = title; field.setAccessibilityLabel(title) }
        var nativeSize = field.controlSize
        switch controlSize {
        case .mini: nativeSize = .mini
        case .small: nativeSize = .small
        default: nativeSize = .regular
        }
        if field.controlSize != nativeSize { field.controlSize = nativeSize }
        // Keep the existing caption/body hierarchy using public standard Font values only.
        let pointSize: CGFloat
        if font == Font.caption { pointSize = 11 }
        else if font == Font.caption2 || font == Font.footnote { pointSize = 10 }
        else if font == Font.callout { pointSize = 12 }
        else { pointSize = NSFont.systemFontSize(for: field.controlSize) }
        let nativeFont = NSFont.systemFont(ofSize: pointSize)
        if field.font?.isEqual(nativeFont) != true { field.font = nativeFont }
        coordinator.refreshDisplay() // a no-op throughout an active native editing session
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.session.revoke(); coordinator.forgetToken()
        field.delegate = nil
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        coordinator.field = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let session: DevelopmentNumberEditSession
        weak var field: NSTextField?
        var token: UUID?
        private weak var owner: DevelopmentNumberInputOwner?
        private var cancelling = false
        init(_ presentation: DevelopmentNumberEditSession.Presentation, owner: DevelopmentNumberInputOwner? = nil) {
            session = .init(presentation); self.owner = owner
        }
        func forgetToken() {
            if let token { owner?.clear(self, token: token) }
            token = nil; cancelling = false
        }
        func updateOwner(_ newOwner: DevelopmentNumberInputOwner?) {
            guard owner !== newOwner else { return }
            session.discardForUpdate(); forgetToken()
            owner = newOwner
            if let field, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        }
        func cancelOwnedEdit(_ expected: UUID) {
            guard token == expected else { return }
            // Close admission before clearing the invalid marker; a callback may reenter.
            forgetToken(); _ = session.end(expected)
        }
        func finishOwnedEdit(_ expected: UUID) {
            guard token == expected, !cancelling, !session.revoked, session.presentation.enabled,
                  let field, let window = field.window,
                  let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else {
                cancelOwnedEdit(expected); return
            }
            let action = session.submit(editor.string, markedText: editor.hasMarkedText(), token: expected)
            guard token == expected, !session.revoked, field.currentEditor() === editor else { return }
            switch action {
            case .invalid, .passThrough:
                // Ending native composition can remove its marked range. Revoke the old token
                // first, so that AppKit's ensuing end callback cannot parse that text again.
                cancelOwnedEdit(expected)
            case .finish, .consumed: break
            }
            window.makeFirstResponder(nil)
        }
        func refreshDisplay() {
            guard !session.revoked, !session.isEditing, let field else { return }
            if field.stringValue != session.displayText { field.stringValue = session.displayText }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard (notification.object as? NSTextField) === field else { return }
            if let token = session.begin() {
                self.token = token; cancelling = false
                owner?.register(self, token: token)
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard (notification.object as? NSTextField) === field else { return }
            if let token { forgetToken(); _ = session.end(token) }
            refreshDisplay()
        }
        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
            guard let field, control === field, let token, !cancelling,
                  let editor = fieldEditor as? NSTextView, field.currentEditor() === editor else { return true }
            _ = session.submit(editor.string, markedText: editor.hasMarkedText(), token: token)
            return true
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard control === field else { return false }
            if command == #selector(NSResponder.cancelOperation(_:)) {
                cancelling = true // AppKit owns cancellation; its ensuing blur must not submit.
                return false
            }
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Composition belongs to the input method, including a Return which confirms it.
            if textView.hasMarkedText() { return false }
            guard let token else { return true }
            switch session.submit(textView.string, markedText: false, token: token) {
            case .passThrough: return false
            case .invalid, .consumed: return true // do not touch editor text, selection, focus or Undo
            case .finish(let token):
                if session.isFinishing(token), let field, field.currentEditor() === textView {
                    field.window?.makeFirstResponder(nil)
                }
                return true
            }
        }
    }
}
