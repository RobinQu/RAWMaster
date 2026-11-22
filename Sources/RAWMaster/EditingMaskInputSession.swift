import AppKit
import Combine
import RAWMasterCore
import RAWMasterImaging

@MainActor final class EditingMaskInputSession: ObservableObject {
    enum Brush { case add, subtract }
    struct CanvasOwner: Hashable {
        let context: EditingInteractionContext
        fileprivate let generation: UUID
    }
    // A point/box interaction keeps its canvas across detector and segmentation jobs.
    private var canvasGeneration = UUID()
    private weak var editing: EditingController?
    typealias Generate = @Sendable (URL, DevelopmentLocalEditSourceBinding, DevelopmentSemanticTarget, [DevelopmentSourcePoint]) async throws -> DevelopmentMaskCandidate
    typealias Install = @Sendable (DevelopmentMaskModelPack.Component, URL) async throws -> Void
    private let installComponent: Install
    private let service: DevelopmentSemanticMaskService
    private let generateOverride: Generate?
    let pack: DevelopmentMaskModelPack
    @Published private(set) var activeKind: DevelopmentMaskKindV3?
    @Published private(set) var instanceOptions: [DevelopmentSemanticMaskService.InstanceOption] = []
    @Published private(set) var selecting: DevelopmentSemanticTarget?
    @Published private(set) var start: DevelopmentSourcePoint?
    @Published private(set) var current: DevelopmentSourcePoint?
    @Published private(set) var viewport: ImageCanvasViewportSnapshot?
    @Published private(set) var candidate: DevelopmentMaskCandidate?
    @Published private(set) var busy = false
    @Published private(set) var note: String?
    @Published private(set) var modelStates: [DevelopmentMaskModelPack.Component:DevelopmentMaskModelPack.State] = [:]
    private var modelCheck = UUID()
    @Published private(set) var brush: Brush?
    @Published private(set) var overlayRevision = UUID()
    @Published var showsOverlay = true
    @Published var brushDiameter = 0.05
    private(set) var original: DevelopmentMaskLayerV3?
    private var gesture: UUID?
    private var frame: EditingDevelopmentLocalFrame?
    private var viewportUpdate: Task<Void, Never>?
    private var ticket: (id:UUID, context:EditingInteractionContext, revision:UUID)?
    private var task: Task<Void,Never>?
    private var beforeStroke: DevelopmentMaskBitmap?
    private var changed = false
    var usesCanvas: Bool { activeKind != nil || selecting != nil || candidate != nil }
    var isActive: Bool { usesCanvas || busy }
    var canAdopt: Bool { candidate != nil && changed && !busy }

    init(editing: EditingController, pack: DevelopmentMaskModelPack = .installed, install: Install? = nil, generate: Generate? = nil) {
        self.editing = editing; self.pack = pack
        self.installComponent = install ?? { try await pack.install($0,from:$1) }
        service = DevelopmentSemanticMaskService(pack:pack)
        generateOverride = generate
    }
    func candidateCounts() async -> (exactCacheHits: Int, successfulGenerations: Int) {
        await service.candidateCounts
    }

    func analysisDiagnostics(for sourceContentID: String) async -> DevelopmentMaskAnalysisDiagnostics? {
        await service.analysisDiagnostics(for: sourceContentID)
    }
    private func generateCandidate(_ capture: URL, _ source: DevelopmentLocalEditSourceBinding, _ target: DevelopmentSemanticTarget,
                                   _ prompt: [DevelopmentSourcePoint], rawDecoder: DevelopmentRAWDecoder?) async throws -> DevelopmentMaskCandidate {
        if let generateOverride { return try await generateOverride(capture, source, target, prompt) }
        return try await service.generate(capture: capture, source: source, target: target, prompt: prompt, rawDecoder: rawDecoder)
    }

    var canvasOwner: CanvasOwner? {
        guard usesCanvas, let context = editing?.developmentContext, allowsInput(context) else { return nil }
        return CanvasOwner(context: context, generation: canvasGeneration)
    }
    func canvasDidDisappear(_ owner: CanvasOwner) {
        guard owner.generation == canvasGeneration, owner.context == editing?.developmentContext else { return }
        cancel()
    }
    func presetCandidate(capture: URL, source: DevelopmentLocalEditSourceBinding, target: DevelopmentSemanticTarget) async throws -> DevelopmentMaskCandidate {
        guard [.subject,.background,.sky,.water].contains(target) else { throw DevelopmentMaskError.invalidPrompt }
        return try await generateCandidate(capture,source,target,[],rawDecoder:editing?.developmentSession.parameters.rawDecoder)
    }
    func allowsInput(_ context: EditingInteractionContext) -> Bool {
        editing?.allowsDevelopmentMaskInput(context) == true
    }
    func select(_ kind: DevelopmentMaskKindV3?, context: EditingInteractionContext) {
        guard allowsInput(context) else { return }
        cancel(); activeKind = kind == .range || kind == .subject ? nil : kind
    }
    func cancel() {
        canvasGeneration = UUID()
        viewportUpdate?.cancel(); viewportUpdate = nil
        task?.cancel(); task = nil; ticket = nil; busy = false; note = nil
        activeKind = nil; selecting = nil; instanceOptions = []; brush = nil; candidate = nil; original = nil; changed = false
        resetPointer(); viewport = nil
    }
    func release() {
        cancel()
        let service = service
        Task { await service.release() }
    }
    func recipeRevisionChanged(_ revision: UUID) {
        if let ticket, ticket.revision != revision { cancel() }
    }
    func refreshModels() async {
        let check = UUID(), pack = pack
        modelCheck = check
        let work = Task.detached(priority:.utility) {
            try Dictionary(uniqueKeysWithValues:DevelopmentMaskModelPack.Component.allCases.map { ($0,try pack.state(of:$0)) })
        }
        let states = await withTaskCancellationHandler { try? await work.value } onCancel: { work.cancel() }
        if let states, !Task.isCancelled, modelCheck == check, states != modelStates { modelStates = states }
    }
    func install(_ component: DevelopmentMaskModelPack.Component, folder: URL) {
        cancel(); let token = UUID()
        guard let editing, let context = editing.developmentContext, allowsInput(context) else { return }
        ticket = (token,context,editing.developmentSession.revision); busy = true
        task = Task {
            do {
                try await installComponent(component,folder)
                await refreshModels()
                guard owns(token) else { return }
                await service.release()
                guard owns(token) else { return }
                busy = false; note = "模型已安装，可在本机使用。"
            } catch { await refreshModels(); finish(error, token:token) }
        }
    }
    func begin(_ target: DevelopmentSemanticTarget, context: EditingInteractionContext) {
        guard let editing, allowsInput(context) else { return }
        cancel()
        if [.instance,.object].contains(target) {
            selecting = target
            let token = UUID()
            ticket = (token,context,editing.developmentSession.revision)
            if target == .instance, let url = editing.work?.source.sourceLocation, let source = editing.developmentSession.source {
                busy = true
                let rawDecoder = editing.developmentSession.parameters.rawDecoder
                task = Task {
                    do {
                        let options = try await service.instanceOptions(capture:url,source:source,rawDecoder:rawDecoder)
                        guard owns(token) else { return }
                        instanceOptions = options; busy = false
                    } catch { finish(error,token:token) }
                }
            }
        } else { generate(target,context:context,prompt:[]) }
    }
    func chooseInstance(_ option: DevelopmentSemanticMaskService.InstanceOption, context: EditingInteractionContext) {
        guard let ticket, owns(ticket.id), ticket.context == context, selecting == .instance, !busy,
              instanceOptions.contains(where:{ $0.id == option.id && $0.point == option.point }) else { return }
        generate(.instance,context:context,prompt:[option.point])
    }
    private func generate(_ target: DevelopmentSemanticTarget, context: EditingInteractionContext, prompt: [DevelopmentSourcePoint]) {
        guard let editing, allowsInput(context), let source = editing.developmentSession.source,
              let capture = editing.work?.source.sourceLocation else { return }
        let token = UUID()
        ticket = (token,context,editing.developmentSession.revision); busy = true; note = nil
        let rawDecoder = editing.developmentSession.parameters.rawDecoder
        task = Task {
            do {
                let result = try await generateCandidate(capture,source,target,prompt,rawDecoder:rawDecoder)
                guard owns(token) else { return }
                selecting = nil; candidate = result; busy = false; changed = target != .brush; showsOverlay = true
                if target == .brush { brush = .add }
                overlayRevision = UUID()
            } catch { finish(error,token:token) }
        }
    }
    func review(_ layer: DevelopmentMaskLayerV3, context: EditingInteractionContext) {
        guard let editing, allowsInput(context), let source = editing.developmentSession.source,
              editing.developmentSession.parameters.masks.contains(layer) else { return }
        cancel()
        do {
            let result = try DevelopmentMaskCandidate(layer:layer,source:source)
            candidate = result; original = layer; showsOverlay = true
            ticket = (UUID(),context,editing.developmentSession.revision); overlayRevision = UUID()
        } catch { note = "无法读取这个选区的快照。" }
    }
    func setBrush(_ mode: Brush) { guard candidate != nil else { return }; resetPointer(); brush = mode; showsOverlay = true }
    func adopt(context: EditingInteractionContext) {
        guard let editing, let ticket, ticket.context == context, owns(ticket.id), canAdopt, let candidate else { return }
        do {
            let layer = try candidate.layer(replacing:original)
            var masks = editing.developmentSession.parameters.masks
            if let original {
                guard let i = masks.firstIndex(where: { $0 == original }) else { cancel(); return }
                masks[i] = layer
            } else { masks.append(layer) }
            try editing.developmentSession.apply(.setMasks(masks),event:.init(context:context,control:.init(group:nil,name:"采用"+layer.name+"蒙版"),
                    nativeInput:.capture(control:"mask.adopt",phase:"discrete",nativeEvent:true)))
            editing.selectDevelopmentScopeMask(layer.id); cancel()
        } catch { note = "未能保存该蒙版。请检查图层数量和选区。" }
    }

    private func owns(_ id: UUID) -> Bool {
        guard let ticket, ticket.id == id, let editing else { return false }
        guard allowsInput(ticket.context), editing.developmentSession.revision == ticket.revision else {
            cancel(); return false
        }
        return true
    }
    private func finish(_ error: Error, token: UUID) {
        guard owns(token) else { return }
        busy = false
        if let e = error as? DevelopmentMaskError, e == .invalidModels || e == .missingModels {
            Task { await refreshModels() }
        }
        note = (error as? DevelopmentMaskError)?.errorDescription ?? "本机识别未完成。可重新选择或使用画笔。"
    }
    private func resetPointer() { start = nil; current = nil; frame = nil; gesture = nil; beforeStroke = nil }
    private func cancelStroke() {
        if let beforeStroke { candidate?.bitmap = beforeStroke; overlayRevision = UUID() }
        resetPointer()
    }
    func canvasViewportChanged(_ value: ImageCanvasViewportSnapshot, owner: CanvasOwner) {
        guard canvasOwner == owner else { return }
        // AppKit can report geometry during updateNSView. Publish the latest measurement after that update.
        viewportUpdate?.cancel()
        viewportUpdate = Task { [weak self] in
            guard let self, !Task.isCancelled, canvasOwner == owner else { return }
            updateViewport(value, context: owner.context)
        }
    }
    func updateViewport(_ value: ImageCanvasViewportSnapshot, context: EditingInteractionContext) {
        guard allowsInput(context), viewport != value else { return }
        if viewport != nil { cancelStroke() }
        viewport = value
    }
    private func point(_ event: ImageCanvasPointerEvent, frame: EditingDevelopmentLocalFrame) throws -> DevelopmentSourcePoint {
        let rect = event.viewport.imageRect, p = event.locationInView
        guard rect.width > 0, rect.height > 0, rect.contains(p) else { throw DevelopmentGeometryMappingError.pointOutsideSource }
        return try frame.mapping.sourcePoint(fromOutput:.init(x:(p.x-rect.minX)/rect.width,y:(p.y-rect.minY)/rect.height))
    }
    private func paint(_ a: DevelopmentSourcePoint, _ b: DevelopmentSourcePoint) {
        guard let brush else { return }
        let adding = (brush == .add) != (original?.inverted ?? false)
        candidate?.bitmap.paint(from:a,to:b,diameter:brushDiameter,adding:adding)
        overlayRevision = UUID()
    }
    func pointer(_ event: ImageCanvasPointerEvent, context: EditingInteractionContext) -> Bool {
        guard activeKind != nil || selecting != nil || brush != nil else { return false }
        if event.phase == .cancelled { if gesture == event.gestureID { cancelStroke() }; return true }
        guard !busy, let editing, let presented = editing.developmentLocalFrame(context:context) else { return true }
        if let ticket, !owns(ticket.id) { return true }
        do {
            let p = try point(event,frame:presented)
            switch event.phase {
            case .began:
                guard start == nil, event.beganFrameID == presented.frameID, event.viewport.frameID == presented.frameID else { return true }
                viewportUpdate?.cancel()
                gesture = event.gestureID; frame = presented; viewport = event.viewport; start = p; current = p
                if brush != nil { beforeStroke = candidate?.bitmap; paint(p,p) }
            case .changed, .ended:
                guard gesture == event.gestureID else { return true }
                guard let frame, frame.frameID == presented.frameID, event.viewport == viewport, let first = start, let previous = current else {
                    cancelStroke(); return true
                }
                current = p
                if brush != nil { paint(previous,p) }
                if event.phase == .ended {
                    if let kind = activeKind {
                        editing.addDevelopmentMask(kind,start:first,end:p,context:context); cancel()
                    } else if let selecting {
                        let isBox = abs(first.x-p.x) >= 0.003 && abs(first.y-p.y) >= 0.003
                        resetPointer(); generate(selecting,context:context,prompt:isBox ? [first,p] : [first])
                    } else {
                        if beforeStroke != candidate?.bitmap { changed = true }
                        resetPointer(); objectWillChange.send()
                    }
                }
            case .cancelled: break
            }
        } catch { cancelStroke() }
        return true
    }
}
