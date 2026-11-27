import SwiftUI
import AppKit
import RAWMasterCore
import RAWMasterImaging

struct EditingDevelopmentCropFrame {
    let context: EditingInteractionContext
    let frameID: UUID
    let sourceGeneration: UInt64
    let geometry: DevelopmentGeometryV3 // exact presented geometry with crop identity
    let plane: DevelopmentGeometryCropPlaneV3
    let outputPixelSize: CGSize
}

@MainActor struct PhotosCropCanvas: View {
    @ObservedObject var editing: EditingController
    let context: EditingInteractionContext
    @Binding var transform: ImageTransform
    @StateObject private var interaction: PhotosCropTrackingController
    init(editing: EditingController, context: EditingInteractionContext, transform: Binding<ImageTransform>) {
        self.editing = editing; self.context = context; self._transform = transform
        self._interaction = StateObject(wrappedValue: PhotosCropTrackingController(editing: editing, context: context))
    }
    var body: some View {
        ZStack {
            if editing.recipe.sceneGraph != nil {
                EditingSceneCanvas(frame: editing.sceneFrame, target: editing.sceneTarget, requestHDR: editing.sceneRequestedHDR && !editing.sceneVisualizeHDR,
                    fitInsets: EditingLayout.fitInsets, transform: $transform, onDisplay: editing.setSceneDisplay,
                    onSampling: editing.setSceneSampling, onPresentationError: editing.scenePresentationFailed,
                    onPhotographicPointer: interaction.pointer, onPhotographicViewport: interaction.scheduleViewport,
                    onPhotographicDoubleClick: { editing.completeDevelopmentCrop(context: context) })
                    .accessibilityLabel("裁切画布")
            } else {
            ZoomableImageView(image: editing.preview, actualPixels: false, transform: $transform, backgroundColor: editing.darkroomBackground.nsColor,
                frameID: editing.previews.primary.frame?.id, onFrameDrawn: { editing.previews.primary.didDraw($0) },
                onPointerEvent: interaction.pointer, onViewportChange: interaction.scheduleViewport,
                onPointerHover: interaction.hover,
                onDoubleClick: { editing.completeDevelopmentCrop(context: context) })
                .fitting(around: EditingLayout.fitInsets)
                .accessibilityLabel("裁切画布")
                .accessibilityHint("拖动边角调整范围，框内移动，框外拉直。也可使用右侧裁切比例、拉直和精确位置数值。")
            }
            if let presentation = interaction.overlayPresentation() {
                overlay(presentation.viewport, frame: presentation.frame)
            }
        }.id(context)
            .onDisappear { interaction.cancel() }
    }
    private func overlay(_ viewport: ImageCanvasViewportSnapshot, frame: EditingDevelopmentCropFrame) -> some View {
        let rect = PhotosCropInteraction.screenRect(editing.developmentGeometry.crop, imageRect: viewport.imageRect, plane: frame.plane)
        return Canvas { context, _ in
            var mask = Path(); mask.addRect(viewport.imageRect); mask.addRect(rect)
            context.fill(mask, with: .color(.black.opacity(0.45)), style: .init(eoFill: true))
            context.stroke(Path(rect), with: .color(.white), lineWidth: 1)
            var guides = Path()
            func line(_ a: CGPoint, _ b: CGPoint) { guides.move(to: a); guides.addLine(to: b) }
            let topLeft = CGPoint(x: rect.minX, y: rect.minY), topRight = CGPoint(x: rect.maxX, y: rect.minY)
            let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY), bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            switch editing.cropOverlayStyle {
            case .ruleOfThirds, .goldenRatio:
                let fractions = editing.cropOverlayStyle == .ruleOfThirds ? [1.0 / 3, 2.0 / 3] : [0.382, 0.618]
                for f in fractions {
                    line(.init(x: rect.minX + rect.width * f, y: rect.minY), .init(x: rect.minX + rect.width * f, y: rect.maxY))
                    line(.init(x: rect.minX, y: rect.minY + rect.height * f), .init(x: rect.maxX, y: rect.minY + rect.height * f))
                }
            case .diagonal:
                if editing.cropOverlayTurn % 2 == 0 { line(topLeft, bottomRight) } else { line(topRight, bottomLeft) }
            case .triangle:
                if editing.cropOverlayTurn % 2 == 0 {
                    line(topLeft, bottomRight); line(bottomLeft, center); line(topRight, center)
                } else {
                    line(topRight, bottomLeft); line(topLeft, center); line(bottomRight, center)
                }
            case .none: break
            }
            context.stroke(guides, with: .color(.white.opacity(0.45)), lineWidth: 0.5)

            // Camera Raw-style crop boundary: a hairline rectangle plus bold L-shaped corners.
            // The dark under-stroke keeps the corners readable over both highlights and shadows.
            let arm = min(28, max(14, min(rect.width, rect.height) * 0.12))
            var corners = Path()
            func corner(_ point: CGPoint, _ horizontal: CGFloat, _ vertical: CGFloat) {
                corners.move(to: CGPoint(x: point.x + horizontal * arm, y: point.y))
                corners.addLine(to: point)
                corners.addLine(to: CGPoint(x: point.x, y: point.y + vertical * arm))
            }
            corner(topLeft, 1, 1); corner(topRight, -1, 1)
            corner(bottomLeft, 1, -1); corner(bottomRight, -1, -1)
            context.stroke(corners, with: .color(.black.opacity(0.5)),
                style: .init(lineWidth: 5, lineCap: .square, lineJoin: .miter))
            context.stroke(corners, with: .color(.white.opacity(0.96)),
                style: .init(lineWidth: 2.5, lineCap: .square, lineJoin: .miter))

            // Lightflow's 18×4 edge-centre grips make the stretch targets visible without
            // introducing separate buttons or changing the underlying eight-handle hit model.
            let edgeGrips = [
                CGRect(x: rect.midX - 9, y: rect.minY - 2, width: 18, height: 4),
                CGRect(x: rect.midX - 9, y: rect.maxY - 2, width: 18, height: 4),
                CGRect(x: rect.minX - 2, y: rect.midY - 9, width: 4, height: 18),
                CGRect(x: rect.maxX - 2, y: rect.midY - 9, width: 4, height: 18)
            ]
            for grip in edgeGrips {
                context.fill(Path(grip.insetBy(dx: -1, dy: -1)), with: .color(.black.opacity(0.45)))
                context.fill(Path(grip), with: .color(.white.opacity(0.96)))
            }

            if rect.width > 120, rect.height > 60 {
                let crop = editing.developmentGeometry.crop
                let width = Int((crop.width * frame.plane.rect.width).rounded())
                let height = Int((crop.height * frame.plane.rect.height).rounded())
                let angle = editing.developmentGeometry.straightenDegrees
                var label = "\(width) × \(height)"
                if abs(angle) > 0.05 { label += " · " + DevelopmentNumericText.format(angle, fractionDigits: 1) + "°" }
                let badgeWidth = min(rect.width - 16, max(76, CGFloat(label.count) * 6.5 + 12))
                let badgeRect = CGRect(x: rect.minX + 8, y: rect.minY + 8, width: badgeWidth, height: 22)
                context.fill(Path(roundedRect: badgeRect, cornerRadius: 5), with: .color(.black.opacity(0.52)))
                context.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white),
                    at: CGPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 5), anchor: .topLeading)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

}

/// Pointer sequence state only; Controller remains the sole recipe authority. No image/native task
/// is retained here. Captured native callbacks keep this original context until the sequence ends.
@MainActor final class PhotosCropTrackingController: ObservableObject {
    let editing: EditingController
    let context: EditingInteractionContext
    @Published private(set) var viewport: ImageCanvasViewportSnapshot?
    private(set) var hoveredHandle: PhotosCropHandle?
    private var tracking: Tracking?
    private var frozenRotation: OverlayPresentation?
    init(editing: EditingController, context: EditingInteractionContext) { self.editing = editing; self.context = context }
    func scheduleViewport(_ value: ImageCanvasViewportSnapshot) {
        // Native layout/draw callbacks must not publish synchronously into SwiftUI's view update.
        DispatchQueue.main.async { [weak self] in self?.updateViewport(value) }
    }
    func updateViewport(_ value: ImageCanvasViewportSnapshot) {
        if let tracking {
            let invalid: Bool
            if tracking.handle == .straighten {
                invalid = value.viewportSize != tracking.viewport.viewportSize || value.backingScale != tracking.viewport.backingScale || value.transform != tracking.viewport.transform
            } else { invalid = value != tracking.viewport }
            if invalid { cancel() }
        }
        if viewport != value { viewport = value }
    }
    func overlayPresentation() -> OverlayPresentation? {
        // During rotation, Lightflow keeps its independent SVG overlay alive while pixels update.
        // Prefer the gesture's frozen viewport, then hand back to the first fully current frame.
        if let tracking, tracking.handle == .straighten, validScope(tracking), let frozenRotation {
            return frozenRotation
        }
        if let frame = editing.developmentCropFrame(context: context), let viewport,
           viewport.frameID == frame.frameID {
            frozenRotation = nil
            return .init(frame: frame, viewport: viewport)
        }
        if let frozenRotation, editing.developmentContext == context, editing.cropEditing,
           editing.previews.primary.currentSourceGeneration == frozenRotation.frame.sourceGeneration {
            return frozenRotation
        }
        return nil
    }
    func hover(_ event: ImageCanvasHoverEvent) {
        let next: PhotosCropHandle?
        if let tracking {
            next = tracking.handle
        } else if let point = event.locationInView,
                  let frame = editing.developmentCropFrame(context: context),
                  event.viewport.frameID == frame.frameID {
            let rect = PhotosCropInteraction.screenRect(editing.developmentGeometry.crop,
                imageRect: event.viewport.imageRect, plane: frame.plane)
            next = PhotosCropInteraction.hit(point, cropRect: rect, imageRect: event.viewport.imageRect)
        } else { next = nil }
        setHoveredHandle(next)
    }
    private func setHoveredHandle(_ value: PhotosCropHandle?) {
        guard hoveredHandle != value else { return }
        hoveredHandle = value
        PhotosCropCursor.set(value)
    }
    struct OverlayPresentation {
        let frame: EditingDevelopmentCropFrame
        let viewport: ImageCanvasViewportSnapshot
    }
    private struct Tracking {
        let pointerID: UUID
        let token: EditingGestureToken
        let handle: PhotosCropHandle
        let startPoint: CGPoint
        let startLocation: CGPoint
        let startCrop: NormalizedCrop
        let geometry: DevelopmentGeometryV3
        let viewport: ImageCanvasViewportSnapshot
        let frame: EditingDevelopmentCropFrame
    }
    private func validScope(_ tracking: Tracking) -> Bool {
        guard editing.developmentContext == context, editing.sourceReady, editing.isPresented, editing.stage == .development,
              editing.cropEditing, !editing.comparing, !editing.developmentShowingOriginal,
              editing.previews.primary.currentSourceGeneration == tracking.frame.sourceGeneration else { return false }
        return (try? editing.developmentSession.validateInteraction(context, gesture: tracking.token)) != nil
    }
    func pointer(_ event: ImageCanvasPointerEvent) -> Bool {
        if event.phase == .cancelled { cancel(); return true }
        do {
            switch event.phase {
            case .began:
                guard let frame = editing.developmentCropFrame(context: context), event.beganFrameID == frame.frameID,
                      event.viewport.frameID == frame.frameID else { return false }
                let rect = PhotosCropInteraction.screenRect(editing.developmentGeometry.crop, imageRect: event.viewport.imageRect, plane: frame.plane)
                guard let handle = PhotosCropInteraction.hit(event.locationInView, cropRect: rect, imageRect: event.viewport.imageRect) else { return false }
                let token = try editing.developmentSession.beginGesture(.init(group: nil, name: handle == .straighten ? "crop.straighten" : "crop"), context: context)
                tracking = .init(pointerID: event.gestureID, token: token, handle: handle,
                    startPoint: try PhotosCropInteraction.planePoint(event.locationInView, imageRect: event.viewport.imageRect, plane: frame.plane),
                    startLocation: event.locationInView, startCrop: editing.developmentGeometry.crop, geometry: editing.developmentGeometry, viewport: event.viewport, frame: frame)
                if handle == .straighten {
                    frozenRotation = .init(frame: frame, viewport: event.viewport)
                    objectWillChange.send()
                }
                setHoveredHandle(handle)
                return true
            case .changed, .ended:
                guard let tracking, tracking.pointerID == event.gestureID, event.beganFrameID == tracking.frame.frameID,
                      validScope(tracking) else { cancel(); return false }
                var next = tracking.geometry
                if tracking.handle == .straighten {
                    // This is a relative angle control, not a source-position edit. Its own new
                    // render may arrive mid-drag; keep its frozen center and absolute begin angle.
                    guard event.viewport.viewportSize == tracking.viewport.viewportSize,
                          event.viewport.backingScale == tracking.viewport.backingScale,
                          event.viewport.transform == tracking.viewport.transform else { cancel(); return false }
                    let center = CGPoint(x: tracking.viewport.imageRect.midX, y: tracking.viewport.imageRect.midY)
                    let a = atan2(tracking.startLocation.y - center.y, tracking.startLocation.x - center.x)
                    let b = atan2(event.locationInView.y - center.y, event.locationInView.x - center.x)
                    var delta = (b - a) * 180 / .pi
                    if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
                    let preGeometryDelta = tracking.geometry.lateOrientation.orientation.isReflection ? delta : -delta
                    var degrees = max(-45, min(45, tracking.geometry.straightenDegrees + preGeometryDelta))
                    if NSEvent.ModifierFlags(rawValue: UInt(event.modifiersRawValue)).contains(.shift) {
                        degrees = (degrees / 15).rounded() * 15
                    }
                    next.straightenDegrees = degrees
                    try editing.setDevelopmentGeometry(next, context: context, gesture: tracking.token, control: "crop.straighten", nativeEvent: true)
                } else {
                    guard let current = editing.developmentCropFrame(context: context), current.frameID == tracking.frame.frameID,
                          current.geometry == tracking.frame.geometry, current.plane == tracking.frame.plane,
                          event.viewport == tracking.viewport, let source = editing.developmentSession.source else { cancel(); return false }
                    let point = try PhotosCropInteraction.planePoint(event.locationInView, imageRect: event.viewport.imageRect, plane: current.plane)
                    let constrained = try editing.developmentSession.cropConstraint.ratio(source: source.sourceSize)
                    let modifiers = NSEvent.ModifierFlags(rawValue: UInt(event.modifiersRawValue))
                    let ratio: Double?
                    if modifiers.contains(.shift), constrained == nil {
                        ratio = tracking.startCrop.width * current.plane.rect.width
                            / max(0.000001, tracking.startCrop.height * current.plane.rect.height)
                    } else { ratio = constrained }
                    next.crop = try PhotosCropInteraction.resized(tracking.startCrop, handle: tracking.handle,
                        delta: .init(x: point.x - tracking.startPoint.x, y: point.y - tracking.startPoint.y), plane: current.plane.rect,
                        ratio: ratio, fromCenter: modifiers.contains(.option))
                    try editing.setDevelopmentGeometry(next, context: context, gesture: tracking.token, nativeEvent: true)
                }
                if event.phase == .ended {
                    self.tracking = nil
                    try editing.developmentSession.endGesture(tracking.token, .commit)
                }
                return true
            case .cancelled: return true
            }
        } catch { cancel(); return true }
    }
    func cancel() {
        setHoveredHandle(nil)
        frozenRotation = nil
        guard let tracking else { return }; self.tracking = nil
        guard editing.developmentContext == context, editing.developmentSession.activeGesture == tracking.token else { return }
        try? editing.developmentSession.endGesture(tracking.token, .cancel)
    }
}
