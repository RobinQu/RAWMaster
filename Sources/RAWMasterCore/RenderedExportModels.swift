import Foundation

public enum RenderedExportFormat: String, Codable, CaseIterable, Sendable { case jpeg8, tiff16, png16 }
public enum RenderedExportState: String, Codable, Sendable { case queued, prepared, succeeded, needsAttention, cancelled }

/// Frozen single-item render/export plan and durable publication receipt. External output bytes are not a production archive.
public struct RenderedExportRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var commandID: String
  public var requestFingerprint: String
  public var workID: String
  public var versionID: String
  /// Active HDR appearance at submission. The version ID continues to reference a stored parent.
  public var frozenSceneRecipe: DevelopmentRecipe?
  public var format: RenderedExportFormat
  public var targetURL: URL
  public var state: RenderedExportState
  public var preparedArtifact: RenderArtifact?
  /// Recognized renderer-owned stage on the destination volume. Retained after preparation errors/cancellation.
  public var stagingURL: URL?
  public var error: String?
  public var completedAt: Date?
  public var createdAt: Date
  public var updatedAt: Date
  public init(id: String = UUID().uuidString, commandID: String, requestFingerprint: String, workID: String,
              versionID: String, format: RenderedExportFormat, targetURL: URL, createdAt: Date = Date()) {
    self.id = id; self.commandID = commandID; self.requestFingerprint = requestFingerprint
    self.workID = workID; self.versionID = versionID; self.format = format; self.targetURL = targetURL
    self.state = .queued; self.preparedArtifact = nil; self.stagingURL = nil; self.error = nil; self.completedAt = nil
    self.createdAt = createdAt; self.updatedAt = createdAt
  }
}
