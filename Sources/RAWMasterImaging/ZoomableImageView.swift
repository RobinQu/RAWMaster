import AppKit
import SwiftUI

extension NSEdgeInsets {
    public static let zero = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
}

public struct ImageTransform: Equatable, Sendable {
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
    /// Rect covered by a windowed bitmap inside the whole-canvas destination rect.
    ///
    /// `window` is normalized with a top-left origin, matching Core Image materialization and
    /// `DevelopmentPreviewFrame.window`. The canvas view is flipped, so the top edge maps to
    /// `destination.minY`. A `nil` window covers the whole destination.
    public static func windowRect(_ window: CGRect?, in destination: CGRect) -> CGRect {
        guard let window else { return destination }
        let rect = CGRect(x: destination.minX + window.minX * destination.width,
                          y: destination.minY + window.minY * destination.height,
                          width: window.width * destination.width,
                          height: window.height * destination.height)
        return rect.intersection(destination)
    }
    /// Normalized window of a whole-canvas `destination` that `bounds` can see, top-left origin.
    public static func visibleWindow(destination: CGRect, bounds: CGRect) -> CGRect? {
        guard destination.width > 0, destination.height > 0 else { return nil }
        let visible = destination.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let minX = max(0, (visible.minX - destination.minX) / destination.width)
        let minY = max(0, (visible.minY - destination.minY) / destination.height)
        let maxX = min(1, (visible.maxX - destination.minX) / destination.width)
        let maxY = min(1, (visible.maxY - destination.minY) / destination.height)
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// Expand `visible` by `margin` of its own size on every side, then clamp to the unit canvas.
    public static func servedWindow(visible: CGRect, margin: CGFloat) -> CGRect {
        let dx = visible.width * max(0, margin), dy = visible.height * max(0, margin)
        let minX = max(0, visible.minX - dx), minY = max(0, visible.minY - dy)
        let maxX = min(1, visible.maxX + dx), maxY = min(1, visible.maxY + dy)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// Keep room for two native RGBA8 bitmaps when the complete visible region fits.
    /// Use an outward-rounded visible region even when a single frame exceeds that allowance.
    public static func budgetedNativeWindow(visible: CGRect, nativeSize: CGSize, cacheBytes: Int, margin: CGFloat) -> CGRect? {
        guard let width = Int(exactly: nativeSize.width), let height = Int(exactly: nativeSize.height),
              width > 0, height > 0, cacheBytes >= 0, (0...0.5).contains(margin),
              [visible.minX, visible.minY, visible.maxX, visible.maxY].allSatisfy(\.isFinite),
              !visible.isEmpty else { return nil }
        let bounds = CGRect(origin: .zero, size: nativeSize)
        let unit = visible.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !unit.isEmpty else { return nil }
        let pixels = CGRect(x: unit.minX * nativeSize.width, y: unit.minY * nativeSize.height,
                            width: unit.width * nativeSize.width, height: unit.height * nativeSize.height)
            .integral.intersection(bounds)
        guard !pixels.isEmpty else { return nil }
        let allowance = cacheBytes / 2
        var best = pixels
        var low = 1
        var high = Int(margin * 10_000)
        while low <= high {
            let steps = (low + high) / 2
            let dx = ceil(pixels.width * CGFloat(steps) / 10_000)
            let dy = ceil(pixels.height * CGFloat(steps) / 10_000)
            let candidate = pixels.insetBy(dx: -dx, dy: -dy).intersection(bounds)
            let rowPixels = Int(candidate.width)
            guard rowPixels <= (Int.max - 63) / 4 else { return nil }
            let alignedRow = ((rowPixels * 4 + 63) / 64) * 64
            if Int(candidate.height) <= allowance / alignedRow {
                best = candidate
                low = steps + 1
            } else {
                high = steps - 1
            }
        }
        return CGRect(x: best.minX / nativeSize.width, y: best.minY / nativeSize.height,
                      width: best.width / nativeSize.width, height: best.height / nativeSize.height)
    }
    /// Snap a window to a `1/steps` grid so small pans keep the same cache identity.
    public static func quantized(_ window: CGRect, steps: Int) -> CGRect {
        guard steps > 1 else { return window }
        let step = 1 / CGFloat(steps)
        let minX = (window.minX / step).rounded(.down) * step
        let minY = (window.minY / step).rounded(.down) * step
        let maxX = min(1, (window.maxX / step).rounded(.up) * step)
        let maxY = min(1, (window.maxY / step).rounded(.up) * step)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// True when `window` fully covers `visible` (with a small tolerance for grid snapping).
    public static func window(_ window: CGRect, covers visible: CGRect, tolerance eps: CGFloat = 1e-4) -> Bool {
        return window.minX <= visible.minX + eps && window.minY <= visible.minY + eps
            && window.maxX >= visible.maxX - eps && window.maxY >= visible.maxY - eps
    }
    public static func fitScale(pixelSize: CGSize, viewport: CGSize,
                                fitInsets: NSEdgeInsets = .zero) -> CGFloat {
        let available = fitViewport(viewport, insets: fitInsets).size
        guard pixelSize.width > 0, pixelSize.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(available.width / pixelSize.width, available.height / pixelSize.height)
    }
    public static func actualPixelScale(pixelSize: CGSize, viewport: CGSize, backingScale: CGFloat,
                                        fitInsets: NSEdgeInsets = .zero) -> CGFloat {
        1 / (max(1, backingScale) * fitScale(pixelSize: pixelSize, viewport: viewport, fitInsets: fitInsets))
    }
    public static func pointScale(pixelSize: CGSize, viewport: CGSize,
                                  transform: ImageTransform, backingScale: CGFloat,
                                  fitInsets: NSEdgeInsets = .zero) -> CGFloat {
        transform.physicalMagnification.map { $0 / max(1, backingScale) }
            ?? (fitScale(pixelSize: pixelSize, viewport: viewport, fitInsets: fitInsets) * transform.scale)
    }
    public static func imageRect(pixelSize: CGSize, viewport: CGSize,
                                 transform: ImageTransform, backingScale: CGFloat,
                                 fitInsets: NSEdgeInsets = .zero) -> CGRect {
        let scale = pointScale(pixelSize: pixelSize, viewport: viewport, transform: transform,
                               backingScale: backingScale, fitInsets: fitInsets)
        let width = pixelSize.width * scale, height = pixelSize.height * scale
        var x: CGFloat, y: CGFloat
        if transform.physicalMagnification == nil, transform.scale == 1 {
            // FIT belongs to the unobscured safe viewport. Once the user zooms, the same
            // fit-relative scale continues smoothly while panning expands to the full canvas.
            let safe = fitViewport(viewport, insets: fitInsets)
            x = safe.minX + (safe.width - width) / 2
            y = safe.minY + (safe.height - height) / 2
        } else {
            x = width <= viewport.width ? (viewport.width - width) / 2 : viewport.width / 2 - transform.centerX * width
            y = height <= viewport.height ? (viewport.height - height) / 2 : viewport.height / 2 - transform.centerY * height
        }
        if abs(scale * backingScale - 1) < 0.001 {
            x = (x * backingScale).rounded() / backingScale
            y = (y * backingScale).rounded() / backingScale
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    private static func fitViewport(_ viewport: CGSize, insets: NSEdgeInsets) -> CGRect {
        let horizontal = max(0, min(viewport.width - 1, insets.left + insets.right))
        let vertical = max(0, min(viewport.height - 1, insets.top + insets.bottom))
        let left = max(0, min(insets.left, viewport.width - horizontal))
        let top = max(0, min(insets.top, viewport.height - vertical))
        return CGRect(x: left, y: top, width: max(1, viewport.width - horizontal),
                      height: max(1, viewport.height - vertical))
    }
}

public struct ImageFrameDrawEvent: Sendable {
    public let frameID: UUID
    public let drawBeganUptimeNanoseconds: UInt64
    public let drawReturnedUptimeNanoseconds: UInt64
    /// Dimensions of the frame raster. A cropped or resized frame can cover a larger canvas.
    public let imagePixelWidth: Int
    public let imagePixelHeight: Int
}

enum ImageCanvasInterpolationPolicy {
    static func resolve(exactPixels: Bool, lowLatency: Bool) -> NSImageInterpolation {
        if exactPixels { return .none }
        return lowLatency ? .medium : .high
    }
}

public struct ImageCanvasViewportSnapshot: Equatable, Sendable {
    public let frameID: UUID?
    public let viewportSize, imagePixelSize: CGSize
    public let imageRect: CGRect
    public let backingScale: CGFloat
    public let transform: ImageTransform
    public init(frameID: UUID?, viewportSize: CGSize, imagePixelSize: CGSize, imageRect: CGRect, backingScale: CGFloat, transform: ImageTransform) {
        self.frameID = frameID; self.viewportSize = viewportSize; self.imagePixelSize = imagePixelSize
        self.imageRect = imageRect; self.backingScale = backingScale; self.transform = transform
    }
}
public enum ImageCanvasPointerPhase: Equatable, Sendable { case began, changed, ended, cancelled }
public struct ImageCanvasPointerEvent: Sendable {
    public let phase: ImageCanvasPointerPhase
    public let gestureID: UUID
    public let beganFrameID: UUID?
    public let viewport: ImageCanvasViewportSnapshot
    public let locationInView: CGPoint
    public let pressure: Double
    public let supportsPressure: Bool
    public let modifiersRawValue: UInt64
    public let eventTimestamp: Double
    public init(phase: ImageCanvasPointerPhase, gestureID: UUID, beganFrameID: UUID?, viewport: ImageCanvasViewportSnapshot,
                locationInView: CGPoint, pressure: Double, supportsPressure: Bool, modifiersRawValue: UInt64, eventTimestamp: Double) {
        self.phase = phase; self.gestureID = gestureID; self.beganFrameID = beganFrameID; self.viewport = viewport
        self.locationInView = locationInView; self.pressure = pressure; self.supportsPressure = supportsPressure
        self.modifiersRawValue = modifiersRawValue; self.eventTimestamp = eventTimestamp
    }
}
public struct ImageCanvasHoverEvent: Sendable {
    public let viewport: ImageCanvasViewportSnapshot
    public let locationInView: CGPoint?
    public let modifiersRawValue: UInt64
    public init(viewport: ImageCanvasViewportSnapshot, locationInView: CGPoint?, modifiersRawValue: UInt64) {
        self.viewport = viewport; self.locationInView = locationInView; self.modifiersRawValue = modifiersRawValue
    }
}

public enum ImageCanvasDiagnosticEvent: Sendable {
    case installed(canvas: UUID, frame: UUID, at: UInt64)
    case drawn(canvas: UUID, frame: UUID, began: UInt64, returned: UInt64)
    case dismantled(canvas: UUID, at: UInt64)
}

public struct ZoomableImageView: NSViewRepresentable {
    public var image: NSImage?
    private weak var borrowedImage: NSImage?
    private weak var borrowedComparisonImage: NSImage?
    private weak var borrowedFallbackImage: NSImage?
    private weak var borrowedComparisonFallback: NSImage?
    private var comparisonWindow: CGRect?
    private var comparisonPresentation = ImageComparisonPresentation()
    public var actualPixels: Bool
    public var lowLatency = false
    @Binding public var transform: ImageTransform
    public var backgroundColor: NSColor
    public var onActualPixelsChange: ((Bool) -> Void)?
    public var onRequestDetail: (() -> Void)?
    public var onFreeZoom: (@MainActor (Bool, ImageCanvasViewportSnapshot) -> Void)?
    public var frameID: UUID?
    public var onFrameDrawn: (@MainActor @Sendable (ImageFrameDrawEvent) -> Void)?
    public var onCanvasDiagnostic: (@MainActor (ImageCanvasDiagnosticEvent) -> Void)?
    public var onPointerEvent: (@MainActor (ImageCanvasPointerEvent) -> Bool)?
    public var onViewportChange: (@MainActor (ImageCanvasViewportSnapshot) -> Void)?
    /// Normalized canvas window visible at 1:1. The owner requests a bitmap covering it.
    public var onVisibleWindow: (@MainActor (CGRect) -> Void)?
    /// Whole-canvas pixel size when `image` covers only `window` of the canvas.
    public var canvasPixelSize: CGSize?
    public var window: CGRect?
    public var onPointerHover: (@MainActor (ImageCanvasHoverEvent) -> Void)?
    public var onDoubleClick: (() -> Void)?
    public var fitInsets: NSEdgeInsets = .zero
    public init(image: NSImage?, actualPixels: Bool, transform: Binding<ImageTransform>,
                backgroundColor: NSColor = .controlBackgroundColor,
                onActualPixelsChange: ((Bool) -> Void)? = nil, onRequestDetail: (() -> Void)? = nil,
                frameID: UUID? = nil, onFrameDrawn: (@MainActor @Sendable (ImageFrameDrawEvent) -> Void)? = nil,
                onPointerEvent: (@MainActor (ImageCanvasPointerEvent) -> Bool)? = nil,
                onViewportChange: (@MainActor (ImageCanvasViewportSnapshot) -> Void)? = nil,
                onPointerHover: (@MainActor (ImageCanvasHoverEvent) -> Void)? = nil,
                onDoubleClick: (() -> Void)? = nil,
                onCanvasDiagnostic: (@MainActor (ImageCanvasDiagnosticEvent) -> Void)? = nil,
                onVisibleWindow: (@MainActor (CGRect) -> Void)? = nil,
                window: CGRect? = nil, canvasPixelSize: CGSize? = nil) {
        self.image = image; self.actualPixels = actualPixels; self._transform = transform
        self.backgroundColor = backgroundColor
        self.onActualPixelsChange = onActualPixelsChange; self.onRequestDetail = onRequestDetail
        self.frameID = frameID; self.onFrameDrawn = onFrameDrawn
        self.onPointerEvent = onPointerEvent; self.onViewportChange = onViewportChange
        self.onPointerHover = onPointerHover; self.onDoubleClick = onDoubleClick
        self.onCanvasDiagnostic = onCanvasDiagnostic
        self.onVisibleWindow = onVisibleWindow; self.window = window; self.canvasPixelSize = canvasPixelSize
    }
    /// The caller owns this exact image until the canvas installs it.
    public func borrowingImage(_ image: NSImage?) -> Self {
        var view = self
        view.image = nil
        view.borrowedImage = image
        return view
    }
    public func lowLatency(_ enabled: Bool) -> Self {
        var view = self
        view.lowLatency = enabled
        return view
    }
    public func trackingFreeZoom(_ callback: @escaping @MainActor (Bool, ImageCanvasViewportSnapshot) -> Void) -> Self {
        var view = self
        view.onFreeZoom = callback
        return view
    }
    public func fitting(around insets: NSEdgeInsets) -> Self {
        var view = self
        view.fitInsets = insets
        return view
    }
    public func beforeAfter(_ image: NSImage?, split: CGFloat) -> Self {
        comparison(image, presentation: .init(mode: .wipeHorizontal, amount: split))
    }
    public func comparison(_ image: NSImage?, presentation: ImageComparisonPresentation,
                           window: CGRect? = nil, fallback: NSImage? = nil) -> Self {
        var view = self
        view.borrowedComparisonImage = image
        view.borrowedComparisonFallback = fallback
        view.comparisonWindow = window
        view.comparisonPresentation = presentation
        return view
    }
    public func fallbackImage(_ image: NSImage?) -> Self {
        var view = self
        view.borrowedFallbackImage = image
        return view
    }
    public func makeNSView(context: Context) -> ImageCanvas {
        let canvas = ImageCanvas()
        canvas.setAccessibilityLabel("照片细节。双击切换适合窗口与原始像素；拖动平移，捏合缩放。")
        return canvas
    }
    public func updateNSView(_ canvas: ImageCanvas, context: Context) {
        updateCanvas(canvas)
    }
    @MainActor func updateCanvas(_ canvas: ImageCanvas) {
        let image = self.image ?? borrowedImage
        canvas.onTransform = { transform = $0 }
        canvas.onActualPixelsChange = onActualPixelsChange
        canvas.onFreeZoom = onFreeZoom
        canvas.onVisibleWindow = onVisibleWindow
        canvas.onRequestDetail = { [weak canvas] in
            if let canvas { onVisibleWindow?(canvas.visibleCanvasWindow) }
            onRequestDetail?()
        }
        canvas.onDoubleClick = onDoubleClick
        canvas.frameID = frameID; canvas.onFrameDrawn = onFrameDrawn
        canvas.setInteractionHandlers(pointer:onPointerEvent,viewport:onViewportChange,hover:onPointerHover)
        canvas.update(image: image, actualPixels: actualPixels, transform: transform, backgroundColor: backgroundColor,
                      lowLatency: lowLatency, fitInsets: fitInsets,
                      comparisonImage: borrowedComparisonImage, comparison: comparisonPresentation,
                      window: window, canvasPixelSize: canvasPixelSize, fallbackImage: borrowedFallbackImage,
                      comparisonWindow: comparisonWindow, comparisonFallback: borrowedComparisonFallback)
        if onCanvasDiagnostic != nil || canvas.hasCanvasDiagnostic {
            canvas.updateCanvasDiagnostic(onCanvasDiagnostic, installedFrame: image == nil ? nil : frameID)
        }
    }
    public static func dismantleNSView(_ view: ImageCanvas, coordinator: ()) {
        view.detachFromRepresentable()
    }
}

public final class ImageCanvas: NSView {
    var frameID: UUID?
    var onFrameDrawn: (@MainActor @Sendable (ImageFrameDrawEvent) -> Void)?
    private var lastDrawnFrameID: UUID?
    private var canvasDiagnostic: (@MainActor (ImageCanvasDiagnosticEvent) -> Void)?
    private var diagnosticCanvasID: UUID?
    var qaMainOwnerStoreForTesting: PreviewQAMainPresentationWitness.Store?
    private var diagnosticInstalledFrame: UUID?
    private var lastDiagnosticDrawnFrameID: UUID?
    var hasCanvasDiagnostic: Bool { canvasDiagnostic != nil }

    func updateCanvasDiagnostic(_ sink: (@MainActor (ImageCanvasDiagnosticEvent) -> Void)?, installedFrame: UUID?) {
        guard let sink else { endCanvasDiagnostic(); return }
        canvasDiagnostic = sink
        let id = diagnosticCanvasID ?? UUID()
        diagnosticCanvasID = id
        guard diagnosticInstalledFrame != installedFrame else { return }
        diagnosticInstalledFrame = installedFrame
        if let installedFrame {
            sink(.installed(canvas: id, frame: installedFrame, at: DispatchTime.now().uptimeNanoseconds))
        }
    }

    func endCanvasDiagnostic() {
        if let canvasDiagnostic, let diagnosticCanvasID {
            canvasDiagnostic(.dismantled(canvas: diagnosticCanvasID, at: DispatchTime.now().uptimeNanoseconds))
        }
        canvasDiagnostic = nil
        diagnosticCanvasID = nil
        diagnosticInstalledFrame = nil
        lastDiagnosticDrawnFrameID = nil
    }
    private var image: NSImage?
    private var comparisonImage: NSImage?
    private var fallbackImage: NSImage?
    private var comparisonFallback: NSImage?
    private var comparisonWindow: CGRect?
    private var comparison = ImageComparisonPresentation()
    var invalidationObserverForTesting: (() -> Void)?
    private var backgroundColor: NSColor = .controlBackgroundColor
    private var resolvedBackgroundColor: CGColor?
    private var transform = ImageTransform()
    private var actualPixels = false
    private var lowLatency = false
    private var fitInsets: NSEdgeInsets = .zero
    private var dragOrigin: NSPoint?
    private var dragTransform = ImageTransform()
    var onTransform: ((ImageTransform) -> Void)?
    var onActualPixelsChange: ((Bool) -> Void)?
    var onRequestDetail: (() -> Void)?
    var onFreeZoom: (@MainActor (Bool, ImageCanvasViewportSnapshot) -> Void)?
    private var zoomStart: (transform: ImageTransform, actualPixels: Bool)?
    private var zoomEndTask: Task<Void, Never>?
    var onDoubleClick: (() -> Void)?
    private var onPointerEvent: (@MainActor (ImageCanvasPointerEvent) -> Bool)?
    private var onViewportChange: (@MainActor (ImageCanvasViewportSnapshot) -> Void)?
    private var onPointerHover: (@MainActor (ImageCanvasHoverEvent) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private struct PointerOwner {
        let id: UUID
        let frameID: UUID?
        let callback: @MainActor (ImageCanvasPointerEvent) -> Bool
        var lastPoint: CGPoint
    }
    private var pointerOwner: PointerOwner?
    private var pointerEpoch: UInt64 = 0
    private var lastViewport: ImageCanvasViewportSnapshot?
    private var lastVisibleWindow: CGRect?
    var onVisibleWindow: (@MainActor (CGRect) -> Void)?
    /// Whole-canvas pixel size when `image` covers only `window` of the canvas.
    private var canvasPixelSize: CGSize?
    /// Normalized top-left window of the canvas that `image` covers. `nil` is the whole canvas.
    private var frameWindow: CGRect?
    private var windowObserver: NSObjectProtocol?
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    private var pixelSize: CGSize {
        // A windowed frame navigates and zooms as the whole canvas, not as its own bitmap.
        if let canvasPixelSize, canvasPixelSize.width > 0, canvasPixelSize.height > 0 { return canvasPixelSize }
        guard let image else { return .zero }
        return rasterPixelSize(image)
    }
    private func rasterPixelSize(_ image: NSImage) -> CGSize {
        // Shared previews draw their producer's CGImage directly. Retina representations
        // synthesized by AppKit are display caches and must not redefine zoom or hit testing.
        if Self.drawsSharedRaster, comparisonImage == nil, let raster = PreviewSharedImageBridge.canvasRaster(for: image) {
            return CGSize(width: raster.width, height: raster.height)
        }
        let rep = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        return CGSize(width: rep?.pixelsWide ?? Int(image.size.width), height: rep?.pixelsHigh ?? Int(image.size.height))
    }
    private var backing: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    func update(image: NSImage?, actualPixels: Bool, transform: ImageTransform,
                backgroundColor: NSColor = .controlBackgroundColor, lowLatency: Bool = false,
                fitInsets: NSEdgeInsets = .zero, comparisonImage: NSImage? = nil,
                comparisonSplit: CGFloat = 0.5, comparison requestedComparison: ImageComparisonPresentation? = nil,
                window: CGRect? = nil, canvasPixelSize: CGSize? = nil, fallbackImage: NSImage? = nil,
                comparisonWindow: CGRect? = nil, comparisonFallback: NSImage? = nil) {
        let enteringActual = actualPixels && !self.actualPixels
        var resolvedTransform = transform
        if actualPixels { resolvedTransform.physicalMagnification = 1 }
        let insetsChanged = !NSEdgeInsetsEqual(self.fitInsets, fitInsets)
        var comparison = requestedComparison ?? .init(amount: comparisonSplit)
        comparison.amount = comparison.mode == .mix ? max(0, min(1, comparison.amount)) : max(0.05, min(0.95, comparison.amount))
        let geometryChanged = self.frameWindow != window || self.canvasPixelSize != canvasPixelSize
        let changed = self.image !== image || self.actualPixels != actualPixels
            || self.transform != resolvedTransform || self.lowLatency != lowLatency || insetsChanged
            || self.comparisonImage !== comparisonImage || self.comparison != comparison
            || self.fallbackImage !== fallbackImage || self.comparisonFallback !== comparisonFallback
            || self.comparisonWindow != comparisonWindow || geometryChanged
        self.image = image
        self.fallbackImage = fallbackImage
        self.comparisonFallback = comparisonFallback
        self.comparisonWindow = comparisonWindow
        let backgroundChanged = !self.backgroundColor.isEqual(backgroundColor)
        if resolvedBackgroundColor == nil || backgroundChanged {
            self.backgroundColor = backgroundColor
            resolveBackgroundColor()
        }
        self.actualPixels = actualPixels
        self.transform = resolvedTransform
        self.frameWindow = window
        self.canvasPixelSize = canvasPixelSize
        self.lowLatency = lowLatency
        self.fitInsets = fitInsets
        self.comparisonImage = comparisonImage
        self.comparison = comparison
        if changed || backgroundChanged {
            needsDisplay = true
            invalidationObserverForTesting?()
        }
        if enteringActual {
            let next = self.transform
            // All panes publish the same physical value, never their different fit scales.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.actualPixels, self.transform == next else { return }
                self.onTransform?(next)
            }
        }
    }
    public override func layout() { super.layout(); needsDisplay = true; publishViewport() }
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); needsDisplay = true; publishViewport()
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
                                         transform: state, backingScale: backing, fitInsets: fitInsets)
    }
    private func imageRect(_ state: ImageTransform) -> CGRect {
        ImageViewportGeometry.imageRect(pixelSize: pixelSize, viewport: bounds.size,
                                        transform: state, backingScale: backing, fitInsets: fitInsets)
    }
    func setInteractionHandlers(pointer: (@MainActor (ImageCanvasPointerEvent) -> Bool)?, viewport: (@MainActor (ImageCanvasViewportSnapshot) -> Void)?,
                                hover: (@MainActor (ImageCanvasHoverEvent) -> Void)? = nil) {
        if pointer == nil { cancelPointer() }
        onPointerEvent = pointer; onViewportChange = viewport
        let trackingChanged = (onPointerHover == nil) != (hover == nil)
        onPointerHover = hover
        if trackingChanged { updateTrackingAreas() }
        if viewport == nil { lastViewport = nil }
        updateWindowObserver()
    }
    func clearInteractionHandlers() {
        cancelPointer(); onPointerEvent = nil; onViewportChange = nil; lastViewport = nil
        onPointerHover = nil
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea); self.hoverTrackingArea = nil }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
    }
    @MainActor func detachFromRepresentable() {
        let qaStore = PreviewQAMainPresentationWitness.resolvedStore(qaMainOwnerStoreForTesting)
        let qaCanvas = diagnosticCanvasID, qaFrame = frameID
        let qaTicket = qaStore?.ticketID(for: image) // Only UUID escapes; canvas already owns the image.
        endCanvasDiagnostic()
        clearInteractionHandlers()
        // Drop only this canvas's ownership. Other presentation aliases keep their bytes.
        image = nil
        comparisonImage = nil
        fallbackImage = nil; comparisonFallback = nil; comparisonWindow = nil
        frameID = nil
        lastDrawnFrameID = nil
        onFrameDrawn = nil
        onTransform = nil
        onActualPixelsChange = nil
        onRequestDetail = nil
        onFreeZoom = nil
        onVisibleWindow = nil
        zoomEndTask?.cancel(); zoomEndTask = nil; zoomStart = nil
        onDoubleClick = nil
        PreviewQAMainPresentationWitness.canvasCleared(store: qaStore, canvasID: qaCanvas, frameID: qaFrame,
            ticketID: qaTicket, fieldsCleared: image == nil && frameID == nil && lastDrawnFrameID == nil &&
                onFrameDrawn == nil && onTransform == nil && onActualPixelsChange == nil && onRequestDetail == nil && onDoubleClick == nil &&
                onPointerEvent == nil && onViewportChange == nil && onPointerHover == nil && lastViewport == nil &&
                hoverTrackingArea == nil && windowObserver == nil && canvasDiagnostic == nil)
    }
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            cancelPointer()
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        }
        super.viewWillMove(toWindow:newWindow)
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindowObserver()
    }
    private func updateWindowObserver() {
        if onPointerEvent == nil, let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil
        }
        if onPointerEvent != nil, let window, windowObserver == nil {
            windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelPointer() }
            }
        }
    }
    public override func resignFirstResponder() -> Bool { cancelPointer(); return super.resignFirstResponder() }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea); self.hoverTrackingArea = nil }
        guard onPointerHover != nil else { return }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTrackingArea = area
    }
    private func publishHover(_ event: NSEvent, inside: Bool) {
        onPointerHover?(.init(viewport: viewportSnapshot,
            locationInView: inside ? convert(event.locationInWindow, from: nil) : nil,
            modifiersRawValue: UInt64(event.modifierFlags.rawValue)))
    }
    public override func mouseMoved(with event: NSEvent) { publishHover(event, inside: true); super.mouseMoved(with: event) }
    public override func mouseEntered(with event: NSEvent) { publishHover(event, inside: true); super.mouseEntered(with: event) }
    public override func mouseExited(with event: NSEvent) { publishHover(event, inside: false); super.mouseExited(with: event) }
    public override func flagsChanged(with event: NSEvent) { publishHover(event, inside: true); super.flagsChanged(with: event) }
    var viewportSnapshot: ImageCanvasViewportSnapshot {
        .init(frameID:frameID,viewportSize:bounds.size,imagePixelSize:pixelSize,imageRect:imageRect(transform),backingScale:backing,transform:transform)
    }
    private func publishViewport() {
        publishVisibleWindow()
        guard let onViewportChange else { return }
        let snapshot = viewportSnapshot
        guard snapshot != lastViewport else { return }
        lastViewport = snapshot; onViewportChange(snapshot)
    }
    /// Normalized canvas window the view can see right now, top-left origin.
    var visibleCanvasWindow: CGRect {
        let canvas = imageRect(transform)
        return ImageViewportGeometry.visibleWindow(destination: canvas, bounds: bounds) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    /// Report the normalized canvas window the view can see, so the owner can request a
    /// matching 1:1 bitmap. Only published while the canvas is showing native pixels.
    private func publishVisibleWindow() {
        guard let onVisibleWindow, actualPixels else { return }
        let canvas = imageRect(transform)
        guard let visible = ImageViewportGeometry.visibleWindow(destination: canvas, bounds: bounds) else { return }
        guard visible != lastVisibleWindow else { return }
        lastVisibleWindow = visible; onVisibleWindow(visible)
    }
    private func pointerEvent(_ phase: ImageCanvasPointerPhase, owner: PointerOwner, event: NSEvent?) -> ImageCanvasPointerEvent {
        let tablet = event.map { $0.type == .tabletPoint || $0.subtype == .tabletPoint } ?? false
        let point = event.map { convert($0.locationInWindow,from:nil) } ?? owner.lastPoint
        let rawPressure = Double(event?.pressure ?? 0)
        return .init(phase:phase,gestureID:owner.id,beganFrameID:owner.frameID,viewport:viewportSnapshot,locationInView:point,
            pressure:tablet && rawPressure.isFinite ? min(1,max(0,rawPressure)):1,supportsPressure:tablet,
            modifiersRawValue:UInt64(event?.modifierFlags.rawValue ?? 0),eventTimestamp:event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
    }
    private func cancelPointer() {
        pointerEpoch &+= 1
        guard let owner = pointerOwner else { return }
        pointerOwner = nil; _ = owner.callback(pointerEvent(.cancelled,owner:owner,event:nil))
    }
    private static let drawsSharedRaster = ProcessInfo.processInfo.environment["RAWMASTER_CANVAS_LEGACY_NSIMAGE"] != "1"
    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // AppKit can supply a dirty region extending beyond this view; a magnified
        // image must never paint over adjacent SwiftUI controls or compare panes.
        bounds.clip()
        publishViewport()
        if resolvedBackgroundColor == nil { resolveBackgroundColor() }
        if let color = resolvedBackgroundColor {
            NSGraphicsContext.current?.cgContext.setFillColor(color)
            NSGraphicsContext.current?.cgContext.fill(bounds)
        }
        guard let image else { return }
        let exactPixels = abs(pointScale(transform) * backing - 1) < 0.001
        NSGraphicsContext.current?.imageInterpolation = ImageCanvasInterpolationPolicy.resolve(exactPixels: exactPixels, lowLatency: lowLatency)
        let diagnosticSnapshot = canvasDiagnostic.flatMap { sink in
            diagnosticCanvasID.flatMap { canvas in frameID.map { (sink, canvas, $0) } }
        }
        let began = DispatchTime.now().uptimeNanoseconds
        let canvas = imageRect(transform)
        // A windowed frame draws only the part of the canvas it actually covers.
        let destination = ImageViewportGeometry.windowRect(frameWindow, in: canvas)
        let drawn = destination.intersection(bounds).intersection(dirtyRect)
        let token = ImagePerformanceTelemetry.shared.begin(operation: "画布绘制",
          stage: comparisonImage == nil ? "主图" : "比较", queue: "画布", boundary: .canvasDrawReturn)
        defer {
            let area = drawn.isEmpty ? 0 : Int(ceil(drawn.width * backing) * ceil(drawn.height * backing))
            ImagePerformanceTelemetry.shared.end(token, pixelCount: area)
        }
        if let comparisonImage {
            drawComparison(current: image, reference: comparisonImage, canvas: canvas)
        } else {
            drawFallback(fallbackImage, under: destination, canvas: canvas)
            drawMainRaster(image, in: destination)
        }
        if let (sink, canvas, frame) = diagnosticSnapshot, frame != lastDiagnosticDrawnFrameID {
            lastDiagnosticDrawnFrameID = frame
            sink(.drawn(canvas: canvas, frame: frame, began: began, returned: DispatchTime.now().uptimeNanoseconds))
        }
        if let frameID, frameID != lastDrawnFrameID, let callback = onFrameDrawn {
            lastDrawnFrameID = frameID
            let returned = DispatchTime.now().uptimeNanoseconds
            let raster = rasterPixelSize(image)
            let event = ImageFrameDrawEvent(frameID: frameID, drawBeganUptimeNanoseconds: began,
                drawReturnedUptimeNanoseconds: returned,
                imagePixelWidth: Int(raster.width), imagePixelHeight: Int(raster.height))
            // AppKit draw return only; this is not WindowServer presentation or input-to-photon.
            DispatchQueue.main.async { callback(event) }
        }
    }
    private func drawMainRaster(_ image: NSImage, in destination: CGRect) {
        if Self.drawsSharedRaster, let raster = PreviewSharedImageBridge.canvasRaster(for: image), let graphics = NSGraphicsContext.current {
            // NSView and offscreen/printing contexts can use opposite coordinate systems.
            let cg = graphics.cgContext
            cg.saveGState()
            cg.setBlendMode(.normal)
            if graphics.isFlipped {
                cg.translateBy(x: destination.minX, y: destination.maxY)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(raster, in: CGRect(origin: .zero, size: destination.size))
            } else {
                cg.draw(raster, in: destination)
            }
            cg.restoreGState()
        } else {
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        }
    }
    private func drawFallback(_ image: NSImage?, under destination: CGRect, canvas: CGRect,
                              operation: NSCompositingOperation = .sourceOver, fraction: CGFloat = 1) {
        let visible = canvas.intersection(bounds)
        guard let image, !visible.isEmpty, !destination.contains(visible) else { return }
        let outside = NSBezierPath(rect: visible)
        let overlap = destination.intersection(visible)
        if !overlap.isEmpty { outside.appendRect(overlap) }
        outside.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        outside.addClip()
        image.draw(in: canvas, from: .zero, operation: operation, fraction: fraction, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawComparison(current: NSImage, reference: NSImage, canvas: CGRect) {
        func draw(_ image: NSImage, operation: NSCompositingOperation = .sourceOver, fraction: CGFloat = 1) {
            let isCurrent = image === current
            let destination = ImageViewportGeometry.windowRect(isCurrent ? frameWindow : comparisonWindow, in: canvas)
            drawFallback(isCurrent ? fallbackImage : comparisonFallback, under: destination, canvas: canvas,
                         operation: operation, fraction: fraction)
            image.draw(in: destination, from: .zero, operation: operation, fraction: fraction,
                       respectFlipped: true, hints: nil)
        }
        switch comparison.mode {
        case .wipeHorizontal, .wipeVertical:
            // Default: reference left/top, current right/bottom. Inversion swaps those regions.
            draw(comparison.inverted ? current : reference)
            NSGraphicsContext.saveGraphicsState()
            let region: CGRect
            switch comparison.mode {
            case .wipeHorizontal:
                region = CGRect(x: comparison.amount * bounds.width, y: 0,
                                width: bounds.width * (1 - comparison.amount), height: bounds.height)
            default:
                region = CGRect(x: 0, y: comparison.amount * bounds.height,
                                width: bounds.width, height: bounds.height * (1 - comparison.amount))
            }
            region.clip()
            draw(comparison.inverted ? reference : current)
            NSGraphicsContext.restoreGraphicsState()
        case .mix:
            draw(reference)
            draw(current, fraction: comparison.inverted ? 1 - comparison.amount : comparison.amount)
        case .difference:
            // Explicit display-space diagnostic: equal displayed pixels become black.
            NSGraphicsContext.saveGraphicsState()
            canvas.clip()
            draw(reference)
            draw(current, operation: .difference)
            NSGraphicsContext.restoreGraphicsState()
        case .checkerboard:
            draw(comparison.inverted ? current : reference)
            let tile: CGFloat = 64
            let rows = Int(ceil(bounds.height / tile)), columns = Int(ceil(bounds.width / tile))
            guard rows > 0, columns > 0 else { return }
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let tileRect = CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile,
                                          width: tile, height: tile).intersection(canvas)
                    guard !tileRect.isNull, tileRect.width > 0, tileRect.height > 0 else { continue }
                    NSGraphicsContext.saveGraphicsState()
                    tileRect.clip()
                    draw(comparison.inverted ? reference : current)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
        }
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
        publishViewport()
    }
    public override func mouseDown(with event: NSEvent) {
        cancelPointer()
        window?.makeFirstResponder(self)
        if image != nil, event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        if image != nil, let onPointerEvent {
            let owner = PointerOwner(id:UUID(),frameID:frameID,callback:onPointerEvent,lastPoint:convert(event.locationInWindow,from:nil))
            let epoch = pointerEpoch
            if onPointerEvent(pointerEvent(.began,owner:owner,event:event)) {
                if epoch == pointerEpoch, self.onPointerEvent != nil { pointerOwner = owner }
                else { _ = owner.callback(pointerEvent(.cancelled,owner:owner,event:nil)) }
                dragOrigin = nil; return
            }
        }
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
        if var owner = pointerOwner {
            owner.lastPoint = convert(event.locationInWindow,from:nil); pointerOwner = owner
            _ = owner.callback(pointerEvent(.changed,owner:owner,event:event)); return
        }
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil), rect = imageRect(dragTransform)
        var next = dragTransform
        next.centerX -= (point.x - origin.x) / max(1, rect.width)
        next.centerY -= (point.y - origin.y) / max(1, rect.height)
        publish(next)
    }
    public override func mouseUp(with event: NSEvent) {
        if let owner = pointerOwner { pointerOwner = nil; _ = owner.callback(pointerEvent(.ended,owner:owner,event:event)) }
        dragOrigin = nil
    }
    private func zoom(by factor: CGFloat, at point: NSPoint) {
        let rect = imageRect(transform)
        let normalizedX = (point.x - rect.minX) / max(1, rect.width)
        let normalizedY = (point.y - rect.minY) / max(1, rect.height)
        var next = transform
        let leavingActualPixels = actualPixels
        if let physical = next.physicalMagnification {
            if onFreeZoom != nil {
                next.scale = max(1, min(64, pointScale(transform) * factor / pointScale(.init())))
                next.physicalMagnification = nil
            } else {
                next.physicalMagnification = max(0.025, min(16, physical * factor))
            }
        } else { next.scale = max(1, min(64, next.scale * factor)) }
        let width = pixelSize.width * pointScale(next), height = pixelSize.height * pointScale(next)
        next.centerX = normalizedX - (point.x - bounds.midX) / max(1, width)
        next.centerY = normalizedY - (point.y - bounds.midY) / max(1, height)
        actualPixels = false
        if leavingActualPixels { onActualPixelsChange?(false) }
        publish(next)
        if onFreeZoom == nil, next.scale > 1 || next.physicalMagnification != nil { onRequestDetail?() }
    }
    func handleZoom(factor: CGFloat, at point: NSPoint, phase: NSEvent.Phase) {
        guard onFreeZoom != nil else {
            if factor != 1 { zoom(by: factor, at: point) }
            return
        }
        if phase.contains(.began) || (zoomStart == nil && factor != 1) {
            zoomStart = (transform, actualPixels)
        }
        if phase.contains(.cancelled) {
            if let start = zoomStart, start.transform != transform {
                actualPixels = start.actualPixels
                publish(start.transform)
                if actualPixels { onActualPixelsChange?(true) }
            }
            finishFreeZoom()
            return
        }
        if factor != 1 { zoom(by: factor, at: point) }
        if phase.contains(.ended) {
            finishFreeZoom()
        } else if zoomStart != nil {
            onFreeZoom?(true, viewportSnapshot)
            if phase.isEmpty {
                zoomEndTask?.cancel()
                zoomEndTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                    self?.finishFreeZoom()
                }
            }
        }
    }
    private func finishFreeZoom() {
        zoomEndTask?.cancel(); zoomEndTask = nil
        guard zoomStart != nil else { return }
        zoomStart = nil
        onFreeZoom?(false, viewportSnapshot)
    }
    public override func magnify(with event: NSEvent) {
        cancelPointer()
        handleZoom(factor: max(0.1, 1 + event.magnification), at: convert(event.locationInWindow, from: nil), phase: event.phase)
    }
    public override func endGesture(with event: NSEvent) {
        finishFreeZoom()
        super.endGesture(with: event)
    }
    public override func scrollWheel(with event: NSEvent) {
        cancelPointer()
        if !event.hasPreciseScrollingDeltas || event.modifierFlags.contains(.option) {
            if event.momentumPhase.isEmpty {
                handleZoom(factor: exp(event.scrollingDeltaY * 0.035), at: convert(event.locationInWindow, from: nil), phase: event.phase)
            }
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
