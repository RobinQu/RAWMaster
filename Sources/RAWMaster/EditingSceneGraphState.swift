import Foundation
import RAWMasterCore

/// Transient workspace state. The only owner of pixels is still the controller's validated recipe.
struct EditingSceneGraphState {
    typealias Graph = DevelopmentSceneGraphV1
    var path: [UUID] = []
    var selection: Set<UUID> = []
    var edge: Graph.Edge?
    var viewing = Graph.View()
    var connection: Connection?
    var generation = UUID()
    var open = false
    var single: UUID? { selection.count == 1 ? selection.first : nil }

    struct Connection {
        let port: Graph.Edge
        let original: EditingController.SceneTicket
        let path: [UUID]
        var replacement: Graph.Endpoint
        var candidate: Graph?
        var reason: String?
    }

    mutating func resetSelection(in scope: Graph.Scope) {
        edge = nil
        if case let .node(end) = scope.output { selection = [end] }
        else { selection = [] }
        generation = UUID()
    }

    mutating func reconcile(_ graph: Graph?) {
        guard let graph else { self = .init(); return }
        while graph.scope(at: path) == nil { path.removeLast() }
        guard let scope = graph.scope(at: path) else { return }
        let valid = Set(scope.nodes.lazy.filter { !$0.operation.isCoverage }.map(\.id))
        if let edge, !scope.imageEdges.contains(edge) { self.edge = nil }
        selection.formIntersection(valid)
        if selection.isEmpty, edge == nil { resetSelection(in: scope) }
        if viewing.groupPath != path { viewing = .init() }
        if case let .node(id) = viewing.target, !valid.contains(id) { viewing = .init() }
        generation = UUID()
    }
    mutating func reconcileTopology(from before: Graph?, to after: Graph?) {
        // Photo recipe tickets already fence old values. Do not publish a fresh graph
        // presentation state and force a second SwiftUI layout on every exposure edit.
        func layout(_ scope: Graph.Scope) -> [Graph.Port] { scope.imageEdges.map(\.port) }
        if let before, let after, let left = before.scope(at: path), let right = after.scope(at: path),
           left.nodes.map(\.id) == right.nodes.map(\.id), layout(left) == layout(right), left.imageEdges == right.imageEdges { return }
        reconcile(after)
    }
}

extension DevelopmentSceneGraphV1.Operation {
    var sceneTypeName: String {
        switch self {
        case .corrector: return "调色"
        case .parallel: return "Parallel"
        case .layer: return "Layer"
        case .group: return "组"
        default: return "覆盖"
        }
    }
    var sceneEnabled: Bool {
        switch self {
        case let .corrector(_, _, _, _, _, enabled), let .parallel(_, _, enabled), let .layer(_, _, enabled), let .group(_, _, _, enabled): return enabled
        default: return true
        }
    }
    func withSceneEnabled(_ value: Bool) -> Self {
        switch self {
        case let .corrector(image, mask, ev, curve, strength, _): return .corrector(image: image, mask: mask, exposureEV: ev, curve: curve, strength: strength, enabled: value)
        case let .parallel(base, layers, _): return .parallel(base: base, layers: layers, enabled: value)
        case let .layer(base, layers, _): return .layer(base: base, layers: layers, enabled: value)
        case let .group(image, graph, strength, _): return .group(image: image, graph: graph, strength: strength, enabled: value)
        default: return self
        }
    }
}
