import Foundation

public enum TriagePhase: String, Codable, Sendable { case ingesting, screening, closed, legacyHistory }
public enum TriageDisposition: String, Codable, Sendable, CaseIterable { case pending, passed, excluded, review }
public struct SessionWorkflow: Codable, Sendable, Identifiable {
  public var id: String { sessionID }
  public var sessionID: String
  public var projectID: String
  public var isNewProject: Bool
  public var phase: TriagePhase
  public var revision: Int
  public var importActive: Bool
  public var closedAt: Date?
  public var manualAnalysisAcknowledged: Bool
  public init(sessionID: String, projectID: String, isNewProject: Bool, phase: TriagePhase = .ingesting, revision: Int = 0, importActive: Bool = false, closedAt: Date? = nil, manualAnalysisAcknowledged: Bool = false) {
    self.sessionID = sessionID; self.projectID = projectID; self.isNewProject = isNewProject
    self.phase = phase; self.revision = revision; self.importActive = importActive; self.closedAt = closedAt
    self.manualAnalysisAcknowledged = manualAnalysisAcknowledged
  }
}
public struct TriageRecord: Codable, Sendable, Identifiable {
  public var id: String { assetID }
  public var assetID: String
  public var disposition: TriageDisposition
  public var revision: Int
  public var logicalWriterID: String?
  public init(assetID: String, disposition: TriageDisposition = .pending, revision: Int = 0, logicalWriterID: String? = nil) {
    self.assetID = assetID; self.disposition = disposition; self.revision = revision; self.logicalWriterID = logicalWriterID
  }
}
public struct CapturePair: Codable, Sendable, Identifiable {
  public var id: String
  public var sessionID: String
  public var rawAssetID: String
  public var jpegAssetID: String
  public var isManual: Bool
  public var assetIDs: [String] { [rawAssetID, jpegAssetID] }
  public init(id: String = UUID().uuidString, sessionID: String, rawAssetID: String, jpegAssetID: String, isManual: Bool) {
    self.id = id; self.sessionID = sessionID; self.rawAssetID = rawAssetID; self.jpegAssetID = jpegAssetID; self.isManual = isManual
  }
}
public struct ProjectAdmission: Codable, Sendable, Identifiable {
  public var id: String { assetID }
  public var assetID: String
  public var projectID: String
  public var sequenceOnly: Bool
  public var admittedAt: Date
  public init(assetID: String, projectID: String, sequenceOnly: Bool = false, admittedAt: Date = Date()) {
    self.assetID = assetID; self.projectID = projectID; self.sequenceOnly = sequenceOnly; self.admittedAt = admittedAt
  }
}
public struct CompletionPreview: Codable, Sendable, Identifiable {
  public var id: String
  public var sessionID: String
  public var projectID: String
  public var fingerprint: String
  public var admittedAssetIDs: [String]
  public var excludedAssetIDs: [String]
  public var sequenceOnlyAssetIDs: [String]
  public var reviewAssetIDs: [String]
  public var issues: [String]
  public var unanalysedCount: Int
  public var captureCount: Int
  public var manualAnalysisAcknowledged: Bool
  public var canCommit: Bool { issues.isEmpty && manualAnalysisAcknowledged }
}
public struct TriageCommand: Codable, Sendable, Identifiable {
  public var id: String
  public var sessionID: String
  public var before: [TriageRecord]
  public var after: [TriageRecord]
  public var restored: Bool
}
public enum ExportFormats: String, Codable, Sendable, CaseIterable { case allOriginals, both, rawOnly, jpegOnly }
public struct ExportSelection: Sendable {
  public var assetIDs: [String]
  public var totalBytes: Int64
  public var missingFormats: [String]
}
public enum TriageQualityStatus: String, Codable, Sendable { case risk, clear, unknown, unsupported, error }
public struct TriageQualityEvidence: Codable, Sendable, Identifiable {
  public var id: String { assetID }
  public var assetID: String
  public var contentHash: String?
  public var fileSize: Int64
  public var source: String
  public var methodVersion: String
  public var status: TriageQualityStatus
  public var reasons: [String]
  public var metrics: [String: Double]
  public var createdAt: Date
  public init(assetID: String, contentHash: String?, fileSize: Int64, source: String, methodVersion: String, status: TriageQualityStatus, reasons: [String] = [], metrics: [String: Double] = [:], createdAt: Date = Date()) {
    self.assetID = assetID; self.contentHash = contentHash; self.fileSize = fileSize; self.source = source; self.methodVersion = methodVersion; self.status = status; self.reasons = reasons; self.metrics = metrics; self.createdAt = createdAt
  }
}
public enum CaptureFileFormat {
  public static func isRAW(_ filename: String) -> Bool { ["arw","dng","raw","cr2","cr3","nef","raf","orf","rw2","nrw","pef","srw","rwl"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) }
  public static func isJPEG(_ filename: String) -> Bool { ["jpg","jpeg"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) }
}
