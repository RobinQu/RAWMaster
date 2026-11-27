import AppKit
import SwiftUI

extension NSControl {
    func suppressStandardFocusRing() {
        if focusRingType != .none { focusRingType = .none }
        if let cell, cell.focusRingType != .none { cell.focusRingType = .none }
    }
}

extension View {
    func workbenchFocusAppearance() -> some View {
        focusEffectDisabled()
            .background(WorkbenchFocusAnchor().allowsHitTesting(false).accessibilityHidden(true))
    }
}

/// Apply inside a button label so it inherits that button's focus without taking ownership of it.
struct WorkbenchFocusUnderline: View {
    @Environment(\.isFocused) private var focused
    var body: some View {
        if focused {
            Capsule().fill(.secondary).frame(height: 2)
                .padding(.horizontal, 4).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// SwiftUI can create a native control after the window has appeared, including the shared field editor.
/// Limit AppKit styling to the window containing this view. System panels own their responders.
private struct WorkbenchFocusAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {}

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated(_:)),
                name: NSWindow.didUpdateNotification, object: window)
            updateResponder()
        }

        @objc private func windowUpdated(_ notification: Notification) { updateResponder() }

        private func updateResponder() {
            guard let responder = window?.firstResponder as? NSView else { return }
            let editor = responder as? NSTextView
            let control = responder as? NSControl ?? editor?.delegate as? NSControl
            control?.suppressStandardFocusRing()
            if responder.focusRingType != .none { responder.focusRingType = .none }
        }
    }
}
