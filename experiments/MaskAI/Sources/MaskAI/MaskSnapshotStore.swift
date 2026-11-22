import Foundation
import CryptoKit

public final class MaskSnapshotStore: @unchecked Sendable {
    public static let maximumSnapshotBytes = 256 * 1024 * 1024
    private let root: URL
    private let snapshots: URL
    private let indexes: URL
    private let lock = NSLock()

    public init(root: URL) throws {
        self.root = root
        snapshots = root.appending(path: "Snapshots")
        indexes = root.appending(path: "Indexes")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
    }

    public func save(mask: MaskImage, descriptor: SemanticMaskDescriptor) throws -> MaskSnapshot {
        lock.lock(); defer { lock.unlock() }
        let key = try descriptor.cacheKey
        guard mask.width == descriptor.source.analysisWidth, mask.height == descriptor.source.analysisHeight,
              mask.values.count <= Self.maximumSnapshotBytes else {
            throw MaskAIError.snapshotFailure("Snapshot dimensions do not match the descriptor's analysis input.")
        }
        let contentSHA = Self.sha256(Data(mask.values))
        let snapshotID = Self.sha256(Data((key + ":" + contentSHA).utf8))
        let reference = MaskSnapshotReference(id: snapshotID, descriptorKey: key, contentSHA256: contentSHA,
                                              width: mask.width, height: mask.height, byteCount: mask.values.count)
        let snapshot = MaskSnapshot(reference: reference, descriptor: descriptor, createdAt: Date())
        let dataURL = snapshots.appending(path: snapshotID + ".gray8")
        let metadataURL = snapshots.appending(path: snapshotID + ".json")
        try Self.writeAtomic(Data(mask.values), to: dataURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try Self.writeAtomic(try encoder.encode(snapshot), to: metadataURL)
        try Self.writeAtomic(try encoder.encode(snapshot), to: indexes.appending(path: key + ".json"))
        return snapshot
    }

    public func latest(for descriptor: SemanticMaskDescriptor) throws -> MaskSnapshot? {
        lock.lock(); defer { lock.unlock() }
        let key = try descriptor.cacheKey
        let url = indexes.appending(path: key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(MaskSnapshot.self, from: Data(contentsOf: url))
        guard try snapshot.descriptor.cacheKey == key else { throw MaskAIError.snapshotFailure("Snapshot index points to a different descriptor.") }
        _ = try loadLocked(snapshot.reference)
        return snapshot
    }

    public func load(_ reference: MaskSnapshotReference) throws -> MaskImage {
        lock.lock(); defer { lock.unlock() }
        return try loadLocked(reference)
    }

    public func validate(_ snapshot: MaskSnapshot) throws {
        guard snapshot.reference.byteCount == snapshot.reference.width * snapshot.reference.height,
              snapshot.reference.byteCount <= Self.maximumSnapshotBytes else {
            throw MaskAIError.snapshotFailure("Invalid snapshot dimensions or byte count.")
        }
        _ = try load(snapshot.reference)
    }

    /// Rolls back a cancelled commit without deleting a newer snapshot for the same descriptor.
    public func discard(_ snapshot: MaskSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        let key = try snapshot.descriptor.cacheKey
        let indexURL = indexes.appending(path: key + ".json")
        if let data = try? Data(contentsOf: indexURL),
           let current = try? JSONDecoder().decode(MaskSnapshot.self, from: data),
           current.reference.id == snapshot.reference.id {
            try FileManager.default.removeItem(at: indexURL)
        }
        let dataURL = snapshots.appending(path: snapshot.reference.id + ".gray8")
        let metadataURL = snapshots.appending(path: snapshot.reference.id + ".json")
        if FileManager.default.fileExists(atPath: dataURL.path) { try FileManager.default.removeItem(at: dataURL) }
        if FileManager.default.fileExists(atPath: metadataURL.path) { try FileManager.default.removeItem(at: metadataURL) }
    }

    private func loadLocked(_ reference: MaskSnapshotReference) throws -> MaskImage {
        guard reference.byteCount == reference.width * reference.height,
              reference.byteCount <= Self.maximumSnapshotBytes else {
            throw MaskAIError.snapshotFailure("Invalid snapshot dimensions or byte count.")
        }
        let url = snapshots.appending(path: reference.id + ".gray8")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MaskAIError.snapshotFailure("Snapshot \(reference.id) is missing.")
        }
        let data = try Data(contentsOf: url)
        guard data.count == reference.byteCount else {
            throw MaskAIError.snapshotFailure("Snapshot byte count mismatch for \(reference.id).")
        }
        guard Self.sha256(data) == reference.contentSHA256 else {
            throw MaskAIError.snapshotFailure("Snapshot SHA-256 mismatch for \(reference.id).")
        }
        return try MaskImage(width: reference.width, height: reference.height, values: Array(data))
    }

    private static func writeAtomic(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
