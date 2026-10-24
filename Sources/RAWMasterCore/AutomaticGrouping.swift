import Foundation

/// Optional post-ingest work never changes the outcome of a completed import.
public typealias ImportPostIngestCallback = @Sendable (
  ImportSession, @escaping @Sendable () throws -> Void,
  @escaping @Sendable (TaskProgress) -> Void
) async -> Void

public struct AutomaticGroupingInput: Sendable {
  public let runID, sessionID, projectID, scopeFingerprint: String
  public let assets: [AssetRecord]
  public let assetRevisions: [Int]
  public let protectedAssetIDs: Set<String>
  public init(runID: String, sessionID: String, projectID: String, scopeFingerprint: String,
              assets: [AssetRecord], assetRevisions: [Int], protectedAssetIDs: Set<String>) {
    self.runID = runID; self.sessionID = sessionID; self.projectID = projectID
    self.scopeFingerprint = scopeFingerprint; self.assets = assets
    self.assetRevisions = assetRevisions; self.protectedAssetIDs = protectedAssetIDs
  }
}

public struct AutomaticGroupingFileStamp: Codable, Sendable, Equatable {
  public let size: Int64
  public let modified: Date
  public let inode, device: UInt64
  public init(size: Int64, modified: Date, inode: UInt64, device: UInt64) {
    self.size = size; self.modified = modified; self.inode = inode; self.device = device
  }
  public static func read(at url: URL) throws -> Self {
    let stamp = try FileSafety.stat(url)
    return Self(size: stamp.size, modified: stamp.modified, inode: stamp.inode, device: stamp.device)
  }
}
public struct AutomaticGroupingSourceProof: Codable, Sendable {
  public let assetID: String
  public let verifiedSHA256: String?
  public let finalStamp: AutomaticGroupingFileStamp?
  public let issue: String?
  public init(assetID: String, verifiedSHA256: String?, finalStamp: AutomaticGroupingFileStamp?, issue: String?) {
    self.assetID = assetID; self.verifiedSHA256 = verifiedSHA256
    self.finalStamp = finalStamp; self.issue = issue
  }
}
public struct AutomaticGroupingProvenance: Codable, Sendable {
  public let providerVersion, analysisSHA256: String
  public let associationHypothesisAssumed: Bool
  public let reportPath: String?
  public let warnings: [String]
  public init(providerVersion: String, analysisSHA256: String, associationHypothesisAssumed: Bool,
              reportPath: String?, warnings: [String]) {
    self.providerVersion = providerVersion; self.analysisSHA256 = analysisSHA256
    self.associationHypothesisAssumed = associationHypothesisAssumed
    self.reportPath = reportPath; self.warnings = warnings
  }
}
public struct AutomaticGroupingAnalysis: Sendable {
  public let runID, scopeFingerprint: String
  public let manifest: SequenceInputManifest
  public let result: SequenceAnalysisResult
  public let observations: [SequenceAssetInput]
  public let featuresAvailable: [Bool]
  public let sourceProofs: [AutomaticGroupingSourceProof]
  public let provenance: AutomaticGroupingProvenance
  public init(runID: String, scopeFingerprint: String, manifest: SequenceInputManifest,
              result: SequenceAnalysisResult, observations: [SequenceAssetInput],
              featuresAvailable: [Bool], sourceProofs: [AutomaticGroupingSourceProof],
              provenance: AutomaticGroupingProvenance) {
    self.runID = runID; self.scopeFingerprint = scopeFingerprint; self.manifest = manifest
    self.result = result; self.observations = observations; self.featuresAvailable = featuresAvailable
    self.sourceProofs = sourceProofs; self.provenance = provenance
  }
}
public typealias AutomaticGroupingAnalyzer = @Sendable (
  AutomaticGroupingInput, @escaping @Sendable () throws -> Void,
  @escaping @Sendable (TaskProgress) -> Void
) async throws -> AutomaticGroupingAnalysis

public enum AutomaticGroupingRunState: String, Codable, Sendable {
  case running, applied, completedNoGroups, cancelled, failed
  var succeeded: Bool { self == .applied || self == .completedNoGroups }
}
public struct AutomaticGroupingRunRecord: Codable, Sendable {
  public let runID, sessionID, scopeFingerprint: String
  public var state: AutomaticGroupingRunState
  public let startedAt: Date
  public var finishedAt: Date?
  public var commandID: String?
  public var groupIDs: [String]
  public var skippedProtectedRanges: Int
  public var message: String?
  public var provenance: AutomaticGroupingProvenance?
  var preparedBatchFingerprint: String?
}

/// Core-prepared groups, retained in the ordinary durable group history.
public struct AutomaticGroupingBatch: Codable, Sendable {
  public let runID, sessionID, scopeFingerprint: String
  public let groups: [AutomaticGroupingBatchGroup]
  public let proofs: [AutomaticGroupingSourceProof]
  public let provenance: AutomaticGroupingProvenance
  public let skippedProtectedRanges: Int
}
public struct AutomaticGroupingBatchGroup: Codable, Sendable {
  public let firstOrdinal, lastOrdinal: Int
  public let assetIDs: [String]
  public let kind: SequenceKind
}
