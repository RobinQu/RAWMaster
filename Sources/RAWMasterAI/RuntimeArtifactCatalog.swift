import CryptoKit
import Foundation

public enum LocalAISetupError: Error, LocalizedError, Sendable, Equatable {
  case unavailable, invalidCatalog, unsupportedPlatform, unsafeArtifact, insufficientSpace
  case consentRequired, modelMismatch, activeChanged, operationRevoked, preparationFailed
  public var errorDescription: String? {
    switch self {
    case .unavailable: return "此应用尚未包含受信任的本机 AI 运行包"
    case .invalidCatalog: return "本机 AI 运行包目录身份不匹配"
    case .unsupportedPlatform: return "此固定运行包不支持当前系统或处理器"
    case .unsafeArtifact: return "运行包路径、内容或文件身份检查失败"
    case .insufficientSpace: return "可用空间不足，旧运行时保持不变"
    case .consentRequired: return "请阅读模型条款并明确选择是否接受"
    case .modelMismatch: return "已有模型不符合固定身份，原文件保持不变"
    case .activeChanged: return "活动运行时已变化，本次候选未激活"
    case .operationRevoked: return "准备操作已取消或被关闭"
    case .preparationFailed: return "本机 AI 准备未完成，可重试并保留已下载数据"
    }
  }
}

public struct RuntimeArtifact: Codable, Sendable, Equatable {
  public let id: String
  public let platform: String
  public let minimumMacOS: String
  public let archivePath: String
  public let archiveByteCount: Int64
  public let archiveSHA256: String
  public let innerManifestSHA256: String
  public let manifestEntryCount: Int
  public let unpackedByteCount: Int64
}

/// Expected digest is an application trust anchor, never supplied by a downloaded catalog itself.
public struct RuntimeArtifactCatalog: Sendable {
  private struct Document: Decodable { let schemaVersion: Int; let artifacts: [RuntimeArtifact] }
  public let identitySHA256: String
  public let artifacts: [RuntimeArtifact]
  let resourceRoot: URL
  // Root's verified fixed data archive. No runtime URL, latest tag or client dependency solver.
  static let bundledCatalogSHA256: String? = "6ae90188e67edc237a0a90ac7bf2d5acf26afcbdff697a4355f599dd9e85ec37"

  public init(catalogURL: URL, expectedSHA256: String, resourceRoot: URL) throws {
    let data = try Data(contentsOf: catalogURL, options: [.mappedIfSafe])
    guard data.count <= 1_048_576, RuntimeArtifactFiles.digest(data) == expectedSHA256,
          RuntimeArtifactFiles.validSHA(expectedSHA256) else { throw LocalAISetupError.invalidCatalog }
    let document = try JSONDecoder().decode(Document.self, from: data)
    guard document.schemaVersion == 1, !document.artifacts.isEmpty, document.artifacts.count <= 16,
          Set(document.artifacts.map(\.id)).count == document.artifacts.count else { throw LocalAISetupError.invalidCatalog }
    for item in document.artifacts {
      guard RuntimeArtifactFiles.validID(item.id), item.platform == "macos-arm64",
            RuntimeArtifactFiles.safeRelativePath(item.archivePath), !item.archivePath.contains("/"),
            item.archivePath.hasSuffix(".zip"), item.archiveByteCount > 0, item.archiveByteCount < 4_294_967_295,
            RuntimeArtifactFiles.validSHA(item.archiveSHA256), RuntimeArtifactFiles.validSHA(item.innerManifestSHA256),
            (1...20_000).contains(item.manifestEntryCount), (1...8_589_934_592).contains(item.unpackedByteCount),
            Self.version(item.minimumMacOS) != nil else { throw LocalAISetupError.invalidCatalog }
    }
    identitySHA256 = expectedSHA256; artifacts = document.artifacts
    self.resourceRoot = resourceRoot.resolvingSymlinksInPath()
  }

  public static func bundled() throws -> RuntimeArtifactCatalog {
    guard let expected = bundledCatalogSHA256 else { throw LocalAISetupError.unavailable }
    guard let resources = Bundle.main.resourceURL else { throw LocalAISetupError.unavailable }
    let root = resources.appendingPathComponent("RuntimeArtifacts", isDirectory: true)
    return try .init(catalogURL: root.appendingPathComponent("catalog.json"), expectedSHA256: expected, resourceRoot: root)
  }
  func artifact(_ id: String, checkPlatform: Bool = true) throws -> RuntimeArtifact {
    guard let item = artifacts.first(where: { $0.id == id }) else { throw LocalAISetupError.unavailable }
    if checkPlatform {
      #if arch(arm64)
      guard let minimum = Self.version(item.minimumMacOS), ProcessInfo.processInfo.isOperatingSystemAtLeast(minimum) else { throw LocalAISetupError.unsupportedPlatform }
      #else
      throw LocalAISetupError.unsupportedPlatform
      #endif
    }
    return item
  }
  private static func version(_ value: String) -> OperatingSystemVersion? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
          let major = Int(parts[0]), let minor = Int(parts[1]), major >= 11,
          let patch = parts.count == 3 ? Int(parts[2]) : 0 else { return nil }
    return .init(majorVersion: major, minorVersion: minor, patchVersion: patch)
  }
}
