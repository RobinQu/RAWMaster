import Darwin
import Foundation

/// Permanent production bytes, separate from preview caches and user export destinations.
/// Call from a worker: publication and recovery hash and fsync real files.
public final class EditingArchive: @unchecked Sendable {
  public let root: URL
  private let protectedRoots: [URL]
  private let lock = NSRecursiveLock()
  public init(root: URL, protectedRoots: [URL]) throws {
    guard root.isFileURL, root.path.hasPrefix("/") else { throw EditingError.unsafePath }
    let canonical = FileSafety.canonical(root)
    let resolvedSources = Set(protectedRoots.map(FileSafety.canonical))
    let paths = Set(resolvedSources.map(\.path))
    // Each source is resolved once for this opening. Resolve every newly used target independently.
    func validateDirectory(_ target: URL) throws {
      let destination = FileSafety.canonical(target).path
      if paths.contains(where: { $0 == "/" || destination == $0 || destination.hasPrefix($0 + "/") }) {
        throw LibraryError.invalid("目标目录不能位于源素材目录内：\(target.path)")
      }
    }
    try validateDirectory(canonical)
    self.root = canonical; self.protectedRoots = Array(resolvedSources)
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    for name in ["artifacts", "receipts", ".staging", ".received", "received-receipts", ".inputs"] {
      let directory = canonical.appendingPathComponent(name, isDirectory: true)
      try validateDirectory(directory)
      guard FileSafety.contains(canonical, directory) else { throw EditingError.unsafePath }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try synchronizeDirectory(canonical)
    try synchronizeDirectory(canonical.deletingLastPathComponent())
  }
  static func safeID(_ id: String) throws {
    guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"), !id.contains("\0") else { throw EditingError.unsafePath }
  }
  private func safeURL(_ relative: String) throws -> URL {
    _ = try FileSafety.safeRelative(relative)
    let url = root.appendingPathComponent(relative)
    guard FileSafety.contains(root, url), FileSafety.canonical(url) != root else { throw EditingError.unsafePath }
    try FileSafety.checkTarget(url, sources: protectedRoots)
    return url
  }
  public func artifactURL(_ artifact: RenderArtifact) throws -> URL {
    try artifact.validate()
    guard artifact.relativePath.hasPrefix("artifacts/") else { throw EditingError.unsafePath }
    return try safeURL(artifact.relativePath)
  }
  private func receiptURL(_ id: String) throws -> URL {
    try Self.safeID(id)
    return try safeURL("receipts/\(id).json")
  }
  private func stagingURL(_ id: String) throws -> URL {
    try Self.safeID(id)
    return try safeURL(".staging/\(id)/payload")
  }
  private func synchronizeDirectory(_ directory: URL) throws {
    let fd = open(directory.path, O_RDONLY)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
  }
  private func writeReceipt(_ receipt: ArchivePublicationReceipt) throws {
    let url = try receiptURL(receipt.id)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(receipt).write(to: url, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
    try handle.synchronize()
    try synchronizeDirectory(url.deletingLastPathComponent())
  }
  private func validateBytes(_ artifact: RenderArtifact, at url: URL) throws {
    guard try FileSafety.stat(url).size == artifact.byteCount, try FileSafety.hash(url) == artifact.sha256 else { throw EditingError.archiveMismatch }
  }
  private func validateShape(_ receipt: ArchivePublicationReceipt) throws -> RenderArtifact {
    try receipt.version.recipe.validate()
    try Self.safeID(receipt.id); try Self.safeID(receipt.version.id); try Self.safeID(receipt.version.workID)
    guard let artifact = receipt.version.artifact else { throw EditingError.invalidArtifact }
    try artifact.validate()
    let prefix = "artifacts/\(receipt.version.workID)/\(receipt.version.id)/\(receipt.id)."
    guard artifact.relativePath.hasPrefix(prefix), !artifact.relativePath.dropFirst(prefix.count).contains("/"),
      (receipt.jobID == nil && receipt.attemptID == nil && receipt.runID == nil) ||
        (receipt.jobID != nil && receipt.attemptID != nil && receipt.runID != nil) else { throw EditingError.archiveMismatch }
    _ = try artifactURL(artifact)
    return artifact
  }
  /// Persist a durable intent receipt before exclusively linking verified staging bytes to the final name.
  /// Recovery can finish an interrupted link without regenerating pixels. Nothing is overwritten.
  public func publish(fileURL: URL, version: EditingVersion, jobID: String? = nil,
                      attemptID: String? = nil, runID: String? = nil) throws -> ArchivePublicationReceipt {
    lock.lock(); defer { lock.unlock() }
    guard let metadata = version.artifact, version.kind != .original else { throw EditingError.invalidArtifact }
    try metadata.validate(); try Self.safeID(version.id); try Self.safeID(version.workID)
    var receipt = ArchivePublicationReceipt(version: version, jobID: jobID, attemptID: attemptID, runID: runID)
    let ext = fileURL.pathExtension.lowercased()
    guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw EditingError.invalidArtifact }
    receipt.version.artifact!.relativePath = "artifacts/\(version.workID)/\(version.id)/\(receipt.id).\(ext)"
    _ = try validateShape(receipt)
    let stage = try stagingURL(receipt.id)
    try FileManager.default.createDirectory(at: stage.deletingLastPathComponent(), withIntermediateDirectories: true)
    let copied = try FileSafety.verifiedCopy(source: fileURL, target: stage, expectedHash: metadata.sha256,
                                             protectedRoots: protectedRoots, cancel: {})
    guard copied.0 == stage else { throw EditingError.archiveMismatch }
    try validateBytes(metadata, at: stage)
    try synchronizeDirectory(stage.deletingLastPathComponent())
    try synchronizeDirectory(root.appendingPathComponent(".staging"))
    try writeReceipt(receipt)
    try finishPublication(receipt)
    return receipt
  }
  private func finishPublication(_ receipt: ArchivePublicationReceipt) throws {
    let artifact = try validateShape(receipt)
    let final = try artifactURL(artifact)
    if FileManager.default.fileExists(atPath: final.path) { try validateBytes(artifact, at: final); return }
    let stage = try stagingURL(receipt.id)
    try validateBytes(artifact, at: stage)
    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
    _ = try artifactURL(artifact) // Repeat canonical/symlink checks immediately before publication.
    // POSIX link is an atomic no-replace operation on the archive volume.
    if link(stage.path, final.path) != 0 {
      guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
      try validateBytes(artifact, at: final)
    }
    try synchronizeDirectory(final.deletingLastPathComponent())
    try synchronizeDirectory(final.deletingLastPathComponent().deletingLastPathComponent())
    try synchronizeDirectory(root.appendingPathComponent("artifacts"))
    // Retain recognized staging bytes until a future explicit retention policy; crash recovery never deletes unknown data.
  }
  public func validate(_ receipt: ArchivePublicationReceipt) throws {
    lock.lock(); defer { lock.unlock() }
    let artifact = try validateShape(receipt)
    let stored = try JSONDecoder().decode(ArchivePublicationReceipt.self, from: Data(contentsOf: receiptURL(receipt.id)))
    guard stored == receipt else { throw EditingError.archiveMismatch }
    try validateBytes(artifact, at: artifactURL(artifact))
  }
  public func recoverPublications(including eligible: (ArchivePublicationReceipt) throws -> Bool = { _ in true }) throws -> [ArchivePublicationReceipt] {
    lock.lock(); defer { lock.unlock() }
    let folder = try safeURL("receipts")
    var result: [ArchivePublicationReceipt] = []
    for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
      // Unrecognized files stay untouched. Recognized but damaged receipts surface an error instead of regeneration.
      guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
        let envelope = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
        let id = envelope["id"] as? String, envelope["version"] is [String:Any],
        url.lastPathComponent == id + ".json" else { continue }
      // Once recognized by its outer identity, a future/damaged recipe is an error, not junk.
      let receipt = try JSONDecoder().decode(ArchivePublicationReceipt.self, from:data)
      guard try eligible(receipt) else { continue }
      try finishPublication(receipt); try validate(receipt); result.append(receipt)
    }
    return result
  }
  func freezeProcessingInput(fileURL: URL, artifact: RenderArtifact, commandID: String, fingerprint: String) throws -> RenderArtifact {
    lock.lock(); defer { lock.unlock() }
    try artifact.validate()
    let ext = fileURL.pathExtension.lowercased()
    guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw EditingError.invalidArtifact }
    var frozen = artifact
    frozen.relativePath = ".inputs/\(try EditingFingerprint.of(commandID))/\(fingerprint).\(ext)"
    let target = try safeURL(frozen.relativePath)
    let copied = try FileSafety.verifiedCopy(source: fileURL, target: target, expectedHash: frozen.sha256,
      protectedRoots: protectedRoots, cancel: {})
    guard copied.0 == target else { throw EditingError.archiveMismatch }
    try validateBytes(frozen, at: target)
    var directory = target.deletingLastPathComponent()
    while FileSafety.contains(root, directory) && directory.path != root.path {
      try synchronizeDirectory(directory); directory.deleteLastPathComponent()
    }
    try synchronizeDirectory(root)
    return frozen
  }
  func processingInputURL(_ artifact: RenderArtifact) throws -> URL {
    try artifact.validate()
    guard artifact.relativePath.hasPrefix(".inputs/") else { throw EditingError.invalidArtifact }
    let url = try safeURL(artifact.relativePath); try validateBytes(artifact, at: url); return url
  }
  private func receivedReceiptURL(_ id: String) throws -> URL {
    try Self.safeID(id); return try safeURL("received-receipts/\(id).json")
  }
  private func validateReceivedShape(_ received: ReceivedProcessingOutput) throws {
    try Self.safeID(received.id); try Self.safeID(received.jobID); try Self.safeID(received.attemptID); try Self.safeID(received.runID)
    try received.artifact.validate()
    let prefix = ".received/\(received.jobID)/\(received.attemptID)/\(received.id)."
    guard received.artifact.relativePath.hasPrefix(prefix),
      !received.artifact.relativePath.dropFirst(prefix.count).contains("/") else { throw EditingError.archiveMismatch }
    _ = try safeURL(received.artifact.relativePath)
  }
  /// Archive returned bytes before attempting version publication. The receipt makes a DB callback loss recoverable.
  func receive(output: AIEditOutput, jobID: String, attemptID: String, runID: String) throws -> ReceivedProcessingOutput {
    lock.lock(); defer { lock.unlock() }
    try output.artifact.validate()
    var received = ReceivedProcessingOutput(jobID: jobID, attemptID: attemptID, runID: runID,
      artifact: output.artifact, configuration: output.configuration, remoteID: output.remoteID)
    let ext = output.fileURL.pathExtension.lowercased()
    guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw EditingError.invalidArtifact }
    received.artifact.relativePath = ".received/\(jobID)/\(attemptID)/\(received.id).\(ext)"
    try validateReceivedShape(received)
    let target = try safeURL(received.artifact.relativePath)
    let copied = try FileSafety.verifiedCopy(source: output.fileURL, target: target, expectedHash: output.artifact.sha256,
      protectedRoots: protectedRoots, cancel: {})
    guard copied.0 == target else { throw EditingError.archiveMismatch }
    try validateBytes(received.artifact, at: target)
    var parent = target.deletingLastPathComponent()
    while FileSafety.contains(root, parent) && parent.path != root.path {
      try synchronizeDirectory(parent); parent.deleteLastPathComponent()
    }
    let receiptURL = try receivedReceiptURL(received.id)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(received).write(to: receiptURL, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: receiptURL); try handle.synchronize(); try handle.close()
    try synchronizeDirectory(receiptURL.deletingLastPathComponent()); try synchronizeDirectory(root)
    return received
  }
  func resolveReceivedOutput(_ received: ReceivedProcessingOutput) throws -> AIEditOutput {
    lock.lock(); defer { lock.unlock() }
    try validateReceivedShape(received)
    let stored = try JSONDecoder().decode(ReceivedProcessingOutput.self, from: Data(contentsOf: receivedReceiptURL(received.id)))
    guard stored == received else { throw EditingError.archiveMismatch }
    let url = try safeURL(received.artifact.relativePath)
    try validateBytes(received.artifact, at: url)
    return AIEditOutput(fileURL: url, artifact: received.artifact, configuration: received.configuration, remoteID: received.remoteID)
  }
  func recoverReceivedOutputs(including eligible: (ReceivedProcessingOutput) throws -> Bool = { _ in true }) throws -> [ReceivedProcessingOutput] {
    lock.lock(); defer { lock.unlock() }
    let directory = try safeURL("received-receipts")
    var result: [ReceivedProcessingOutput] = []
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
      guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
        let received = try? JSONDecoder().decode(ReceivedProcessingOutput.self, from: data),
        url.lastPathComponent == received.id + ".json", try eligible(received) else { continue }
      _ = try resolveReceivedOutput(received); result.append(received)
    }
    return result
  }

}

public struct EditingLibraryBackupManifest: Codable, Equatable, Sendable {
  public var formatVersion: Int
  public var databaseSHA256: String
  public var files: [String: String]
  public var createdAt: Date
  public var recipeResources: [String: Int64]?
  public init(databaseSHA256: String, files: [String: String], createdAt: Date = Date(), recipeResources: [String: Int64] = [:],
              requiresWriterDetach: Bool = false) {
    self.formatVersion = recipeResources.isEmpty && !requiresWriterDetach ? 1 : 2
    self.databaseSHA256 = databaseSHA256; self.files = files; self.createdAt = createdAt
    self.recipeResources = recipeResources.isEmpty ? nil : recipeResources
  }
}
