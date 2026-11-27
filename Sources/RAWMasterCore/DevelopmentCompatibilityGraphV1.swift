import Foundation

/// A read-only view of an existing renderer, not a second persisted recipe.
package struct DevelopmentCompatibilityGraphV1: Sendable {
  package enum Failure: Error, Equatable { case unsupportedVersion }

  package enum Stage: String, CaseIterable, Hashable, Sendable {
    case source, compatibilityCorrector, finalOutput
  }

  package struct NodeID: Hashable, Sendable {
    package let workID: String
    package let stage: Stage
  }

  package struct Edge: Equatable, Sendable {
    package let source: NodeID
    package let destination: NodeID
  }

  package let versionID: String
  package let source: EditingSourceSnapshot
  package let recipe: DevelopmentRecipe
  package let nodes: [NodeID]
  package let edges: [Edge]

  package init(_ version: EditingVersion) throws {
    // An artifact remains the authoritative image when present. It must not be reconstructed from its recipe.
    guard (version.kind == .original || version.kind == .development), version.artifact == nil, version.recipe.sceneGraph == nil else {
      throw Failure.unsupportedVersion
    }
    try version.recipe.validate()
    versionID = version.id
    source = version.source
    recipe = version.recipe
    let nodes = Stage.allCases.map { NodeID(workID: version.workID, stage: $0) }
    self.nodes = nodes
    edges = zip(nodes, nodes.dropFirst()).map { Edge(source: $0.0, destination: $0.1) }
  }
}
