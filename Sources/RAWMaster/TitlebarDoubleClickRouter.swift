import AppKit

/// SwiftUI's unified toolbar can swallow double clicks on both decorative
/// principal content and blank toolbar space. Route only that window chrome to
/// native zoom; toolbar controls and the photo workspace keep their own input.
@MainActor
enum TitlebarDoubleClickRouter {
    static let brandItemID = "workbench.brand"

    @discardableResult
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 2,
              event.window === window, window.attachedSheet == nil,
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen),
              isZoomArea(event.locationInWindow, in: window) else { return false }
        window.performZoom(nil)
        return true
    }

    static func isZoomArea(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard point.x >= 0, point.x < window.frame.width,
              point.y >= window.contentLayoutRect.maxY,
              point.y < window.frame.height else { return false }

        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind),
               button.bounds.contains(button.convert(point, from: nil)) { return false }
        }
        for item in window.toolbar?.items ?? [] {
            guard !item.itemIdentifier.rawValue.contains(brandItemID), let view = item.view,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
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
