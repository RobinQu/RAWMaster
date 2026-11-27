import Foundation

/// Persistent grading graph over one scene-linear AP1 source. Scene geometry precedes the graph;
/// only the final image endpoint can become a master. View state is never serialized here.
package struct DevelopmentSceneGraphV1: Codable, Equatable, Sendable {
  package static let maximumNodes = 96
  package static let maximumDepth = 5
  package static let maximumLayers = 8

  package enum Failure: Error, Equatable {
    case unsupportedSchema, budget, duplicateID(UUID), missingNode(UUID), cycle(UUID)
    case incompatiblePort(UUID), disconnectedNodes, invalidParameter, unknownGroup(UUID), unknownNode(UUID)
    case ambiguousBoundary, staleEdge, unsupportedUngroup
  }

  package enum Endpoint: Hashable, Codable, Sendable {
    case input, node(UUID)

    package init(from decoder: Decoder) throws {
      let data = try decoder.singleValueContainer(), token = try data.decode(String.self)
      if token == "$input" { self = .input }
      else if let id = UUID(uuidString: token) { self = .node(id) }
      else { throw Failure.invalidParameter }
    }

    package func encode(to encoder: Encoder) throws {
      var data = encoder.singleValueContainer()
      switch self {
      case .input: try data.encode("$input")
      case .node(let id): try data.encode(id.uuidString)
      }
    }
  }

  package enum Blend: String, CaseIterable, Codable, Sendable {
    case normal, add, subtract, multiply, screen, overlay
    case softLight = "soft-light", hardLight = "hard-light"
    case lighten, darken, difference, color, luminosity
  }

  package struct Layer: Codable, Equatable, Sendable {
    package let image: Endpoint
    package let weight: Float
    package let mode: Blend

    package init(_ image: Endpoint, weight: Float, mode: Blend = .normal) {
      self.image = image; self.weight = weight; self.mode = mode
    }

    package init(from decoder: Decoder) throws {
      let data = try GraphFields(decoder, ["image", "weight", "mode"])
      self.init(try data.value("image"), weight: try data.value("weight"), mode: try data.value("mode"))
    }
  }

  package enum CoverageCombine: String, Codable, Sendable { case add, subtract, intersect }

  package enum Operation: Equatable, Sendable {
    case corrector(image: Endpoint, mask: UUID?, exposureEV: Float, curve: [SIMD2<Float>], strength: Float, enabled: Bool)
    /// Each branch is a complete grade. Blend their *changes from base*, without ordering.
    case parallel(base: Endpoint, layers: [Layer], enabled: Bool)
    /// Each layer blends over the previous one; the order and mode are significant.
    case layer(base: Endpoint, layers: [Layer], enabled: Bool)
    case group(image: Endpoint, graph: Scope, strength: Float, enabled: Bool)
    /// Normalized source-edge coordinates; values are coverage, not color.
    case linearCoverage(start: SIMD2<Float>, end: SIMD2<Float>)
    case radialCoverage(center: SIMD2<Float>, radii: SIMD2<Float>, feather: Float)
    case combineCoverage(base: UUID, other: UUID, mode: CoverageCombine)
    case adjustCoverage(mask: UUID, strength: Float, inverted: Bool)
    /// Provider-produced coverage (for example a deterministic segmentation mask). The id names
    /// a model stage supplied beside the graph; it is not a node id.
    case externalCoverage(id: UUID)

    package var isCoverage: Bool {
      switch self {
      case .linearCoverage, .radialCoverage, .combineCoverage, .adjustCoverage, .externalCoverage: return true
      default: return false
      }
    }
  }

  package struct Node: Equatable, Sendable, Identifiable, Codable {
    package let id: UUID
    package let name: String
    package let operation: Operation

    package init(id: UUID = UUID(), name: String, operation: Operation) {
      self.id = id; self.name = name; self.operation = operation
    }

    package init(from decoder: Decoder) throws {
      let data = try GraphFields(decoder, ["id", "name", "operation"])
      self.init(id: try data.value("id"), name: try data.value("name"), operation: try data.value("operation"))
    }
  }

  package struct Scope: Codable, Equatable, Sendable {
    package let nodes: [Node]
    package let output: Endpoint

    package init(nodes: [Node], output: Endpoint) { self.nodes = nodes; self.output = output }

    package init(from decoder: Decoder) throws {
      // Guard recursion during decoding rather than waiting until after all groups were allocated.
      guard decoder.codingPath.filter({ $0.stringValue == "graph" }).count <= maximumDepth else { throw Failure.budget }
      let data = try GraphFields(decoder, ["nodes", "output"])
      let nodes: [Node] = try data.array("nodes", maximum: maximumNodes)
      self.init(nodes: nodes, output: try data.value("output"))
    }
  }

  package struct View: Equatable, Sendable {
    package enum Target: Equatable, Sendable { case final, node(UUID), bypass }
    package let groupPath: [UUID]
    package let target: Target

    package init(groupPath: [UUID] = [], target: Target = .final) {
      self.groupPath = groupPath; self.target = target
    }
  }

  private let schemaVersion = 1
  package let graph: Scope
  package let output: DevelopmentSceneOutputStateV1.Version

  package init(graph: Scope, output: DevelopmentSceneOutputStateV1.Version) throws {
    var all: Set<UUID> = []
    try Self.validate(graph, depth: 1, all: &all)
    self.graph = graph; self.output = output
  }

  package init(from decoder: Decoder) throws {
    let data = try GraphFields(decoder, ["schemaVersion", "graph", "output"])
    guard try data.value("schemaVersion", Int.self) == 1 else { throw Failure.unsupportedSchema }
    try self.init(graph: data.value("graph"), output: data.value("output"))
  }

  /// Replace the whole validated value so failed mutations leave the committed graph untouched.
  package func replacingGraph(_ graph: Scope) throws -> Self { try Self(graph: graph, output: output) }

  /// Outside clones the coverage dependencies, then inverts the copy. The new corrector is neutral.
  package func addingOutside(of corrector: UUID, before successor: UUID? = nil,
                              correctorID: UUID = UUID(), maskID: UUID = UUID(), generate: () -> UUID = UUID.init) throws -> Self {
    guard let node = graph.nodes.first(where: { $0.id == corrector }),
          case let .corrector(_, mask?, _, _, _, _) = node.operation else { throw Failure.unknownNode(corrector) }
    let source = Endpoint.node(corrector)
    let added = Node(id: correctorID, name: "Outside", operation: .corrector(image: source, mask: maskID,
      exposureEV: 0, curve: [], strength: 1, enabled: true))
    let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    var copyIDs: [UUID: UUID] = [:]
    func collect(_ id: UUID) {
      guard copyIDs[id] == nil else { return }
      copyIDs[id] = generate()
      for ref in byID[id]!.operation.coverages { collect(ref) }
    }
    collect(mask)
    let copy = graph.nodes.compactMap { node -> Node? in
      guard let id = copyIDs[node.id] else { return nil }
      return .init(id: id, name: node.name, operation: node.operation.remapped(copyIDs, clone: { $0 }))
    }
    let coverage = Node(id: maskID, name: "Outside coverage", operation: .adjustCoverage(mask: copyIDs[mask]!, strength: 1, inverted: true))
    // Refuse ambiguous fan-out. Explicit successor only applies to its single image input.
    if let successor {
      guard let index = graph.nodes.firstIndex(where: { $0.id == successor }),
            let replacement = graph.nodes[index].operation.replacingSingleImageInput(source, with: .node(correctorID)) else {
        throw Failure.incompatiblePort(successor)
      }
      var nodes = graph.nodes
      nodes[index] = .init(id: successor, name: nodes[index].name, operation: replacement)
      return try replacingGraph(.init(nodes: nodes + copy + [coverage, added], output: graph.output))
    }
    guard graph.output == source else { throw Failure.incompatiblePort(corrector) }
    return try replacingGraph(.init(nodes: graph.nodes + copy + [coverage, added], output: .node(correctorID)))
  }

  /// Remap all node references as one unit; there are no source-specific pixels in these coverage operators.
  package func remapped(generate: () -> UUID = UUID.init) throws -> Self {
    var ids: [UUID: UUID] = [:]
    func collect(_ scope: Scope) {
      for node in scope.nodes {
        ids[node.id] = generate()
        if case let .group(_, graph, _, _) = node.operation { collect(graph) }
      }
    }
    func clone(_ scope: Scope) -> Scope {
      .init(nodes: scope.nodes.map { node in
        .init(id: ids[node.id]!, name: node.name, operation: node.operation.remapped(ids, clone: clone))
      }, output: scope.output.remapped(ids))
    }
    collect(graph)
    return try replacingGraph(clone(graph))
  }

  private static func validate(_ graph: Scope, depth: Int, all: inout Set<UUID>) throws {
    guard depth <= maximumDepth, graph.nodes.count <= maximumNodes - all.count else { throw Failure.budget }
    var byID: [UUID: Operation] = [:]
    for node in graph.nodes {
      guard all.insert(node.id).inserted else { throw Failure.duplicateID(node.id) }
      guard !node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, node.name.utf8.count <= 256 else { throw Failure.invalidParameter }
      byID[node.id] = node.operation
    }
    for node in graph.nodes {
      try node.operation.validateParameters()
      if case let .group(_, child, _, _) = node.operation { try validate(child, depth: depth + 1, all: &all) }
    }
    var active: Set<UUID> = [], resolved: Set<UUID> = []
    func visit(_ endpoint: Endpoint, asCoverage: Bool) throws {
      guard case .node(let id) = endpoint else { return } // scope input is always an image
      guard let op = byID[id] else { throw Failure.missingNode(id) }
      guard op.isCoverage == asCoverage else { throw Failure.incompatiblePort(id) }
      guard !resolved.contains(id) else { return }
      guard active.insert(id).inserted else { throw Failure.cycle(id) }
      for image in op.images { try visit(image, asCoverage: false) }
      for mask in op.coverages { try visit(.node(mask), asCoverage: true) }
      active.remove(id); resolved.insert(id)
    }
    try visit(graph.output, asCoverage: false)
    guard resolved.count == graph.nodes.count else { throw Failure.disconnectedNodes }
  }
}

private struct GraphFields {
  let data: KeyedDecodingContainer<RecipeCodingKey>
  init(_ decoder: Decoder, _ keys: [String]) throws {
    try RecipeCoding.requireKeys(decoder, keys)
    data = try decoder.container(keyedBy: RecipeCodingKey.self)
  }
  func value<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T { try data.decode(type, forKey: .init(key)) }
  func array<T: Decodable>(_ key: String, maximum: Int) throws -> [T] {
    var list = try data.nestedUnkeyedContainer(forKey: .init(key)), values: [T] = []
    while !list.isAtEnd {
      guard values.count < maximum else { throw DevelopmentSceneGraphV1.Failure.budget }
      values.append(try list.decode(T.self))
    }
    return values
  }
}

extension DevelopmentSceneGraphV1.Operation: Codable {
  typealias Graph = DevelopmentSceneGraphV1
  private enum Kind: String, Codable { case corrector, parallel, layer, group, linearCoverage, radialCoverage, combineCoverage, adjustCoverage, externalCoverage }

  package init(from decoder: Decoder) throws {
    let object = try decoder.container(keyedBy: RecipeCodingKey.self)
    let kind = try object.decode(Kind.self, forKey: .init("kind"))
    func fields(_ keys: String...) throws -> GraphFields { try GraphFields(decoder, ["kind"] + keys) }
    switch kind {
    case .corrector:
      let d = try fields("image", "mask", "exposureEV", "curve", "strength", "enabled")
      self = .corrector(image: try d.value("image"), mask: try d.value("mask", UUID?.self), exposureEV: try d.value("exposureEV"),
        curve: try d.array("curve", maximum: 16), strength: try d.value("strength"), enabled: try d.value("enabled"))
    case .parallel, .layer:
      let d = try fields("base", "layers", "enabled")
      let base: Graph.Endpoint = try d.value("base"), layers: [Graph.Layer] = try d.array("layers", maximum: Graph.maximumLayers)
      let enabled: Bool = try d.value("enabled")
      self = kind == .parallel ? .parallel(base: base, layers: layers, enabled: enabled) : .layer(base: base, layers: layers, enabled: enabled)
    case .group:
      let d = try fields("image", "graph", "strength", "enabled")
      self = .group(image: try d.value("image"), graph: try d.value("graph"), strength: try d.value("strength"), enabled: try d.value("enabled"))
    case .linearCoverage:
      let d = try fields("start", "end")
      self = .linearCoverage(start: try d.value("start"), end: try d.value("end"))
    case .radialCoverage:
      let d = try fields("center", "radii", "feather")
      self = .radialCoverage(center: try d.value("center"), radii: try d.value("radii"), feather: try d.value("feather"))
    case .combineCoverage:
      let d = try fields("base", "other", "mode")
      self = .combineCoverage(base: try d.value("base"), other: try d.value("other"), mode: try d.value("mode"))
    case .adjustCoverage:
      let d = try fields("mask", "strength", "inverted")
      self = .adjustCoverage(mask: try d.value("mask"), strength: try d.value("strength"), inverted: try d.value("inverted"))
    case .externalCoverage:
      let d = try fields("id")
      self = .externalCoverage(id: try d.value("id"))
    }
  }

  package func encode(to encoder: Encoder) throws {
    var data = encoder.container(keyedBy: RecipeCodingKey.self)
    func write<T: Encodable>(_ key: String, _ value: T) throws { try data.encode(value, forKey: .init(key)) }
    func kind(_ kind: Kind) throws { try write("kind", kind) }
    switch self {
    case let .corrector(image, mask, exposure, curve, strength, enabled):
      try kind(.corrector); try write("image", image); try write("mask", mask); try write("exposureEV", exposure)
      try write("curve", curve); try write("strength", strength); try write("enabled", enabled)
    case let .parallel(base, layers, enabled), let .layer(base, layers, enabled):
      if case .parallel = self { try kind(.parallel) } else { try kind(.layer) }
      try write("base", base); try write("layers", layers); try write("enabled", enabled)
    case let .group(image, graph, strength, enabled):
      try kind(.group); try write("image", image); try write("graph", graph); try write("strength", strength); try write("enabled", enabled)
    case let .linearCoverage(start, end): try kind(.linearCoverage); try write("start", start); try write("end", end)
    case let .radialCoverage(center, radii, feather):
      try kind(.radialCoverage); try write("center", center); try write("radii", radii); try write("feather", feather)
    case let .combineCoverage(base, other, mode): try kind(.combineCoverage); try write("base", base); try write("other", other); try write("mode", mode)
    case let .adjustCoverage(mask, strength, inverted): try kind(.adjustCoverage); try write("mask", mask); try write("strength", strength); try write("inverted", inverted)
    case let .externalCoverage(id): try kind(.externalCoverage); try write("id", id)
    }
  }

  var images: [Graph.Endpoint] {
    switch self {
    case let .corrector(image, _, _, _, _, _), let .group(image, _, _, _): return [image]
    case let .parallel(base, layers, _), let .layer(base, layers, _): return [base] + layers.map(\.image)
    default: return []
    }
  }

  var coverages: [UUID] {
    switch self {
    case let .corrector(_, mask, _, _, _, _): return Array([mask].compactMap { $0 })
    case let .adjustCoverage(mask, _, _): return [mask]
    case let .combineCoverage(base, other, _): return [base, other]
    default: return []
    }
  }

  fileprivate func validateParameters() throws {
    func unit(_ x: Float) -> Bool { (0...1).contains(x) }
    func point(_ p: SIMD2<Float>) -> Bool { unit(p.x) && unit(p.y) }
    switch self {
    case let .corrector(_, _, exposure, curve, strength, _):
      guard (-12...12).contains(exposure), unit(strength), curve.isEmpty || (2...16).contains(curve.count),
        curve.allSatisfy({ (-24...24).contains($0.x) && (-24...24).contains($0.y) }),
        zip(curve, curve.dropFirst()).allSatisfy({ $1.x - $0.x >= 0.001 && $1.y >= $0.y }) else { throw Graph.Failure.invalidParameter }
    case let .parallel(_, layers, _), let .layer(_, layers, _):
      guard (1...Graph.maximumLayers).contains(layers.count), layers.allSatisfy({ unit($0.weight) }) else { throw Graph.Failure.invalidParameter }
      if case .parallel = self {
        guard layers.allSatisfy({ $0.mode == .normal }) else { throw Graph.Failure.invalidParameter }
      }
    case let .group(_, _, strength, _), let .adjustCoverage(_, strength, _):
      guard unit(strength) else { throw Graph.Failure.invalidParameter }
    case let .linearCoverage(start, end):
      guard point(start), point(end), max(abs(end.x - start.x), abs(end.y - start.y)) >= 0.0001 else { throw Graph.Failure.invalidParameter }
    case let .radialCoverage(center, radii, feather):
      guard point(center), (0.0001...2).contains(radii.x), (0.0001...2).contains(radii.y), unit(feather) else { throw Graph.Failure.invalidParameter }
    case .combineCoverage, .externalCoverage: break
    }
  }

  fileprivate func replacingSingleImageInput(_ original: Graph.Endpoint, with input: Graph.Endpoint) -> Self? {
    switch self {
    case let .corrector(image, mask, ev, curve, strength, enabled) where image == original:
      return .corrector(image: input, mask: mask, exposureEV: ev, curve: curve, strength: strength, enabled: enabled)
    case let .group(image, graph, strength, enabled) where image == original:
      return .group(image: input, graph: graph, strength: strength, enabled: enabled)
    default: return nil
    }
  }

  fileprivate func remapped(_ ids: [UUID: UUID], clone: (Graph.Scope) -> Graph.Scope) -> Self {
    func endpoint(_ e: Graph.Endpoint) -> Graph.Endpoint { e.remapped(ids) }
    func layer(_ layer: Graph.Layer) -> Graph.Layer { .init(endpoint(layer.image), weight: layer.weight, mode: layer.mode) }
    switch self {
    case let .corrector(image, mask, ev, curve, strength, enabled):
      return .corrector(image: endpoint(image), mask: mask.map { ids[$0]! }, exposureEV: ev, curve: curve, strength: strength, enabled: enabled)
    case let .parallel(base, layers, enabled): return .parallel(base: endpoint(base), layers: layers.map(layer), enabled: enabled)
    case let .layer(base, layers, enabled): return .layer(base: endpoint(base), layers: layers.map(layer), enabled: enabled)
    case let .group(image, graph, strength, enabled): return .group(image: endpoint(image), graph: clone(graph), strength: strength, enabled: enabled)
    case let .combineCoverage(base, other, mode): return .combineCoverage(base: ids[base]!, other: ids[other]!, mode: mode)
    case let .adjustCoverage(mask, strength, inverted): return .adjustCoverage(mask: ids[mask]!, strength: strength, inverted: inverted)
    case .linearCoverage, .radialCoverage, .externalCoverage: return self
    }
  }
}

private extension DevelopmentSceneGraphV1.Endpoint {
  func remapped(_ ids: [UUID: UUID]) -> Self {
    if case .node(let id) = self { return .node(ids[id]!) }
    return .input
  }
}
