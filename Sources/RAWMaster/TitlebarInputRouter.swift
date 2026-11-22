import AppKit

/// A unified toolbar can capture mouse-downs in the space around its items.
@MainActor
enum TitlebarInputRouter {
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .leftMouseDown, event.window === window,
              window.attachedSheet == nil, window.isMovable,
              !window.styleMask.contains(.fullScreen),
              isBlankTitlebar(event.locationInWindow, in: window) else { return false }

        switch event.clickCount {
        case 1:
            window.performDrag(with: event)
        case 2 where window.styleMask.contains(.resizable):
            window.performZoom(nil)
        default:
            return false
        }
        return true
    }

    static func isBlankTitlebar(_ point: NSPoint, in window: NSWindow) -> Bool {
        // Keep the frame's resize edges and the workspace under AppKit's normal hit testing.
        let frame = NSRect(origin: .zero, size: window.frame.size)
        guard window.styleMask.contains(.titled), frame.insetBy(dx: 5, dy: 5).contains(point),
              point.y >= window.contentLayoutRect.maxY else { return false }

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind),
               button.bounds.contains(button.convert(point, from: nil)) { return false }
        }
        for item in window.toolbar?.visibleItems ?? [] {
            guard item.itemIdentifier != .space, item.itemIdentifier != .flexibleSpace,
                  let view = item.view, !view.isHiddenOrHasHiddenAncestor else { continue }
            if view.bounds.contains(view.convert(point, from: nil)) { return false }
        }
        let frameView = window.contentView?.superview
        var hit = frameView?.hitTest(point)
        while let view = hit, view !== frameView {
            if view is NSControl { return false }
            hit = view.superview
        }
        return true
    }
}
