import Foundation

/// What one scene render actually did. The Rust backend fills every counter from its completion
/// receipt; the Swift reference reports its own dispatch count and budget peak so fallbacks remain
/// diagnosable.
struct DevelopmentSceneExecutionReceiptV1: Equatable, Sendable {
  enum Backend: String, Sendable {
    case rust
    case swift
    case swiftFallback
  }

  let backend: Backend
  let tiles: Int
  let nodes: Int
  let dispatches: Int
  let coverageCacheHits: Int
  let nodeCacheHits: Int
  let peakBytes: Int
  let budgetBytes: Int
  let cpuMilliseconds: Double
  let fallbackReason: String?
}
