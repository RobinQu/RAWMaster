import AppKit
import Combine
import RAWMasterCore
import RAWMasterImaging

@MainActor final class EditingMaskInputSession: ObservableObject {
    private weak var editing: EditingController?
    @Published private(set) var activeKind: DevelopmentMaskKindV3?
    @Published private(set) var start: DevelopmentSourcePoint?
    @Published private(set) var current: DevelopmentSourcePoint?
    @Published private(set) var viewport: ImageCanvasViewportSnapshot?
    private var frame: EditingDevelopmentLocalFrame?
    init(editing:EditingController){self.editing=editing}
    func select(_ kind:DevelopmentMaskKindV3?,context:EditingInteractionContext){
        guard editing?.developmentContext == context else{return};cancel();activeKind=kind == .range || kind == .subject ? nil:kind
    }
    func cancel(){activeKind=nil;start=nil;current=nil;frame=nil}
    func updateViewport(_ value:ImageCanvasViewportSnapshot,context:EditingInteractionContext){
        guard editing?.developmentContext == context else{return};if viewport != value{start=nil;current=nil;frame=nil};viewport=value
    }
    private func point(_ event:ImageCanvasPointerEvent,frame:EditingDevelopmentLocalFrame)throws->DevelopmentSourcePoint {
        let rect=event.viewport.imageRect,p=event.locationInView
        guard rect.width>0,rect.height>0,rect.contains(p)else{throw DevelopmentGeometryMappingError.pointOutsideSource}
        return try frame.mapping.sourcePoint(fromOutput:.init(x:(p.x-rect.minX)/rect.width,y:(p.y-rect.minY)/rect.height))
    }
    func pointer(_ event:ImageCanvasPointerEvent,context:EditingInteractionContext)->Bool {
        guard activeKind != nil else{return false}
        if event.phase == .cancelled{cancel();return true}
        guard let editing,let kind=activeKind,editing.developmentContext == context,let currentFrame=editing.developmentLocalFrame(context:context)else{return true}
        do{
            switch event.phase{
            case .began:
                guard start==nil,event.viewport.frameID==currentFrame.frameID else{return true}
                frame=currentFrame;viewport=event.viewport;start=try point(event,frame:currentFrame);current=start
            case .changed,.ended:
                guard let original=frame,original.frameID==currentFrame.frameID,event.viewport == viewport else{cancel();return true}
                current=try point(event,frame:currentFrame)
                if event.phase == .ended,let first=start,let last=current{editing.addDevelopmentMask(kind,start:first,end:last,context:context);cancel()}
            case .cancelled:break
            }
        }catch{cancel()};return true
    }
}
