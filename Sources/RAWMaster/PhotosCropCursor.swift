import AppKit

/// Lightflow-style contextual crop cursors, updated only when the active hit region changes.
@MainActor enum PhotosCropCursor {
    private static let rotate = cursor(symbol: "arrow.counterclockwise")
    private static let upLeftDownRight = cursor(symbol: "arrow.up.left.and.arrow.down.right")
    private static let upRightDownLeft = cursor(symbol: "arrow.up.right.and.arrow.down.left")

    static func set(_ handle: PhotosCropHandle?) {
        switch handle {
        case .none: NSCursor.arrow.set()
        case .straighten: rotate.set()
        case .left, .right: NSCursor.resizeLeftRight.set()
        case .top, .bottom: NSCursor.resizeUpDown.set()
        case .topLeft, .bottomRight: upLeftDownRight.set()
        case .topRight, .bottomLeft: upRightDownLeft.set()
        case .center: NSCursor.openHand.set()
        }
    }

    private static func cursor(symbol name: String) -> NSCursor {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return .arrow
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [.white])
        let source = symbol.withSymbolConfiguration(configuration)?.withSymbolConfiguration(palette)
            ?? symbol
        let image = NSImage(size: .init(width: 24, height: 24))
        image.lockFocus()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        source.draw(in: .init(x: 3, y: 3, width: 18, height: 18), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .init(x: 12, y: 12))
    }
}
