import Foundation

public struct ManagedModelProgress: Sendable {
  public let phase: String
  public let completedBytes: Int64
  public let totalBytes: Int64
  public let message: String
  public let reusedBytes: Int64?
  public init(phase: String, completedBytes: Int64, totalBytes: Int64, message: String, reusedBytes: Int64? = nil) {
    self.phase = phase; self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.message = message; self.reusedBytes = reusedBytes
  }
}
extension ManagedRuntimeService {
  public func prepareModels(includeTextureFix: Bool = false, acceptedResearchLicense: Bool, progress: @escaping @Sendable (ManagedModelProgress) -> Void) async throws {
    guard acceptedResearchLicense else { throw AIServiceError.invalidConfiguration("请先阅读并接受 Qwen2.1 研究/评估许可；商业用途需要另行许可") }
    try await prepareModelProcess(includeTextureFix: includeTextureFix, progress: progress)
  }
}
