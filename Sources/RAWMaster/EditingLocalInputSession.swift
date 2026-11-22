import AppKit
import Combine
import RAWMasterCore
import RAWMasterImaging

struct EditingDevelopmentLocalFrame {
    let context: EditingInteractionContext
    let frameID: UUID
    let sourceGeneration: UInt64
    let recipeFingerprint: String
    let mapping: DevelopmentGeometryMappingV3
    let source: DevelopmentLocalEditSourceBinding
}

/// Source-space scalar input only. No native job, recipe/image history or second render owner.
@MainActor final class EditingLocalInputSession: ObservableObject {
    private weak var editing: EditingController?
    @Published private(set) var tool: DevelopmentLocalTool?
    @Published var retouchMode: DevelopmentRetouchMode = .heal
    @Published private var sizes: [String: Double] = [:]
    @Published private(set) var donor: DevelopmentSourcePoint?
    @Published private(set) var points: [DevelopmentStrokePoint] = []
    @Published private(set) var cursor: DevelopmentSourcePoint?
    @Published private(set) var panHeld = false
    @Published var selectedOperationID: UUID?
    private var donorFingerprint: String?
    private var donorContext: EditingInteractionContext?
    private var tracking: Tracking?
    @Published private(set) var viewport: ImageCanvasViewportSnapshot?
    private struct Tracking {
        let id: UUID
        let frame: EditingDevelopmentLocalFrame
        let viewport: ImageCanvasViewportSnapshot
        let tool: DevelopmentLocalTool
        let selectingDonor: Bool
        let radius: Double
        let explicitDonor: DevelopmentSourcePoint?
    }
    init(editing: EditingController) { self.editing = editing }
    var collecting: Bool { tracking != nil }
    var size: Double { size(for: tool ?? .retouch) }
    func size(for tool: DevelopmentLocalTool) -> Double { sizes[tool.rawValue] ?? 40 }
    var sizeRange: ClosedRange<Double> {
        let short = editing?.developmentSession.source.map { Double(min($0.orientedWidth, $0.orientedHeight)) } ?? 200
        let maximum = min(200, short)
        return min(3, maximum)...maximum
    }
    func select(_ tool: DevelopmentLocalTool?) {
        cancel(clearTool: true); self.tool = tool
        if let tool { setSize(min(sizeRange.upperBound, max(sizeRange.lowerBound, size(for: tool))), tool: tool) }
    }
    func setSize(_ size: Double, tool: DevelopmentLocalTool? = nil) {
        guard size.isFinite, sizeRange.contains(size) else { return }
        let target = tool ?? self.tool ?? .retouch
        if target == self.tool { cancelCollection() }
        sizes[target.rawValue] = size
    }
    func setPanHeld(_ held: Bool) { if held { cancelCollection() }; panHeld = held }
    func clearDonor() { donor = nil; donorFingerprint = nil; donorContext = nil }
    func frameWasDrawn(_ event: ImageFrameDrawEvent) {
        if editing?.previews.primary.didDraw(event) == true { objectWillChange.send() }
    }
    func recipeWillChange() { cancelCollection(); clearDonor(); selectedOperationID = nil }
    func cancelCollection() { tracking = nil; points = [] }
    func cancel(clearTool: Bool = false) {
        cancelCollection(); clearDonor(); cursor = nil; viewport = nil; panHeld = false
        if clearTool { tool = nil; selectedOperationID = nil }
    }
    func updateViewport(_ value: ImageCanvasViewportSnapshot, context: EditingInteractionContext) {
        guard editing?.developmentContext == context else { return }
        if let viewport, viewport != value { cancelCollection(); clearDonor(); cursor = nil }
        if viewport != value { viewport = value }
    }
    func hover(_ event: ImageCanvasHoverEvent, context: EditingInteractionContext) {
        guard let editing, let frame = editing.developmentLocalFrame(context: context), frame.frameID == event.viewport.frameID,
              let location = event.locationInView else { if self.editing?.developmentContext == context { cursor = nil }; return }
        cursor = try? sourcePoint(location, viewport: event.viewport, frame: frame)
    }
    private func sourcePoint(_ point: CGPoint, viewport: ImageCanvasViewportSnapshot,
                             frame: EditingDevelopmentLocalFrame) throws -> DevelopmentSourcePoint {
        let rect = viewport.imageRect
        guard point.x.isFinite, point.y.isFinite, rect.width > 0, rect.height > 0,
              point.x >= rect.minX, point.x <= rect.maxX, point.y >= rect.minY, point.y <= rect.maxY else {
            throw DevelopmentGeometryMappingError.pointOutsideSource
        }
        return try frame.mapping.sourcePoint(fromOutput: .init(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height))
    }
    private func point(_ event: ImageCanvasPointerEvent, frame: EditingDevelopmentLocalFrame) throws -> DevelopmentStrokePoint {
        let pressure = event.supportsPressure && event.pressure.isFinite ? min(1, max(0, event.pressure)) : 1
        return .init(position: try sourcePoint(event.locationInView, viewport: event.viewport, frame: frame), pressure: pressure)
    }
    func pointer(_ event: ImageCanvasPointerEvent, context: EditingInteractionContext) -> Bool {
        if event.phase == .cancelled {
            if tracking?.id == event.gestureID, tracking?.frame.context == context { cancelCollection() }
            return true
        }
        guard let editing else { return false }
        do {
            switch event.phase {
            case .began:
                guard tracking == nil, !panHeld, !editing.developmentAnalysisBusy, let tool,
                      let frame = editing.developmentLocalFrame(context: context), event.beganFrameID == frame.frameID,
                      event.viewport.frameID == frame.frameID else { return false }
                let first = try point(event, frame: frame)
                let option = NSEvent.ModifierFlags(rawValue: UInt(event.modifiersRawValue)).contains(.option)
                if donorContext != context || donorFingerprint != frame.recipeFingerprint { clearDonor() }
                let selecting = tool == .retouch && option
                if !selecting, tool == .retouch, donor == nil,
                   retouchMode == .clone || editing.developmentSourceFacts?.localCapabilities.contains(.automaticDonor) != true {
                    editing.message = "请按住 Option 点击照片，选择\(retouchMode == .clone ? "克隆" : "修复")来源。"; return true
                }
                let radius = size / Double(min(frame.source.orientedWidth, frame.source.orientedHeight))
                tracking = .init(id: event.gestureID, frame: frame, viewport: event.viewport, tool: tool,
                    selectingDonor: selecting, radius: radius, explicitDonor: donor)
                points = selecting ? [] : [first]; cursor = first.position
                if selecting { donor = first.position; donorContext = context; donorFingerprint = frame.recipeFingerprint }
                return true
            case .changed, .ended:
                guard let active = tracking, active.id == event.gestureID, active.frame.context == context else { return false }
                guard !panHeld, let current = editing.developmentLocalFrame(context: context), current.frameID == active.frame.frameID,
                      current.recipeFingerprint == active.frame.recipeFingerprint, current.mapping == active.frame.mapping,
                      event.beganFrameID == active.frame.frameID, event.viewport == active.viewport else { cancelCollection(); return false }
                let next = try point(event, frame: active.frame); cursor = next.position
                if !active.selectingDonor {
                    if active.tool == .redEye {
                        // A tablet's lift may report zero pressure; retain the click's peak.
                        points = [.init(position: next.position, pressure: max(points.first?.pressure ?? 0, next.pressure))]
                    }
                    else if points.last != next {
                        guard points.count < DevelopmentLocalEditLimits.maximumPointsPerStroke else {
                            cancelCollection(); editing.message = "这笔修饰过长，请分成几笔完成。"; return true
                        }
                        points.append(next)
                    }
                }
                if event.phase == .ended {
                    let collected = points; cancelCollection()
                    guard !active.selectingDonor, collected.contains(where: { $0.pressure > 0 }) else { return true }
                    let stroke = DevelopmentStroke(points: collected, radiusInShortEdge: active.radius)
                    try stroke.validate(); _ = try stroke.dabCount(sourceSize: active.frame.source.sourceSize)
                    editing.finishDevelopmentLocalInput(stroke: stroke, tool: active.tool, donor: active.explicitDonor, frame: active.frame, gestureID: active.id)
                }
                return true
            case .cancelled: return true
            }
        } catch {
            // A projected miss cancels this entire sequence rather than clamping onto an edge.
            if tracking?.frame.context == context { cancelCollection() }
            return true
        }
    }
}
