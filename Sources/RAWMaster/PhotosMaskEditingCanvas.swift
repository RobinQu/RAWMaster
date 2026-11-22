import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct PhotosMaskEditingCanvas:View{
    @ObservedObject var editing:EditingController
    @ObservedObject var input:EditingMaskInputSession
    let context:EditingInteractionContext
    @Binding var transform:ImageTransform
    var body:some View{
        ZStack{
            ZoomableImageView(image:editing.preview,actualPixels:editing.actualPixels && editing.previews.primary.frame?.quality == .detail,
                transform:.init(get:{transform},set:{if editing.developmentContext == context{transform=$0}}),
                backgroundColor:editing.darkroomBackground.nsColor,
                onActualPixelsChange:{editing.setActualPixels($0,nativeEvent:true)},onRequestDetail:{editing.requestDetailPreview(nativeEvent:true)},
                frameID:editing.previews.primary.frame?.id,onFrameDrawn:{editing.previews.primary.didDraw($0)},
                onPointerEvent:{input.pointer($0,context:context)},onViewportChange:{input.updateViewport($0,context:context)})
            if let frame=editing.developmentLocalFrame(context:context),let viewport=input.viewport,viewport.frameID==frame.frameID{
                Canvas{g,size in
                    guard viewport.viewportSize==size,let first=input.start,let last=input.current else{return}
                    func screen(_ p:DevelopmentSourcePoint)->CGPoint?{guard let o=try? frame.mapping.outputPoint(fromSource:p)else{return nil};return .init(x:viewport.imageRect.minX+o.x*viewport.imageRect.width,y:viewport.imageRect.minY+o.y*viewport.imageRect.height)}
                    guard let a=screen(first),let b=screen(last)else{return}
                    var path=Path()
                    if input.activeKind == .linear{path.move(to:a);path.addLine(to:b)}
                    else{path=Path(ellipseIn:.init(x:a.x-abs(a.x-b.x),y:a.y-abs(a.y-b.y),width:abs(a.x-b.x)*2,height:abs(a.y-b.y)*2))}
                    g.stroke(path,with:.color(.black),lineWidth:3);g.stroke(path,with:.color(.yellow),lineWidth:1)
                }.allowsHitTesting(false)
            }
        }.accessibilityLabel("蒙版选取画布").accessibilityHint("拖动创建线性或径向渐变，Escape 取消")
            .onDisappear{if editing.developmentContext == context{input.cancel()}}
    }
}
