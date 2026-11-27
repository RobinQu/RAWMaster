import Foundation

extension DevelopmentSceneGraphV1 {
  package enum Port: Hashable, Sendable {
    case final, image(UUID), base(UUID), layer(UUID, Int)
  }

  /// The anchor is a specific incoming port *and* its expected producer, never a guess from selection.
  package struct Edge: Hashable, Sendable {
    package let port: Port
    package let upstream: Endpoint
    package init(_ port: Port, upstream: Endpoint) { self.port = port; self.upstream = upstream }
  }

  package enum Insert: Sendable { case serial, parallel(mixerID: UUID), layer(mixerID: UUID) }

  package func scope(at path: [UUID]) -> Scope? {
    var current = graph
    for id in path {
      guard case let .group(_, child, _, _)? = current.nodes.first(where: { $0.id == id })?.operation else { return nil }
      current = child
    }
    return current
  }

  package func updating(_ id: UUID, at path: [UUID], _ change: (Node) throws -> Node) throws -> Self {
    try transformScope(path) { scope in
      guard let index = scope.nodes.firstIndex(where: { $0.id == id }) else { throw Failure.unknownNode(id) }
      var nodes = scope.nodes
      let old = nodes[index], next = try change(old)
      guard next.id == old.id, next.operation.images == old.operation.images,
            next.operation.coverages == old.operation.coverages else { throw Failure.staleEdge }
      nodes[index] = next
      return .init(nodes: nodes, output: scope.output)
    }
  }

  package func movingLayer(of id: UUID, from start: Int, to end: Int, at path: [UUID]) throws -> Self {
    try transformScope(path) { scope in
      guard let index = scope.nodes.firstIndex(where: { $0.id == id }),
            case let .layer(base, layers, enabled) = scope.nodes[index].operation,
            layers.indices.contains(start), layers.indices.contains(end) else { throw Failure.incompatiblePort(id) }
      var ordered = layers, nodes = scope.nodes
      let layer = ordered.remove(at: start)
      ordered.insert(layer, at: end)
      nodes[index] = .init(id: id, name: nodes[index].name, operation: .layer(base: base, layers: ordered, enabled: enabled))
      return .init(nodes: nodes, output: scope.output)
    }
  }

  package func addingLayer(to id: UUID, at path: [UUID], nodeID: UUID = UUID()) throws -> Self {
    try transformScope(path) { scope in
      guard let index = scope.nodes.firstIndex(where: { $0.id == id }) else { throw Failure.unknownNode(id) }
      let mixer = scope.nodes[index], inputs: (Endpoint, [Layer], Bool)
      switch mixer.operation {
      case let .parallel(base, layers, enabled), let .layer(base, layers, enabled): inputs = (base, layers, enabled)
      default: throw Failure.incompatiblePort(id)
      }
      let branch = Node(id: nodeID, name: "调色支路", operation: .corrector(image: inputs.0, mask: nil,
        exposureEV: 0, curve: [], strength: 1, enabled: true))
      var nodes = scope.nodes
      nodes[index] = .init(id: id, name: mixer.name, operation: mixer.operation.mixer(base: inputs.0,
        layers: inputs.1 + [.init(.node(nodeID), weight: 0)], enabled: inputs.2))
      return .init(nodes: nodes + [branch], output: scope.output)
    }
  }

  package func rewiring(_ edge: Edge, to replacement: Endpoint, at path: [UUID] = []) throws -> Self {
    try transformScope(path) { try Self.replacing(edge, with: replacement, in: $0) }
  }

  package func inserting(_ kind: Insert, on edge: Edge, at path: [UUID] = [],
                         name: String = "Corrector", id: UUID = UUID()) throws -> Self {
    try transformScope(path) { scope in
      let corrector = Node(id: id, name: name, operation: .corrector(image: edge.upstream, mask: nil,
        exposureEV: 0, curve: [], strength: 1, enabled: true))
      let inserted: [Node], replacement: Endpoint
      switch kind {
      case .serial:
        inserted = [corrector]; replacement = .node(id)
      case .parallel(let mixerID), .layer(let mixerID):
        let layers = [Layer(.node(id), weight: 0)]
        let parallel: Bool
        if case .parallel = kind { parallel = true } else { parallel = false }
        inserted = [corrector, .init(id: mixerID, name: parallel ? "Parallel" : "Layer",
          operation: parallel ? .parallel(base: edge.upstream, layers: layers, enabled: true)
                              : .layer(base: edge.upstream, layers: layers, enabled: true))]
        replacement = .node(mixerID)
      }
      let next = try Self.replacing(edge, with: replacement, in: scope)
      return .init(nodes: next.nodes + inserted, output: next.output)
    }
  }

  /// Group a subgraph that has exactly one incoming producer and one outgoing producer.
  /// Coverage can be brought along, but may not remain shared across a scope boundary.
  package func grouping(_ selection: Set<UUID>, at path: [UUID] = [], name: String = "Group", id: UUID = UUID()) throws -> Self {
    try transformScope(path) { scope in
      let selected = scope.nodes.filter { selection.contains($0.id) }
      guard !selected.isEmpty, selected.count == selection.count else { throw Failure.ambiguousBoundary }
      let remainder = scope.nodes.filter { !selection.contains($0.id) }
      func local(_ e: Endpoint) -> Bool { if case let .node(id) = e { return selection.contains(id) }; return false }
      let inputs = Set(selected.flatMap(\.operation.images).filter { !local($0) })
      let outputs = Set((remainder.flatMap(\.operation.images) + [scope.output]).filter(local))
      guard inputs.count == 1, outputs.count == 1, let input = inputs.first, let output = outputs.first,
            selected.allSatisfy({ $0.operation.coverages.allSatisfy(selection.contains) }),
            remainder.allSatisfy({ $0.operation.coverages.allSatisfy { !selection.contains($0) } }) else { throw Failure.ambiguousBoundary }
      let child = Scope(nodes: selected.map { $0.mappingImages { $0 == input ? .input : $0 } }, output: output)
      let grouped = Node(id: id, name: name, operation: .group(image: input, graph: child, strength: 1, enabled: true))
      return .init(nodes: remainder.map { $0.mappingImages { $0 == output ? .node(id) : $0 } } + [grouped],
        output: scope.output == output ? .node(id) : scope.output)
    }
  }

  package func ungrouping(_ id: UUID, at path: [UUID] = []) throws -> Self {
    try transformScope(path) { scope in
      guard case let .group(input, inner, strength, enabled)? = scope.nodes.first(where: { $0.id == id })?.operation else {
        throw Failure.unknownGroup(id)
      }
      // Removing an attenuated or disabled group would otherwise change the rendered image.
      guard strength == 1, enabled else { throw Failure.unsupportedUngroup }
      let end = inner.output == .input ? input : inner.output
      let outer = scope.nodes.filter { $0.id != id }.map { $0.mappingImages { $0 == .node(id) ? end : $0 } }
      return .init(nodes: outer + inner.nodes.map { $0.mappingImages { $0 == .input ? input : $0 } },
        output: scope.output == .node(id) ? end : scope.output)
    }
  }

  package func insertingTemplate(_ template: Self, on edge: Edge, at path: [UUID] = [],
                                 name: String, id: UUID = UUID()) throws -> Self {
    // Template scope carries only grade intent, not the donor photo's SDR trim, output route, or identity.
    let inner = try template.remapped().graph
    return try transformScope(path) { scope in
      let next = try Self.replacing(edge, with: .node(id), in: scope)
      let group = Node(id: id, name: name, operation: .group(image: edge.upstream, graph: inner, strength: 1, enabled: true))
      return .init(nodes: next.nodes + [group], output: next.output)
    }
  }

  private func transformScope(_ path: [UUID], body: (Scope) throws -> Scope) throws -> Self {
    guard path.count < Self.maximumDepth else { throw Failure.budget }
    func visit(_ scope: Scope, path: ArraySlice<UUID>) throws -> Scope {
      guard let id = path.first else { return try body(scope) }
      guard let i = scope.nodes.firstIndex(where: { $0.id == id }),
            case let .group(image, child, strength, enabled) = scope.nodes[i].operation else { throw Failure.unknownGroup(id) }
      var nodes = scope.nodes
      nodes[i] = .init(id: id, name: nodes[i].name, operation: .group(image: image,
        graph: try visit(child, path: path.dropFirst()), strength: strength, enabled: enabled))
      return .init(nodes: nodes, output: scope.output)
    }
    return try replacingGraph(visit(graph, path: path[...]))
  }

  private static func replacing(_ edge: Edge, with replacement: Endpoint, in scope: Scope) throws -> Scope {
    if edge.port == .final {
      guard scope.output == edge.upstream else { throw Failure.staleEdge }
      return .init(nodes: scope.nodes, output: replacement)
    }
    let id: UUID
    switch edge.port {
    case .final: throw Failure.staleEdge
    case .image(let value), .base(let value), .layer(let value, _): id = value
    }
    guard let i = scope.nodes.firstIndex(where: { $0.id == id }) else { throw Failure.unknownNode(id) }
    var nodes = scope.nodes
    let node = nodes[i], next: Operation
    switch (edge.port, node.operation) {
    case (.image, .corrector(let image, _, _, _, _, _)), (.image, .group(let image, _, _, _)):
      guard image == edge.upstream else { throw Failure.staleEdge }
      next = node.operation.mappingImages { _ in replacement }
    case (.base, .parallel(let base, let layers, let enabled)), (.base, .layer(let base, let layers, let enabled)):
      guard base == edge.upstream else { throw Failure.staleEdge }
      next = node.operation.mixer(base: replacement, layers: layers, enabled: enabled)
    case (.layer(_, let slot), .parallel(let base, var layers, let enabled)), (.layer(_, let slot), .layer(let base, var layers, let enabled)):
      guard layers.indices.contains(slot), layers[slot].image == edge.upstream else { throw Failure.staleEdge }
      layers[slot] = .init(replacement, weight: layers[slot].weight, mode: layers[slot].mode)
      next = node.operation.mixer(base: base, layers: layers, enabled: enabled)
    default: throw Failure.incompatiblePort(id)
    }
    nodes[i] = .init(id: id, name: node.name, operation: next)
    return .init(nodes: nodes, output: scope.output)
  }
}

extension DevelopmentSceneGraphV1.Scope {
  package var imageEdges: [DevelopmentSceneGraphV1.Edge] {
    typealias Edge = DevelopmentSceneGraphV1.Edge
    return nodes.flatMap { node -> [Edge] in
      switch node.operation {
      case let .corrector(image, _, _, _, _, _), let .group(image, _, _, _): return [.init(.image(node.id), upstream: image)]
      case let .parallel(base, layers, _), let .layer(base, layers, _):
        return [.init(.base(node.id), upstream: base)] + layers.enumerated().map { .init(.layer(node.id, $0.offset), upstream: $0.element.image) }
      default: return []
      }
    } + [.init(.final, upstream: output)]
  }

  package func dependencies(of selection: Set<UUID>) -> Set<UUID> {
    let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    var included = selection
    func masks(_ id: UUID) {
      for dependency in byID[id]?.operation.coverages ?? [] where included.insert(dependency).inserted { masks(dependency) }
    }
    selection.forEach(masks)
    return included
  }
}

private extension DevelopmentSceneGraphV1.Node {
  func mappingImages(_ map: (DevelopmentSceneGraphV1.Endpoint) -> DevelopmentSceneGraphV1.Endpoint) -> Self {
    .init(id: id, name: name, operation: operation.mappingImages(map))
  }
}

private extension DevelopmentSceneGraphV1.Operation {
  func mappingImages(_ map: (Graph.Endpoint) -> Graph.Endpoint) -> Self {
    switch self {
    case let .corrector(image, mask, exposure, curve, strength, enabled):
      return .corrector(image: map(image), mask: mask, exposureEV: exposure, curve: curve, strength: strength, enabled: enabled)
    case let .group(image, graph, strength, enabled): return .group(image: map(image), graph: graph, strength: strength, enabled: enabled)
    case let .parallel(base, layers, enabled), let .layer(base, layers, enabled):
      return mixer(base: map(base), layers: layers.map { .init(map($0.image), weight: $0.weight, mode: $0.mode) }, enabled: enabled)
    default: return self
    }
  }
  func mixer(base: Graph.Endpoint, layers: [Graph.Layer], enabled: Bool) -> Self {
    if case .parallel = self { return .parallel(base: base, layers: layers, enabled: enabled) }
    return .layer(base: base, layers: layers, enabled: enabled)
  }
}
