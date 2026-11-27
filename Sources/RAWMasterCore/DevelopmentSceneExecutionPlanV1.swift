import Foundation

/// An in-memory compiler for the homogeneous scene-linear, premultiplied AP1 exposure slice.
/// All inputs are derived from the same source image, so normal layer interpolation is linear in gain.
/// This is not a serialized graph, a generic mixer, or a bridge from display-referred recipes.
package struct DevelopmentSceneExecutionPlanV1: Sendable {
  package enum Input: Hashable, Sendable { case source, node(UUID) }
  package enum Operation: Sendable {
    case exposure(input: Input, ev: Float, enabled: Bool)
    case normalLayer(base: Input, layer: Input, weight: Float)
  }
  package struct Node: Sendable {
    package let id: UUID
    package let operation: Operation
    package init(id: UUID, operation: Operation) { self.id = id; self.operation = operation }
  }
  package enum Failure: Error, Equatable {
    case invalidNodes, missingNode(UUID), cycle(UUID), disconnectedNodes, invalidExposure, invalidWeight
  }

  private let exposureByNode: [UUID: Double]
  package let finalExposureEV: Float

  package init(nodes: [Node], final: Input) throws {
    guard (1...DevelopmentSceneWorkflowV1.maximumCorrectors).contains(nodes.count) else { throw Failure.invalidNodes }
    var byID: [UUID: Operation] = [:]
    for node in nodes {
      guard byID.updateValue(node.operation, forKey: node.id) == nil else { throw Failure.invalidNodes }
    }
    var visiting: Set<UUID> = [], exposures: [UUID: Double] = [:]
    func resolve(_ input: Input) throws -> Double {
      guard case let .node(id) = input else { return 0 }
      if let ev = exposures[id] { return ev }
      guard let operation = byID[id] else { throw Failure.missingNode(id) }
      guard visiting.insert(id).inserted else { throw Failure.cycle(id) }
      let ev: Double
      switch operation {
      case .exposure(let input, let increment, let enabled):
        guard (-12...12).contains(increment) else { throw Failure.invalidExposure }
        ev = try resolve(input) + (enabled ? Double(increment) : 0)
      case .normalLayer(let base, let layer, let weight):
        guard (0...1).contains(weight) else { throw Failure.invalidWeight }
        // Validate both paths, even at zero weight. An ignored edge may not hide an invalid graph.
        let a = try resolve(base), b = try resolve(layer)
        if weight == 0 || a == b { ev = a }
        else if weight == 1 { ev = b }
        else { ev = log2(exp2(a) * (1 - Double(weight)) + exp2(b) * Double(weight)) }
      }
      guard (-12...12).contains(ev) else { throw Failure.invalidExposure }
      visiting.remove(id)
      exposures[id] = ev
      return ev
    }
    let finalEV = try resolve(final)
    guard exposures.count == nodes.count else { throw Failure.disconnectedNodes }
    finalExposureEV = Float(finalEV)
    exposureByNode = exposures
  }

  package init(serial workflow: DevelopmentSceneWorkflowV1) throws {
    var previous = Input.source
    let nodes = workflow.correctors.map { corrector -> Node in
      let node = Node(id: corrector.id, operation: .exposure(input: previous, ev: corrector.exposureEV, enabled: corrector.enabled))
      previous = .node(corrector.id)
      return node
    }
    try self.init(nodes: nodes, final: previous)
  }

  package func exposureEV(at input: Input) throws -> Float {
    switch input {
    case .source: return 0
    case .node(let id):
      guard let ev = exposureByNode[id] else { throw Failure.missingNode(id) }
      return Float(ev)
    }
  }
}
