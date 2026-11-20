import Foundation
import Security
import RAWMasterCore

public enum AIServiceError: LocalizedError, Equatable {
  case invalidConfiguration(String), credentialUnavailable, credentialDestinationMismatch, keychain(Int32)
  case submissionIntentMissing, inputChanged, unsupportedImage, invalidResponse, providerRejected(Int, String)
  case outcomeUnknown, runtimeUnavailable(String), busy
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message), .runtimeUnavailable(let message): return message
    case .credentialUnavailable: return "请在设置中保存此供应商凭证"
    case .credentialDestinationMismatch: return "凭证与上传目标不匹配，请为新目标重新保存凭证"
    case .keychain(let status): return "钥匙串操作失败（\(status)）"
    case .submissionIntentMissing: return "任务尚未保存提交意图"
    case .inputChanged: return "输入文件与已保存任务快照不一致"
    case .unsupportedImage: return "供应商输入必须是已渲染的 PNG 或 JPEG"
    case .invalidResponse: return "供应商未返回可归档的图像"
    case .providerRejected(let status, let code): return "供应商拒绝请求（HTTP \(status)，\(code)）"
    case .outcomeUnknown: return "请求可能已提交，远端结果与费用未知；不会自动重试"
    case .busy: return "本地编辑正在运行"
    }
  }
}
public enum ProviderDestination {
  public static func canonical(_ endpoint: URL) throws -> String {
    guard var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), c.scheme?.lowercased() == "https",
      let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else {
      throw AIServiceError.invalidConfiguration("云端接口必须是无用户名、查询参数和片段的 HTTPS 地址")
    }
    c.scheme = "https"; c.host = host; if c.port == 443 { c.port = nil }
    guard let url = c.url else { throw EditingError.invalidProfile }
    return url.absoluteString
  }
  static func validate(_ profile: AIProviderProfile) throws {
    guard profile.kind != .localComfy, !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      profile.model != "gpt-image-1", profile.acceptedForUse else { throw AIServiceError.invalidConfiguration("请明确配置可用的模型版本并接受此上传目标") }
    _ = try canonical(profile.endpoint)
    // Persist structured options, never raw authorization material in profiles/job snapshots.
    for key in profile.configuration.keys where ["key", "apikey", "api_key", "authorization", "token", "secret", "password"].contains(key.lowercased()) { throw EditingError.invalidProfile }
    guard !profile.capabilities.supportsMask, !profile.capabilities.supportsStrength else {
      throw AIServiceError.invalidConfiguration("此适配器尚未验收蒙版或强度参数")
    }
  }
}
public protocol ProviderCredentialStore: Sendable {
  func save(_ secret: String, for profile: AIProviderProfile) throws -> String
  func secret(reference: String, for profile: AIProviderProfile) throws -> String
  func delete(reference: String) throws
}
public final class KeychainCredentialStore: ProviderCredentialStore, @unchecked Sendable {
  private let service: String
  private struct Binding: Codable { let destination: String; let secret: String }
  public init(service: String = "RAWMaster.AI") { self.service = service }
  public func save(_ secret: String, for profile: AIProviderProfile) throws -> String {
    guard !secret.isEmpty, !secret.contains("\n"), !secret.contains("\r") else { throw AIServiceError.credentialUnavailable }
    let id = UUID().uuidString
    let data = try JSONEncoder().encode(Binding(destination: ProviderDestination.canonical(profile.endpoint), secret: secret))
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: id, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData as String: data]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { throw AIServiceError.keychain(status) }
    return id
  }
  public func secret(reference: String, for profile: AIProviderProfile) throws -> String {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: reference, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    guard status == errSecSuccess, let data = value as? Data else { throw AIServiceError.credentialUnavailable }
    let binding = try JSONDecoder().decode(Binding.self, from: data)
    guard binding.destination == (try ProviderDestination.canonical(profile.endpoint)) else { throw AIServiceError.credentialDestinationMismatch }
    return binding.secret
  }
  public func delete(reference: String) throws {
    let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: reference] as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw AIServiceError.keychain(status) }
  }
}
public actor ProviderProfileRepository {
  private let store: LibraryStore
  private let credentials: any ProviderCredentialStore
  public init(store: LibraryStore, credentials: any ProviderCredentialStore = KeychainCredentialStore()) { self.store = store; self.credentials = credentials }
  public func profiles() throws -> [AIProviderProfile] { try store.loadProviderProfiles() }
  public func save(_ profile: AIProviderProfile, secret: String? = nil) throws -> AIProviderProfile {
    var saved = profile
    if profile.kind != .localComfy {
      _ = try ProviderDestination.canonical(profile.endpoint)
      let old = try store.loadProviderProfiles().first { $0.id == profile.id }
      if let old, (try ProviderDestination.canonical(old.endpoint)) != (try ProviderDestination.canonical(profile.endpoint)) { saved.credentialReference = nil; if secret?.isEmpty != false { saved.acceptedForUse = false } }
      if let secret, !secret.isEmpty { saved.credentialReference = try credentials.save(secret, for: saved) }
      else if let reference = saved.credentialReference { _ = try credentials.secret(reference: reference, for: saved) }
    }
    try store.saveProviderProfile(saved)
    return saved
  }
}
public enum ProviderCatalog {
  /// Disabled examples verified against official provider references on 2026-10-30. Access is untested.
  public static var examples: [AIProviderProfile] { [
    AIProviderProfile(kind: .openAI, displayName: "GPT Image", model: "gpt-image-2.5-sunburst-2026-09-08", endpoint: URL(string: "https://api.openai.com/v1/images/edits")!, capabilities: .init(capabilityID: "openai-images-json-2026-10-30", supportsReferences: true), configuration: ["size": "1024x1024", "quality": "auto"]),
    AIProviderProfile(kind: .seedream, displayName: "Seedream / 中国方舟", model: "doubao-seedream-5-0-lite-260128", endpoint: URL(string: "https://ark.cn-beijing.volces.com/api/v3/images/generations")!, region: "cn-beijing", capabilities: .init(capabilityID: "ark-images-json-2026-10-30", supportsReferences: true), configuration: ["size": "2K"]),
    AIProviderProfile(kind: .gemini, displayName: "Nano Banana", model: "gemini-nano-banana-2.1", endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!, capabilities: .init(capabilityID: "gemini-interactions-2026-10-30", supportsReferences: true), configuration: ["store": "false"])
  ] }
}
