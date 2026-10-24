import AppKit
import SwiftUI

/// A thumbnail selects on pointer down, without waiting to disambiguate a double tap.
/// Right/control clicks and scrolling remain owned by the containing SwiftUI views.
struct CardInputLayer: NSViewRepresentable {
    var onPress: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    func makeNSView(context: Context) -> CardInputView {
        let view = CardInputView()
        view.setAccessibilityElement(false) // The visible card provides its label and press action.
        return view
    }
    func updateNSView(_ view: CardInputView, context: Context) {
        view.onPress = onPress; view.onDoubleClick = onDoubleClick
    }
}

final class CardInputView: NSView {
    var onPress: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var currentEvent: () -> NSEvent? = { NSApp.currentEvent }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func captures(_ event: NSEvent?) -> Bool {
        guard let event else { return true }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return !event.modifierFlags.contains(.control)
        default: return false
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.captures(currentEvent()) else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return }
        if event.clickCount == 2 { onDoubleClick?() }
        else if event.clickCount == 1 { onPress?(event.modifierFlags) }
    }
    override func mouseUp(with event: NSEvent) {}
}
