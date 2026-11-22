import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct PhotosMaskEditingCanvas: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var input: EditingMaskInputSession
    let context: EditingInteractionContext
    @Binding var transform: ImageTransform
    @State private var overlay: CGImage?
    @State private var overlayGeometry: DevelopmentGeometryMappingV3?
    private struct OverlayKey: Equatable {
        let revision: UUID
        let mapping: DevelopmentGeometryMappingV3?
        let visible: Bool
    }
    var body: some View {
        let frame = editing.developmentLocalFrame(context:context)
        let overlayKey = OverlayKey(revision:input.overlayRevision,mapping:frame?.mapping,visible:input.candidate != nil && input.showsOverlay)
        ZStack {
            ZoomableImageView(image:editing.preview,actualPixels:editing.actualPixels && editing.previews.primary.frame?.quality == .detail,
                transform:.init(get:{transform},set:{if editing.developmentContext == context { transform = $0 }}),
                backgroundColor:editing.darkroomBackground.nsColor,
                onActualPixelsChange:{editing.setActualPixels($0,nativeEvent:true)},onRequestDetail:{editing.requestDetailPreview(nativeEvent:true)},
                frameID:editing.previews.primary.frame?.id,onFrameDrawn:{editing.previews.primary.didDraw($0)},
                onPointerEvent:{input.pointer($0,context:context)},onViewportChange:{input.updateViewport($0,context:context)})
            if let frame, let viewport = input.viewport, viewport.frameID == frame.frameID {
                Canvas { graphics,size in
                    guard viewport.viewportSize == size else { return }
                    if overlayKey.visible, overlayGeometry == frame.mapping, let overlay {
                        graphics.draw(Image(decorative:overlay,scale:1),in:viewport.imageRect)
                    }
                    guard let first = input.start, let last = input.current else { return }
                    func screen(_ p: DevelopmentSourcePoint) -> CGPoint? {
                        guard let out = try? frame.mapping.outputPoint(fromSource:p) else { return nil }
                        return .init(x:viewport.imageRect.minX+out.x*viewport.imageRect.width,y:viewport.imageRect.minY+out.y*viewport.imageRect.height)
                    }
                    guard let a = screen(first), let b = screen(last) else { return }
                    var path = Path()
                    if input.activeKind == .linear { path.move(to:a); path.addLine(to:b) }
                    else if input.activeKind == .radial { path.addEllipse(in:.init(x:a.x-abs(a.x-b.x),y:a.y-abs(a.y-b.y),width:abs(a.x-b.x)*2,height:abs(a.y-b.y)*2)) }
                    else if input.selecting != nil { path.addRect(.init(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))) }
                    else if input.brush != nil { path.addEllipse(in:.init(x:b.x-3,y:b.y-3,width:6,height:6)) }
                    graphics.stroke(path,with:.color(.black),lineWidth:3); graphics.stroke(path,with:.color(.yellow),lineWidth:1)
                }.allowsHitTesting(false)
            }
        }
        .accessibilityLabel("蒙版选取画布").accessibilityHint("点选、框选物体或拖动画笔，Escape 取消")
        .task(id:overlayKey) {
            guard overlayKey.visible, let mapping = overlayKey.mapping, let bitmap = input.candidate?.bitmap else { overlay = nil; return }
            let inverted = input.original?.inverted ?? false, opacity = input.original?.opacity ?? 1
            let work = Task.detached(priority:.userInitiated) { try bitmap.overlay(mapping:mapping,inverted:inverted,opacity:opacity) }
            let result = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled { overlay = result; overlayGeometry = mapping }
        }
        .onDisappear { if editing.developmentContext == context { input.cancel() } }
    }
}
