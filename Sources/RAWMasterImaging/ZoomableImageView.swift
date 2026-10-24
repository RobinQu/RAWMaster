import AppKit
import SwiftUI

public struct ImageTransform: Equatable {
    /// Magnification relative to fitting the image in the viewport.
    public var scale: CGFloat
    public var centerX: CGFloat
    public var centerY: CGFloat
    /// Optional backing pixels per source pixel. 1 is physical 1:1 in every compare pane.
    /// When nil, scale retains its fit-relative meaning for ordinary browsing.
    public var physicalMagnification: CGFloat?
    public init(scale: CGFloat = 1, centerX: CGFloat = 0.5, centerY: CGFloat = 0.5,
                physicalMagnification: CGFloat? = nil) {
        self.scale = scale; self.centerX = centerX; self.centerY = centerY
        self.physicalMagnification = physicalMagnification
    }
}

/// Pure geometry shared by the native canvas and executable diagnostics.
public enum ImageViewportGeometry {
    public static func fitScale(pixelSize: CGSize, viewport: CGSize) -> CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / pixelSize.width, viewport.height / pixelSize.height)
    }
    public static func actualPixelScale(pixelSize: CGSize, viewport: CGSize, backingScale: CGFloat) -> CGFloat {
        1 / (max(1, backingScale) * fitScale(pixelSize: pixelSize, viewport: viewport))
    }
    public static func pointScale(pixelSize: CGSize, viewport: CGSize,
                                  transform: ImageTransform, backingScale: CGFloat) -> CGFloat {
        transform.physicalMagnification.map { $0 / max(1, backingScale) }
            ?? (fitScale(pixelSize: pixelSize, viewport: viewport) * transform.scale)
    }
    public static func imageRect(pixelSize: CGSize, viewport: CGSize,
                                 transform: ImageTransform, backingScale: CGFloat) -> CGRect {
        let scale = pointScale(pixelSize: pixelSize, viewport: viewport, transform: transform, backingScale: backingScale)
        let width = pixelSize.width * scale, height = pixelSize.height * scale
        var x = width <= viewport.width ? (viewport.width - width) / 2 : viewport.width / 2 - transform.centerX * width
        var y = height <= viewport.height ? (viewport.height - height) / 2 : viewport.height / 2 - transform.centerY * height
        if abs(scale * backingScale - 1) < 0.001 {
            x = (x * backingScale).rounded() / backingScale
            y = (y * backingScale).rounded() / backingScale
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct ZoomableImageView: NSViewRepresentable {
    public var image: NSImage?
    public var actualPixels: Bool
    @Binding public var transform: ImageTransform
    public var backgroundColor: NSColor
    public var onActualPixelsChange: ((Bool) -> Void)?
    public var onRequestDetail: (() -> Void)?
    public init(image: NSImage?, actualPixels: Bool, transform: Binding<ImageTransform>,
                backgroundColor: NSColor = .controlBackgroundColor,
                onActualPixelsChange: ((Bool) -> Void)? = nil, onRequestDetail: (() -> Void)? = nil) {
        self.image = image; self.actualPixels = actualPixels; self._transform = transform
        self.backgroundColor = backgroundColor
        self.onActualPixelsChange = onActualPixelsChange; self.onRequestDetail = onRequestDetail
    }
    public func makeNSView(context: Context) -> ImageCanvas {
        let canvas = ImageCanvas()
        canvas.setAccessibilityLabel("照片细节。双击切换适合窗口与原始像素；拖动平移，捏合缩放。")
        return canvas
    }
    public func updateNSView(_ canvas: ImageCanvas, context: Context) {
        canvas.onTransform = { transform = $0 }
        canvas.onActualPixelsChange = onActualPixelsChange
        canvas.onRequestDetail = onRequestDetail
        canvas.update(image: image, actualPixels: actualPixels, transform: transform, backgroundColor: backgroundColor)
    }
}

public final class ImageCanvas: NSView {
    private var image: NSImage?
    private var backgroundColor: NSColor = .controlBackgroundColor
    private var resolvedBackgroundColor: CGColor?
    private var transform = ImageTransform()
    private var actualPixels = false
    private var dragOrigin: NSPoint?
    private var dragTransform = ImageTransform()
    var onTransform: ((ImageTransform) -> Void)?
    var onActualPixelsChange: ((Bool) -> Void)?
    var onRequestDetail: (() -> Void)?
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    private var pixelSize: CGSize {
        guard let image else { return .zero }
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        return CGSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
    }
    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    private var fit: CGFloat {
        ImageViewportGeometry.fitScale(pixelSize: pixelSize, viewport: bounds.size)
    }
    func update(image: NSImage?, actualPixels: Bool, transform: ImageTransform,
                backgroundColor: NSColor = .controlBackgroundColor) {
        let enteringActual = actualPixels && !self.actualPixels
        self.image = image
        if resolvedBackgroundColor == nil || !self.backgroundColor.isEqual(backgroundColor) {
            self.backgroundColor = backgroundColor
            resolveBackgroundColor()
        }
        self.actualPixels = actualPixels
        self.transform = transform
        if actualPixels { self.transform.physicalMagnification = 1 }
        needsDisplay = true
        if enteringActual {
            let next = self.transform
            // All panes publish the same physical value, never their different fit scales.
            DispatchQueue.main.async { [weak self] in self?.onTransform?(next) }
        }
    }
    public override func layout() { super.layout(); needsDisplay = true }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); needsDisplay = true
    }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveBackgroundColor()
        needsDisplay = true
    }
    private func resolveBackgroundColor() {
        // Resolve semantic colors only when their inputs change. Appearance stack
        // switches and NSColor conversion must stay out of zoom/pan drawing.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let rgb = backgroundColor.usingColorSpace(.deviceRGB) ?? .gray
            resolvedBackgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                components: [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent])
        }
    }
    private func pointScale(_ state: ImageTransform) -> CGFloat {
        ImageViewportGeometry.pointScale(pixelSize: pixelSize, viewport: bounds.size,
                                         transform: state, backingScale: backing)
    }
    private func imageRect(_ state: ImageTransform) -> CGRect {
        ImageViewportGeometry.imageRect(pixelSize: pixelSize, viewport: bounds.size,
                                        transform: state, backingScale: backing)
    }
    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // AppKit can supply a dirty region extending beyond this view; a magnified
        // image must never paint over adjacent SwiftUI controls or compare panes.
        bounds.clip()
        if resolvedBackgroundColor == nil { resolveBackgroundColor() }
        if let color = resolvedBackgroundColor {
            NSGraphicsContext.current?.cgContext.setFillColor(color)
            NSGraphicsContext.current?.cgContext.fill(bounds)
        }
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = abs(pointScale(transform) * backing - 1) < 0.001 ? .none : .high
        image.draw(in: imageRect(transform), from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
    private func publish(_ next: ImageTransform) {
        var state = next
        state.scale = max(1, min(64, state.scale))
        let size = pixelSize
        let width = size.width * pointScale(state), height = size.height * pointScale(state)
        let minX = width > 0 ? min(0.5, bounds.width / (2 * width)) : 0.5
        let minY = height > 0 ? min(0.5, bounds.height / (2 * height)) : 0.5
        state.centerX = min(1-minX, max(minX, state.centerX))
        state.centerY = min(1-minY, max(minY, state.centerY))
        transform = state; onTransform?(state); needsDisplay = true
    }
    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            let enteringActualPixels = !actualPixels && transform.physicalMagnification == nil && abs(transform.scale - 1) < 0.01
            var next = ImageTransform()
            if enteringActualPixels {
                let point = convert(event.locationInWindow, from: nil), rect = imageRect(transform)
                next.physicalMagnification = 1
                next.centerX = (point.x - rect.minX) / max(1, rect.width)
                next.centerY = (point.y - rect.minY) / max(1, rect.height)
            }
            actualPixels = enteringActualPixels
            publish(next)
            onActualPixelsChange?(enteringActualPixels)
            if enteringActualPixels { onRequestDetail?() }
        } else { dragOrigin = convert(event.locationInWindow, from: nil); dragTransform = transform }
    }
    public override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil), rect = imageRect(dragTransform)
        var next = dragTransform
        next.centerX -= (point.x - origin.x) / max(1, rect.width)
        next.centerY -= (point.y - origin.y) / max(1, rect.height)
        publish(next)
    }
    public override func mouseUp(with event: NSEvent) { dragOrigin = nil }
    private func zoom(by factor: CGFloat, at point: NSPoint) {
        let rect = imageRect(transform)
        let normalizedX = (point.x - rect.minX) / max(1, rect.width)
        let normalizedY = (point.y - rect.minY) / max(1, rect.height)
        var next = transform
        let leavingActualPixels = actualPixels
        if let physical = next.physicalMagnification {
            next.physicalMagnification = max(0.025, min(16, physical * factor))
        } else { next.scale = max(1, min(64, next.scale * factor)) }
        let width = pixelSize.width * pointScale(next), height = pixelSize.height * pointScale(next)
        next.centerX = normalizedX - (point.x - bounds.midX) / max(1, width)
        next.centerY = normalizedY - (point.y - bounds.midY) / max(1, height)
        actualPixels = false
        publish(next)
        if leavingActualPixels { onActualPixelsChange?(false) }
        if next.scale > 1 || next.physicalMagnification != nil { onRequestDetail?() }
    }
    public override func magnify(with event: NSEvent) {
        zoom(by: max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }
    public override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.option) {
            zoom(by: exp(event.scrollingDeltaY * 0.035), at: convert(event.locationInWindow, from: nil))
        } else {
            let rect = imageRect(transform)
            var next = transform
            next.centerX -= event.scrollingDeltaX / max(1, rect.width)
            next.centerY -= event.scrollingDeltaY / max(1, rect.height)
            publish(next)
        }
    }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
