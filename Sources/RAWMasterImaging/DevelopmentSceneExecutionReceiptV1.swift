import Foundation

/// What one scene render actually did. The Rust backend fills every counter from its completion
/// receipt; the Swift reference reports its own dispatch count and budget peak so fallbacks remain
/// diagnosable.
package struct DevelopmentSceneExecutionReceiptV1: Codable, Equatable, Sendable {
  package enum Backend: String, Codable, Sendable {
    case rust
    case swift
    case swiftFallback
    case passthrough
    case mixed
  }

  package let backend: Backend
  package let tiles: Int
  package let nodes: Int
  package let dispatches: Int
  package let coverageCacheHits: Int
  package let nodeCacheHits: Int
  package let peakBytes: Int
  package let budgetBytes: Int
  package let cpuMilliseconds: Double
  package let fallbackReason: String?
  package var photographicEngine: String?
  package var dagBackend: Backend?

  func includingPhotographic(_ applied: Bool) -> Self {
    guard applied else { return self }
    return Self(backend: backend == .passthrough ? .swift : .mixed, tiles: tiles, nodes: nodes, dispatches: dispatches,
      coverageCacheHits: coverageCacheHits, nodeCacheHits: nodeCacheHits, peakBytes: peakBytes, budgetBytes: budgetBytes,
      cpuMilliseconds: cpuMilliseconds, fallbackReason: fallbackReason, photographicEngine: "scene-photographic-v1-f32-metal", dagBackend: backend)
  }
}
