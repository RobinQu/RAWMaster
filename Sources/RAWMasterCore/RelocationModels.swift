import CryptoKit
import Foundation

public enum RelocationRole: String, Codable, Sendable, CaseIterable { case source, managed }
public enum RelocationItemStatus: String, Codable, Sendable {
  case matched, ambiguous, missing, differentContent, noHash, unreadable, stale, committed
}
public struct RelocationCandidate: Codable, Sendable, Identifiable {
  public var id: String { path }
  public var path: String
  public var relativePath: String
  public var contentHash: String
  public var fileFingerprint: String
  public init(path: String, relativePath: String, contentHash: String, fileFingerprint: String) {
    self.path = path
    self.relativePath = relativePath
    self.contentHash = contentHash
    self.fileFingerprint = fileFingerprint
  }
}
public struct RelocationItem: Codable, Sendable, Identifiable {
  public var id: String { assetID }
  public var assetID: String
  public var filename: String
  public var status: RelocationItemStatus
  public var candidates: [RelocationCandidate]
  public var selectedPath: String?
  public var message: String
  public var assetFingerprint: String
  public var oldPath: String
  public var oldPathWasAvailable: Bool
  public init(
    assetID: String, filename: String, status: RelocationItemStatus = .missing,
    candidates: [RelocationCandidate] = [], selectedPath: String? = nil, message: String = "",
    assetFingerprint: String, oldPath: String, oldPathWasAvailable: Bool
  ) {
    self.assetID = assetID
    self.filename = filename
    self.status = status
    self.candidates = candidates
    self.selectedPath = selectedPath
    self.message = message
    self.assetFingerprint = assetFingerprint
    self.oldPath = oldPath
    self.oldPathWasAvailable = oldPathWasAvailable
  }
}
public struct RelocationSession: Codable, Sendable, Identifiable {
  public var id: String
  public var importSessionID: String
  public var rootPath: String
  public var scanRootPath: String?
  public var role: RelocationRole
  public var status: String
  public var items: [RelocationItem]
  public var scannedFiles: Int
  public var scanComplete: Bool
  public var createdAt: Date
  public var message: String
  public var matchedCount: Int {
    items.filter { $0.selectedPath != nil && ($0.status == .matched || $0.status == .ambiguous) }
      .count
  }
  public var committedCount: Int { items.filter { $0.status == .committed }.count }
  public init(
    id: String = UUID().uuidString, importSessionID: String, rootPath: String, role: RelocationRole,
    status: String = "scanning", items: [RelocationItem] = [], scannedFiles: Int = 0,
    scanComplete: Bool = false, createdAt: Date = Date(), message: String = "",
    scanRootPath: String? = nil
  ) {
    self.id = id
    self.importSessionID = importSessionID
    self.rootPath = rootPath
    self.scanRootPath = scanRootPath
    self.role = role
    self.status = status
    self.items = items
    self.scannedFiles = scannedFiles
    self.scanComplete = scanComplete
    self.createdAt = createdAt
    self.message = message
  }
}

enum LocationIdentity {
  static func path(_ asset: AssetRecord, role: RelocationRole) -> String {
    role == .source
      ? asset.resolvedSourceURL.path : (asset.effectiveManagedPath ?? asset.currentPath)
  }
  static func fingerprint(_ asset: AssetRecord, role: RelocationRole) -> String {
    // Human ratings, import progress, groups and availability are deliberately excluded.
    let fields = [
      asset.id, asset.sessionID, asset.relativePath, asset.contentHash ?? "",
      String(asset.fileSize), role.rawValue, path(asset, role: role),
      role == .source && asset.effectiveManagedPath == nil ? asset.currentPath : "",
    ]
    return digest((try? JSONEncoder().encode(fields)) ?? Data())
  }
  static func stamp(_ stamp: FileStamp) -> String {
    digest(
      Data(
        "\(stamp.device)|\(stamp.inode)|\(stamp.size)|\(stamp.modified.timeIntervalSince1970)".utf8)
    )
  }
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct VerifiedRelocation {
  var assetID: String
  var expectedFingerprint: String
  var candidate: RelocationCandidate
  var oldPathMustRemainUnavailable: String?
}
