import Foundation
import Combine
import RAWMasterCore
import RAWMasterImaging

/// A ready selection belongs to exactly one photo, preset version and draft revision. Callers cancel when that scope ends.
@MainActor final class DevelopmentPresetMaskPreparation: ObservableObject {
    struct Ticket: Equatable {
        let record: DevelopmentPresetRecord
        let context: EditingInteractionContext
        let revision: UUID
    }
    typealias Generate = (DevelopmentSemanticTarget) async throws -> DevelopmentMaskLayerV3
    @Published private(set) var ticket: Ticket?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published private(set) var ready: [DevelopmentMaskLayerV3]?
    private var job: Task<Void, Never>?
    private var token: UUID?

    func cancel() {
        job?.cancel()
        job = nil
        token = nil
        ticket = nil
        ready = nil
        busy = false
        status = ""
    }

    func start(_ ticket: Ticket, source: DevelopmentLocalEditSourceBinding, existingLayerCount: Int,
               isCurrent: @escaping () -> Bool, generate: @escaping Generate) {
        cancel()
        guard isCurrent(), let intents = ticket.record.patch.semanticMasks else { return }
        self.ticket = ticket
        guard existingLayerCount + intents.count <= DevelopmentMaskLayerV3.maximumLayers else {
            status = "已达到每张照片的蒙版图层上限。"
            return
        }
        let token = UUID()
        self.token = token
        busy = true
        job = Task { [weak self] in
            var fresh: [DevelopmentSemanticTarget: DevelopmentMaskLayerV3] = [:]
            var layers: [DevelopmentMaskLayerV3] = []
            var changed = Set<String>()
            for (i, intent) in intents.enumerated() {
                guard let self, self.owns(token, isCurrent: isCurrent) else { return }
                self.status = "正在准备 " + String(i + 1) + "/" + String(intents.count) + " · " + intent.target.title
                do {
                    if fresh[intent.target] == nil { fresh[intent.target] = try await generate(intent.target) }
                    guard self.owns(token, isCurrent: isCurrent), let mask = fresh[intent.target] else { return }
                    let layer = try intent.configuring(mask, source: source)
                    layers.append(layer)
                    if layer.semanticSnapshot?.generator != intent.generator || layer.semanticSnapshot?.modelHashes != intent.modelHashes {
                        changed.insert(intent.target.title)
                    }
                } catch {
                    guard self.owns(token, isCurrent: isCurrent) else { return }
                    self.busy = false
                    if case DevelopmentMaskError.absent = error {
                        self.status = intent.target.title + " · 本张未找到目标，已跳过预设。"
                    } else { self.status = intent.target.title + " · " + error.localizedDescription }
                    return
                }
            }
            guard let self, self.owns(token, isCurrent: isCurrent) else { return }
            self.ready = layers
            self.busy = false
            self.status = "已准备 " + layers.map(\.name).joined(separator: "、")
            if !changed.isEmpty { self.status += " · 当前模型版本已变更：" + changed.sorted().joined(separator: "、") }
        }
    }

    private func owns(_ token: UUID, isCurrent: () -> Bool) -> Bool {
        guard self.token == token else { return false }
        guard !Task.isCancelled, isCurrent() else { cancel(); return false }
        return true
    }

    func layers(for ticket: Ticket) -> [DevelopmentMaskLayerV3]? { self.ticket == ticket ? ready : nil }
}
