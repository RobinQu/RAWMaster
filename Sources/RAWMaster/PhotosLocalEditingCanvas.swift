import SwiftUI
import AppKit
import RAWMasterCore
import RAWMasterImaging

struct PhotosLocalEditingCanvas: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var input: EditingLocalInputSession
    let context: EditingInteractionContext
    @Binding var transform: ImageTransform
    var overlayOnly = false
    var body: some View {
        ZStack {
            let frame = editing.previews.primary.frame, fit = editing.previews.primary.fitFallback
            if !overlayOnly {
            ZoomableImageView(image: nil, actualPixels: editing.actualPixels,
                transform: .init(get: { transform }, set: { value in if editing.developmentContext == context { transform = value } }),
                backgroundColor: AppPalette.canvasNSColor,
                onActualPixelsChange: { value in
                    if editing.developmentContext == context {
                        editing.setActualPixels(value, nativeEvent: true, requestPreview: value || transform == .init())
                    }
                },
                frameID: frame?.id, onFrameDrawn: input.frameWasDrawn,
                onPointerEvent: { input.pointer($0, context: context) },
                onViewportChange: { snapshot in
                    input.updateViewport(snapshot, context: context)
                    DispatchQueue.main.async {
                        guard editing.developmentContext == context, snapshot.transform == transform else { return }
                        editing.updateCanvasSampling(snapshot, role: .primary)
                    }
                },
                onPointerHover: { input.hover($0, context: context) },
                onVisibleWindow: { [weak editing] visible in
                    guard let editing, editing.developmentContext == context else { return }
                    editing.updateDetailVisibleWindow(visible)
                },
                window: frame?.window, canvasPixelSize: frame?.nativeSize ?? fit?.nativeSize)
                .borrowingImage(frame?.image ?? fit?.image)
                .fallbackImage(frame?.window == nil ? nil : fit?.image)
                .fitting(around: EditingLayout.fitInsets)
                .trackingFreeZoom { active, snapshot in
                    guard editing.developmentContext == context else { return }
                    editing.updateCanvasSampling(snapshot, role: .primary, zooming: active)
                }
            }
            if let frame = editing.developmentLocalFrame(context: context), let viewport = input.viewport, viewport.frameID == frame.frameID {
                localOverlay(frame, imageRect: viewport.imageRect).allowsHitTesting(false).accessibilityHidden(true)
            }
        }.accessibilityLabel(input.tool == .retouch ? "修饰画布" : "红眼修正画布")
            .accessibilityHint("在照片上点击或涂抹。按住 Option 点击选择修复来源；可缩放查看细节，按 Escape 取消。")
            .onDisappear { if editing.developmentContext == context { input.cancelCollection() } }
    }
    private func localOverlay(_ frame: EditingDevelopmentLocalFrame, imageRect: CGRect) -> some View {
        Canvas { drawing, size in
            guard let current = editing.developmentLocalFrame(context: context), current.frameID == frame.frameID,
                  let viewport = input.viewport, viewport.frameID == frame.frameID, viewport.viewportSize == size else { return }
            func screen(_ point: DevelopmentSourcePoint) -> CGPoint? {
                guard let output = try? frame.mapping.outputPoint(fromSource: point) else { return nil }
                return .init(x: imageRect.minX + output.x * imageRect.width, y: imageRect.minY + output.y * imageRect.height)
            }
            func ring(_ center: DevelopmentSourcePoint, radius: Double) -> Path {
                let source = frame.source.sourceSize
                var path = Path(), hasPoint = false
                for index in 0...32 {
                    let angle = Double(index) / 32 * 2 * .pi
                    let point = DevelopmentSourcePoint(x: center.x + cos(angle) * radius / Double(source.width),
                        y: center.y + sin(angle) * radius / Double(source.height))
                    guard (0...1).contains(point.x), (0...1).contains(point.y), let p = screen(point) else { hasPoint = false; continue }
                    if hasPoint { path.addLine(to: p) } else { path.move(to: p); hasPoint = true }
                }
                return path
            }
            if let cursor = input.cursor, !input.panHeld {
                let path = ring(cursor, radius: input.size)
                drawing.stroke(path, with: .color(.black), lineWidth: 3)
                drawing.stroke(path, with: .color(.white), lineWidth: 1)
            }
            if let donor = input.donor, let point = screen(donor) {
                var cross = Path(); cross.move(to: .init(x: point.x - 6, y: point.y)); cross.addLine(to: .init(x: point.x + 6, y: point.y))
                cross.move(to: .init(x: point.x, y: point.y - 6)); cross.addLine(to: .init(x: point.x, y: point.y + 6))
                drawing.stroke(cross, with: .color(.yellow), lineWidth: 2)
            }
            var stroke = Path(), first = true
            for sample in input.points {
                guard let p = screen(sample.position) else { continue }
                if first { stroke.move(to: p); first = false } else { stroke.addLine(to: p) }
            }
            drawing.stroke(stroke, with: .color(.white.opacity(0.8)), lineWidth: 2)
            if let id = input.selectedOperationID,
               let operation = editing.developmentSession.parameters.localEdits.operations.first(where: { $0.id == id }),
               let center = operation.stroke.points.first?.position {
                let path = ring(center, radius: operation.stroke.radiusInShortEdge * Double(min(frame.source.orientedWidth, frame.source.orientedHeight)))
                drawing.stroke(path, with: .color(.black), lineWidth: 3)
                drawing.stroke(path, with: .color(.yellow), lineWidth: 1)
            }
        }
    }
}

/// Pointer events arrive from the EDR surface. Both appearances draw the same vector overlays.
struct EditingScenePhotographicOverlays: View {
    @ObservedObject var editing: EditingController
    @Binding var transform: ImageTransform
    var body: some View {
        if editing.developmentLocalInput.tool != nil, let context = editing.developmentContext {
            PhotosLocalEditingCanvas(editing: editing, input: editing.developmentLocalInput, context: context,
                transform: $transform, overlayOnly: true).allowsHitTesting(false)
        } else if let owner = editing.developmentMaskInput.canvasOwner {
            PhotosMaskEditingCanvas(editing: editing, input: editing.developmentMaskInput, owner: owner,
                transform: $transform, overlayOnly: true).allowsHitTesting(false)
        }
    }
}
