import Foundation

public enum GroupOrigin: String, Codable, Sendable { case manual, acceptedSuggestion, automaticPendingReview }

public enum Decision: String, Codable, Sendable, CaseIterable { case undecided, keep, reject }
public enum ImportMode: String, Codable, Sendable, CaseIterable { case reference, copy }
public enum ImportState: String, Codable, Sendable {
  case discovered, copying, verifying, ready, failed
}
public enum AssetAvailability: String, Codable, Sendable { case available, missing, changed }
public struct ProjectRecord: Codable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var createdAt: Date
  public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
  }
}
public struct AssetRecord: Codable, Sendable, Identifiable {
  public var id: String
  public var sessionID: String
  public var projectID: String
  public var projectName: String
  public var sourcePath: String
  public var currentPath: String
  public var effectiveSourcePath: String?
  public var effectiveManagedPath: String?
  public var relativePath: String
  public var filename: String
  public var fileSize: Int64
  public var capturedAt: Date?
  public var camera: String?
  public var width: Int?
  public var height: Int?
  public var contentHash: String?
  public var decision: Decision
  public var rating: Int
  public var groupID: String?
  public var sequenceIndex: Int?
  public var isSequenceMember: Bool
  public var availability: AssetAvailability
  public var importState: ImportState
  public var error: String?
  public var resolvedURL: URL { URL(fileURLWithPath: effectiveManagedPath ?? currentPath) }
  public var resolvedSourceURL: URL { URL(fileURLWithPath: effectiveSourcePath ?? sourcePath) }
  public var url: URL { resolvedURL }
  public init(
    id: String = UUID().uuidString, sessionID: String, projectID: String, projectName: String = "",
    sourcePath: String, currentPath: String? = nil, relativePath: String? = nil,
    filename: String? = nil, fileSize: Int64 = 0, capturedAt: Date? = nil, camera: String? = nil,
    width: Int? = nil, height: Int? = nil, contentHash: String? = nil,
    decision: Decision = .undecided, rating: Int = 0, groupID: String? = nil,
    sequenceIndex: Int? = nil, isSequenceMember: Bool = false,
    availability: AssetAvailability = .available, importState: ImportState = .discovered,
    error: String? = nil, effectiveSourcePath: String? = nil, effectiveManagedPath: String? = nil
  ) {
    self.id = id
    self.sessionID = sessionID
    self.projectID = projectID
    self.projectName = projectName
    self.sourcePath = sourcePath
    self.currentPath = currentPath ?? sourcePath
    self.effectiveSourcePath = effectiveSourcePath
    self.effectiveManagedPath = effectiveManagedPath
    self.relativePath = relativePath ?? URL(fileURLWithPath: sourcePath).lastPathComponent
    self.filename = filename ?? URL(fileURLWithPath: sourcePath).lastPathComponent
    self.fileSize = fileSize
    self.capturedAt = capturedAt
    self.camera = camera
    self.width = width
    self.height = height
    self.contentHash = contentHash
    self.decision = decision
    self.rating = rating
    self.groupID = groupID
    self.sequenceIndex = sequenceIndex
    self.isSequenceMember = isSequenceMember
    self.availability = availability
    self.importState = importState
    self.error = error
  }
}
public struct CaptureGroup: Codable, Sendable, Identifiable {
  public var id: String
  public var projectID: String
  public var name: String
  public var kind: String
  public var assetIDs: [String]
  public var includedAssetIDs: [String]
  public var origin: GroupOrigin
  public var locked: Bool
  public var groupRevision: Int
  public init(
    id: String = UUID().uuidString, projectID: String, name: String, kind: String = "连拍",
    assetIDs: [String] = [], includedAssetIDs: [String] = [], origin: GroupOrigin = .manual,
    locked: Bool = true, groupRevision: Int = 0
  ) {
    self.id = id
    self.projectID = projectID
    self.name = name
    self.kind = kind
    self.assetIDs = assetIDs
    self.includedAssetIDs = includedAssetIDs
    self.origin = origin
    self.locked = locked
    self.groupRevision = groupRevision
  }
  enum CodingKeys: String, CodingKey {
    case id, projectID, name, kind, assetIDs, includedAssetIDs, origin, locked, groupRevision
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    projectID = try c.decode(String.self, forKey: .projectID)
    name = try c.decode(String.self, forKey: .name)
    kind = try c.decode(String.self, forKey: .kind)
    assetIDs = try c.decodeIfPresent([String].self, forKey: .assetIDs) ?? []
    includedAssetIDs = try c.decodeIfPresent([String].self, forKey: .includedAssetIDs) ?? []
    origin = try c.decodeIfPresent(GroupOrigin.self, forKey: .origin) ?? .manual
    locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? true
    groupRevision = try c.decodeIfPresent(Int.self, forKey: .groupRevision) ?? 0
  }

}
public struct ImportSession: Codable, Sendable, Identifiable {
  public var id: String
  public var projectID: String
  public var projectName: String
  public var sourcePath: String
  public var destinationPath: String?
  public var mode: ImportMode
  public var status: String
  public var discovered: Int
  public var completed: Int
  public var failed: Int
  public var createdAt: Date
  public var scanCompleted: Bool?
  public var effectiveSourceRoot: String?
  public var effectiveManagedRoot: String?
  public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
  public var effectiveSourceURL: URL { URL(fileURLWithPath: effectiveSourceRoot ?? sourcePath) }
  public var managedContainerURL: URL? {
    (effectiveManagedRoot ?? destinationPath).map { URL(fileURLWithPath: $0) }
  }
  public init(
    id: String = UUID().uuidString, projectID: String, projectName: String, sourcePath: String,
    destinationPath: String? = nil, mode: ImportMode, status: String = "pending",
    discovered: Int = 0, completed: Int = 0, failed: Int = 0, createdAt: Date = Date(),
    scanCompleted: Bool? = false, effectiveSourceRoot: String? = nil,
    effectiveManagedRoot: String? = nil
  ) {
    self.id = id
    self.projectID = projectID
    self.projectName = projectName
    self.sourcePath = sourcePath
    self.destinationPath = destinationPath
    self.mode = mode
    self.status = status
    self.discovered = discovered
    self.completed = completed
    self.failed = failed
    self.createdAt = createdAt
    self.scanCompleted = scanCompleted
    self.effectiveSourceRoot = effectiveSourceRoot
    self.effectiveManagedRoot = effectiveManagedRoot
  }
}
public struct TaskProgress: Codable, Sendable {
  public var title: String
  public var completed: Int
  public var total: Int
  public var message: String
  public var isRunning: Bool
  public init(
    title: String, completed: Int = 0, total: Int = 0, message: String = "", isRunning: Bool = true
  ) {
    self.title = title
    self.completed = completed
    self.total = total
    self.message = message
    self.isRunning = isRunning
  }
}
public struct SelectionChange: Codable, Sendable {
  public var assetID: String
  public var oldDecision: Decision
  public var newDecision: Decision
  public var oldRating: Int
  public var newRating: Int
  public init(
    assetID: String, oldDecision: Decision, newDecision: Decision, oldRating: Int, newRating: Int
  ) {
    self.assetID = assetID
    self.oldDecision = oldDecision
    self.newDecision = newDecision
    self.oldRating = oldRating
    self.newRating = newRating
  }
}
public struct ExportReport: Codable, Sendable {
  public var destinationPath: String
  public var copied: Int
  public var failed: Int
  public var manifestPath: String
  public var errors: [String]
  public init(
    destinationPath: String, copied: Int = 0, failed: Int = 0, manifestPath: String = "",
    errors: [String] = []
  ) {
    self.destinationPath = destinationPath
    self.copied = copied
    self.failed = failed
    self.manifestPath = manifestPath
    self.errors = errors
  }
}
public enum LibraryError: LocalizedError {
  case database(String)
  case invalid(String)
  case busy, cancelled
  case sourceChanged(String)
  public var errorDescription: String? {
    switch self {
    case .database(let s): return "资料库错误：\(s)"
    case .invalid(let s): return s
    case .busy: return "已有任务正在进行"
    case .cancelled: return "任务已取消"
    case .sourceChanged(let s): return "读取期间源文件发生变化：\(s)"
    }
  }
}
