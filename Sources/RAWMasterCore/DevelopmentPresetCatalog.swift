import CryptoKit
import Darwin
import Foundation
import ImageIO

public enum DevelopmentPresetKind: String, Codable, Sendable {
    case user, imported, profile, look, sidecar
}

public struct DevelopmentPresetRecord: Codable, Equatable, Identifiable, Sendable {
    public var id, name, group: String
    public var kind: DevelopmentPresetKind
    public var patch: DevelopmentPresetPatch
    public var sourceSHA256: String?
    public var blockingReasons: [String]
    public var version: Int
    public var metadata: [String: String]

    public init(id: String, name: String, group: String, kind: DevelopmentPresetKind, patch: DevelopmentPresetPatch,
                sourceSHA256: String? = nil, blockingReasons: [String] = [], version: Int = 1, metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
        self.patch = patch
        self.sourceSHA256 = sourceSHA256
        self.blockingReasons = blockingReasons
        self.version = version
        self.metadata = metadata
    }

    public var isBrowsable: Bool { kind != .look && kind != .sidecar }

    public func validate() throws {
        guard (1...256).contains(id.utf8.count), !id.hasPrefix("classic."),
              [name, group].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 2048 }),
              version > 0, version < Int.max, metadata.count <= 256, blockingReasons.count <= 1024,
              metadata.allSatisfy({ $0.key.utf8.count <= 512 && $0.value.utf8.count <= 262_144 }),
              blockingReasons.allSatisfy({ $0.utf8.count <= 8192 }),
              sourceSHA256.map(EditingFingerprint.isSHA256) != false,
              kind != .user || (!patch.isEmpty && sourceSHA256 == nil) else { throw DevelopmentPresetError.invalid }
        try patch.validate()
    }

    public func supportsAmount(from base: DevelopmentRecipe) -> Bool {
        (kind == .user || metadata["supportsAmount"] == "true") && patch.supportsAmount(from: base)
    }

    public func reason(for sourceID: String) -> String? {
        if !blockingReasons.isEmpty { return blockingReasons.joined(separator: " · ") }
        if let source = patch.boundSourceID, source != sourceID { return DevelopmentPresetError.differentSource.localizedDescription }
        return !isBrowsable || patch.isEmpty ? DevelopmentPresetError.unavailable.localizedDescription : nil
    }
}

/// A catalog mutation publishes the new index only after all content-addressed files have been verified.
/// flock serializes reads and read-modify-write operations across windows, catalog instances and processes.
public final class DevelopmentPresetCatalog: Sendable {
    public struct ImportHistory: Sendable {
        public let committed: [String]
        public let unsequenced: [String]
        public let summaries: [String: String]
    }
    public static let shared = DevelopmentPresetCatalog(root: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("RAWMaster/Presets", isDirectory: true))
    public static let didChange = Notification.Name("RAWMaster.DevelopmentPresetCatalog.didChange")
    private let root: URL
    private struct Index: Codable {
        var schema = 1
        var records: [DevelopmentPresetRecord] = []
        var favorites: Set<String> = []
        var batches: [String: Set<String>]?
        var batchCommitOrder: [String]?
        var retiredBatches: Set<String>?
        var independentlyOwned: Set<String>?
    }
    private struct NativeFile: Codable {
        let schema: Int
        let preset: DevelopmentPresetRecord
    }
    public init(root: URL) { self.root = root.standardizedFileURL }

    public func records() throws -> [DevelopmentPresetRecord] { try read { $0.records } }
    public func favoriteIDs() throws -> Set<String> { try read { $0.favorites } }
    public func snapshot() throws -> (records: [DevelopmentPresetRecord], favorites: Set<String>) {
        try read { ($0.records, $0.favorites) }
    }

    public func toggleFavorite(_ id: String) throws {
        try change { index in
            guard index.records.contains(where: { $0.id == id && $0.isBrowsable }) else { throw DevelopmentPresetError.unavailable }
            if index.favorites.contains(id) { index.favorites.remove(id) } else { index.favorites.insert(id) }
        }
    }

    @discardableResult
    public func create(name: String, group: String, patch: DevelopmentPresetPatch, copiedFrom: DevelopmentPresetRecord? = nil) throws -> DevelopmentPresetRecord {
        var record = DevelopmentPresetRecord(id: UUID().uuidString, name: name, group: group, kind: .user, patch: patch)
        if let original = copiedFrom {
            guard original.kind == .user else { throw DevelopmentPresetError.unavailable }
            record.metadata = ["parentID": original.id, "parentVersion": String(original.version)]
        }
        try record.validate()
        return try change { index in
            let stored = try storedRecord(record)
            index.records.append(stored)
            return (stored, true)
        }
    }

    @discardableResult
    public func revise(_ original: DevelopmentPresetRecord, name: String, group: String, patch: DevelopmentPresetPatch) throws -> DevelopmentPresetRecord {
        try change { index in
            guard let offset = index.records.firstIndex(where: { $0.id == original.id }), index.records[offset] == original,
                  original.kind == .user else { throw DevelopmentPresetError.conflict }
            var updated = original
            updated.name = name
            updated.group = group
            updated.patch = patch
            updated = try storedRecord(updated)
            if updated == original { return (original, false) }
            updated.version += 1
            try updated.validate()
            try archive(original)
            index.records[offset] = updated
            return (updated, true)
        }
    }

    public func delete(_ original: DevelopmentPresetRecord) throws {
        try change { index in
            guard original.kind == .user, let offset = index.records.firstIndex(of: original) else { throw DevelopmentPresetError.conflict }
            try archive(original)
            index.records.remove(at: offset)
            index.favorites.remove(original.id)
        }
    }

    /// Returns only IDs introduced by this call. Existing SHA-identical sources may carry a prior batch's metadata.
    public func importBatch(_ records: [DevelopmentPresetRecord], originals: [String: Data], batchID: String? = nil,
                            requireUnambiguousUUIDs: Bool = false) throws -> [String] {
        guard records.count <= 8192, originals.count <= 8192 else { throw DevelopmentPresetError.invalid }
        if let batchID {
            guard (1...256).contains(batchID.utf8.count), records.allSatisfy({ $0.kind != .user && $0.sourceSHA256 != nil }) else {
                throw DevelopmentPresetError.invalid
            }
        }
        return try change { index in
            if let batchID, index.retiredBatches?.contains(batchID) == true { throw DevelopmentPresetError.conflict }
            let previousIDs = Set(index.records.map(\.id))
            var uuidSources: [String: Set<String>] = [:]
            for known in index.records {
                if let uuid = known.metadata["uuid"]?.lowercased(), !uuid.isEmpty, let sha = known.sourceSHA256 {
                    uuidSources[uuid, default: []].insert(sha)
                }
            }
            var known = Dictionary(uniqueKeysWithValues: index.records.map { ($0.id, $0) })
            var inserted: [DevelopmentPresetRecord] = []
            var provenanceChanges = Set<String>()
            let referenced = Set(records.compactMap(\.sourceSHA256))
            guard Set(originals.keys).isSubset(of: referenced) else { throw DevelopmentPresetError.invalid }
            for (hash, bytes) in originals {
                guard EditingFingerprint.isSHA256(hash), Self.hash(bytes) == hash else { throw DevelopmentPresetError.missingOriginal }
            }
            for incoming in records {
                let record = try storedRecord(incoming)
                try record.validate()
                if requireUnambiguousUUIDs, let uuid = record.metadata["uuid"]?.lowercased(), !uuid.isEmpty,
                   let sha = record.sourceSHA256, !(uuidSources[uuid] ?? []).subtracting([sha]).isEmpty {
                    throw DevelopmentPresetError.conflict
                }
                if let previous = known[record.id] {
                    guard previous == record || (previous.sourceSHA256 != nil && previous.sourceSHA256 == record.sourceSHA256 && previous.kind == record.kind) else {
                        throw DevelopmentPresetError.conflict
                    }
                    if let incoming = record.metadata["sourceLocationsV1"], previous.sourceSHA256 != nil {
                        let old = try Self.locations(previous.metadata["sourceLocationsV1"])
                        let combined = old.union(try Self.locations(incoming))
                        if combined != old {
                            guard combined.count <= 2048 else { throw DevelopmentPresetError.invalid }
                            var updated = previous
                            let encoded = try Self.encoder().encode(combined.sorted())
                            updated.metadata["sourceLocationsV1"] = String(decoding: encoded, as: UTF8.self)
                            try updated.validate()
                            known[record.id] = updated
                            provenanceChanges.insert(record.id)
                        }
                    }
                    continue
                }
                if let first = record.metadata["sourceLocationsV1"] { _ = try Self.locations(first) }
                if let uuid = record.metadata["uuid"]?.lowercased(), !uuid.isEmpty, let sha = record.sourceSHA256 {
                    let competing = (uuidSources[uuid] ?? []).subtracting([sha])
                    let allowed = Set((record.metadata["allowedUUIDHashes"] ?? "").split(separator: ",").map(String.init))
                    guard competing.isSubset(of: allowed) else { throw DevelopmentPresetError.conflict }
                    uuidSources[uuid, default: []].insert(sha)
                }
                known[record.id] = record
                inserted.append(record)
            }
            for hash in referenced {
                if let data = originals[hash] { try put(data, at: originalURL(hash), hash: hash) }
                else { _ = try originalData(sha256: hash) }
            }
            if !provenanceChanges.isEmpty {
                for i in index.records.indices where provenanceChanges.contains(index.records[i].id) {
                    if let updated = known[index.records[i].id] { index.records[i] = updated }
                }
            }
            index.records.append(contentsOf: inserted.map { known[$0.id] ?? $0 })
            let requested = Set(records.map(\.id))
            var anchors = index.independentlyOwned ?? []
            let owned = Set((index.batches ?? [:]).values.flatMap { $0 })
            if let batchID, !requested.isEmpty {
                var batches = index.batches ?? [:]
                if let receipt = batches[batchID], receipt != requested { throw DevelopmentPresetError.conflict }
                let changed = batches[batchID] == nil
                if changed { index.batchCommitOrder = (index.batchCommitOrder ?? []) + [batchID] }
                anchors.formUnion(previousIDs.intersection(requested).subtracting(owned))
                batches[batchID] = requested
                index.batches = batches
                index.independentlyOwned = anchors
                return (inserted.map(\.id), changed || !inserted.isEmpty || !provenanceChanges.isEmpty)
            }
            let priorAnchors = anchors
            anchors.formUnion(requested.intersection(owned))
            if !anchors.isEmpty { index.independentlyOwned = anchors }
            return (inserted.map(\.id), !inserted.isEmpty || priorAnchors != anchors || !provenanceChanges.isEmpty)
        }
    }

    public func originalData(sha256: String) throws -> Data {
        guard EditingFingerprint.isSHA256(sha256) else { throw DevelopmentPresetError.invalid }
        let url = originalURL(sha256)
        guard let data = try? Self.data(at: url), Self.hash(data) == sha256 else { throw DevelopmentPresetError.missingOriginal }
        return data
    }

    public func importBatchIDs() throws -> [String] {
        let history = try importHistory()
        return history.unsequenced + history.committed
    }

    func wasImportBatchRemoved(_ batchID: String) throws -> Bool {
        try read { $0.retiredBatches?.contains(batchID) == true }
    }

    public func importHistory() throws -> ImportHistory {
        try read { index in
            let batches = index.batches ?? [:]
            let order = index.batchCommitOrder ?? []
            let legacy = Set(batches.keys).subtracting(order).sorted()
            let names = Dictionary(uniqueKeysWithValues: index.records.map { ($0.id, $0.name) })
            let summaries = batches.mapValues { ids in
                let examples = ids.compactMap { names[$0] }.sorted().prefix(2)
                return "\(ids.count) 项 · " + examples.joined(separator: "、")
            }
            return ImportHistory(committed: order, unsequenced: legacy, summaries: summaries)
        }
    }

    public func removeImportBatch(_ batchID: String) throws {
        try change { index in
            guard var batches = index.batches, let ids = batches.removeValue(forKey: batchID) else { return ((), false) }
            let stillOwned = Set(batches.values.flatMap { $0 }).union(index.independentlyOwned ?? [])
            let removed = ids.subtracting(stillOwned)
            index.records.removeAll { removed.contains($0.id) }
            index.favorites.subtract(removed)
            index.batches = batches
            index.batchCommitOrder?.removeAll { $0 == batchID }
            // A delayed retry of an already-undone import must not re-acquire the released references.
            var retired = index.retiredBatches ?? []
            retired.insert(batchID)
            index.retiredBatches = retired
            return ((), true)
        }
    }

    /// A stale rollback receipt cannot delete a different row or a personal preset.
    public func removeBatch(ids: [String], expectedHashes: [String: String]) throws {
        let requested = Set(ids)
        guard requested == Set(expectedHashes.keys), expectedHashes.values.allSatisfy(EditingFingerprint.isSHA256) else {
            throw DevelopmentPresetError.conflict
        }
        try change { index in
            let referenced = Set((index.batches ?? [:]).values.flatMap { $0 })
            guard requested.isDisjoint(with: referenced) else { throw DevelopmentPresetError.conflict }
            let affected = index.records.filter { requested.contains($0.id) }
            guard affected.allSatisfy({ $0.kind != .user && $0.sourceSHA256 == expectedHashes[$0.id] }) else { throw DevelopmentPresetError.conflict }
            index.records.removeAll { requested.contains($0.id) }
            index.favorites.subtract(requested)
            return ((), !affected.isEmpty)
        }
    }

    public func materialize(_ row: DevelopmentPresetRecord) throws -> DevelopmentPresetRecord {
        guard let ref = row.patch.fullRecipeReference else { return row }
        try row.validate()
        let data = try Self.data(at: recipeAssetURL(ref))
        guard Self.hash(data) == ref, let source = row.patch.boundSourceID else { throw DevelopmentPresetError.missingOriginal }
        let recipe = try DevelopmentRecipe.decodeJSON(data)
        try Self.checkFrozenMasks(recipe)
        var result = row
        result.patch = try .init(fullRecipe: recipe, sourceID: source)
        return result
    }

    public func nativeData(for row: DevelopmentPresetRecord) throws -> Data {
        let record = try materialize(row)
        try record.validate()
        guard record.kind == .user, record.sourceSHA256 == nil, record.blockingReasons.isEmpty else { throw DevelopmentPresetError.unavailable }
        return try Self.encoder().encode(NativeFile(schema: 1, preset: record))
    }

    public func importNative(_ data: Data) throws -> DevelopmentPresetRecord {
        guard data.count <= Self.maximumBytes else { throw DevelopmentPresetError.invalid }
        let file = try JSONDecoder().decode(NativeFile.self, from: data)
        guard file.schema == 1, file.preset.kind == .user, file.preset.sourceSHA256 == nil, file.preset.patch.fullRecipeReference == nil, file.preset.blockingReasons.isEmpty else {
            throw DevelopmentPresetError.invalid
        }
        // A future or misspelled optional field must not disappear during personal preset exchange.
        let encoded = try nativeData(for: file.preset)
        guard let received = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let canonical = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
              received == canonical else { throw DevelopmentPresetError.invalid }
        _ = try importBatch([file.preset], originals: [:])
        return try records().first(where: { $0.id == file.preset.id }) ?? file.preset
    }

    /// Browsing reads a small reference. Only capture, full preview, adoption or export opens the frozen recipe and bitmaps.
    private func storedRecord(_ row: DevelopmentPresetRecord) throws -> DevelopmentPresetRecord {
        if row.patch.fullRecipeReference != nil {
            _ = try materialize(row)
            return row
        }
        guard let full = row.patch.fullRecipe else { return row }
        try row.validate()
        try Self.checkFrozenMasks(full)
        let bytes = try Self.encoder().encode(full)
        let hash = Self.hash(bytes)
        try put(bytes, at: recipeAssetURL(hash), hash: hash)
        var stored = row
        stored.patch = row.patch.referencing(hash)
        return stored
    }
    private func recipeAssetURL(_ hash: String) -> URL { root.appendingPathComponent("recipes").appendingPathComponent(hash + ".json") }
    private static func checkFrozenMasks(_ recipe: DevelopmentRecipe) throws {
        for mask in recipe.adjustmentsV3?.masks ?? [] where mask.kind == .subject {
            guard let snapshot = mask.semanticSnapshot, let png = mask.subjectPNG,
                  let source = CGImageSourceCreateWithData(png as CFData, nil),
                  CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
                  let pixel = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  pixel.width == snapshot.width, pixel.height == snapshot.height, pixel.bitsPerComponent == 8,
                  pixel.colorSpace?.model == .monochrome, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw DevelopmentPresetError.missingOriginal
            }
        }
    }
    private static let maximumBytes = 128 * 1024 * 1024

    public static func data(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard size.isRegularFile == true, let bytes = size.fileSize, (0...maximumBytes).contains(bytes) else { throw DevelopmentPresetError.invalid }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw DevelopmentPresetError.invalid }
        return data
    }

    private static func locations(_ json: String?) throws -> Set<String> {
        guard let json else { return [] }
        let array = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        guard array.count <= 2048, array.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw DevelopmentPresetError.invalid }
        return Set(array)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private var indexURL: URL { root.appendingPathComponent("index-v1.json") }
    private func originalURL(_ hash: String) -> URL { root.appendingPathComponent("originals").appendingPathComponent(hash) }
    private func archive(_ record: DevelopmentPresetRecord) throws {
        let data = try Self.encoder().encode(record)
        let hash = Self.hash(data)
        try put(data, at: root.appendingPathComponent("versions").appendingPathComponent(hash + ".json"), hash: hash)
    }
    private func put(_ data: Data, at url: URL, hash: String) throws {
        guard data.count <= Self.maximumBytes else { throw DevelopmentPresetError.invalid }
        if FileManager.default.fileExists(atPath: url.path) {
            guard Self.hash(try Self.data(at: url)) == hash else { throw DevelopmentPresetError.missingOriginal }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
    private func locked<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("catalog.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    private func loadIndex() throws -> Index {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return Index() }
        var index = try JSONDecoder().decode(Index.self, from: Self.data(at: indexURL))
        guard index.schema == 1, Set(index.records.map(\.id)).count == index.records.count else { throw DevelopmentPresetError.invalid }
        let active = Set((index.batches ?? [:]).keys), order = index.batchCommitOrder ?? []
        guard Set(order).count == order.count, Set(order).isSubset(of: active),
              active.isDisjoint(with: index.retiredBatches ?? []) else { throw DevelopmentPresetError.invalid }
        for offset in index.records.indices {
            CameraRawPresetMapping.upgradeImportedExposure(&index.records[offset])
            try index.records[offset].validate()
        }
        return index
    }
    private func read<T>(_ body: (Index) throws -> T) throws -> T {
        try locked(exclusive: false) { try body(loadIndex()) }
    }
    @discardableResult private func change<T>(_ body: (inout Index) throws -> (T, Bool)) throws -> T {
        let (result, changed) = try locked(exclusive: true) {
            var index = try loadIndex()
            let (result, changed) = try body(&index)
            if changed {
                let data = try Self.encoder().encode(index)
                guard data.count <= Self.maximumBytes else { throw DevelopmentPresetError.invalid }
                try data.write(to: indexURL, options: .atomic)
            }
            return (result, changed)
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        return result
    }
    private func change(_ body: (inout Index) throws -> Void) throws {
        try change { index in try body(&index); return ((), true) }
    }
}
