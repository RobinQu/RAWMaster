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
            ZoomableImageView(image: editing.preview, actualPixels: false, transform: $transform, backgroundColor: AppPalette.canvasNSColor,
                frameID: editing.previews.primary.frame?.id, onFrameDrawn: { editing.previews.primary.didDraw($0) },
                onPointerEvent: interaction.pointer, onViewportChange: interaction.updateViewport)
                .accessibilityLabel("裁切画布")
                .accessibilityHint("拖动边角调整范围，框内移动，框外拉直。也可使用右侧裁切比例、拉直和精确位置数值。")
            if let frame = editing.developmentCropFrame(context: context), let viewport = interaction.viewport, viewport.frameID == frame.frameID {
                overlay(viewport, frame: frame)
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
            for f in [1.0 / 3, 2.0 / 3] {
                var grid = Path(); grid.move(to: .init(x: rect.minX + rect.width * f, y: rect.minY)); grid.addLine(to: .init(x: rect.minX + rect.width * f, y: rect.maxY))
                grid.move(to: .init(x: rect.minX, y: rect.minY + rect.height * f)); grid.addLine(to: .init(x: rect.maxX, y: rect.minY + rect.height * f))
                context.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.5)
            }
            for x in [rect.minX, rect.midX, rect.maxX] {
                for y in [rect.minY, rect.midY, rect.maxY] where x != rect.midX || y != rect.midY {
                    context.fill(Path(ellipseIn: .init(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.white))
                }
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
    private var tracking: Tracking?
    init(editing: EditingController, context: EditingInteractionContext) { self.editing = editing; self.context = context }
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
                    next.straightenDegrees = max(-45, min(45, tracking.geometry.straightenDegrees + preGeometryDelta))
                    try editing.setDevelopmentGeometry(next, context: context, gesture: tracking.token, control: "crop.straighten", nativeEvent: true)
                } else {
                    guard let current = editing.developmentCropFrame(context: context), current.frameID == tracking.frame.frameID,
                          current.geometry == tracking.frame.geometry, current.plane == tracking.frame.plane,
                          event.viewport == tracking.viewport, let source = editing.developmentSession.source else { cancel(); return false }
                    let point = try PhotosCropInteraction.planePoint(event.locationInView, imageRect: event.viewport.imageRect, plane: current.plane)
                    let ratio = try editing.developmentSession.cropConstraint.ratio(source: source.sourceSize)
                    next.crop = try PhotosCropInteraction.resized(tracking.startCrop, handle: tracking.handle,
                        delta: .init(x: point.x - tracking.startPoint.x, y: point.y - tracking.startPoint.y), plane: current.plane.rect, ratio: ratio)
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
        guard let tracking else { return }; self.tracking = nil
        guard editing.developmentContext == context, editing.developmentSession.activeGesture == tracking.token else { return }
        try? editing.developmentSession.endGesture(tracking.token, .cancel)
    }
}
