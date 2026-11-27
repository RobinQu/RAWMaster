import CryptoKit
import Foundation
import RAWMasterCore
import RAWMasterImaging
import RAWMasterLibrary

struct WorkbenchDeliveryManifest: Codable, Sendable {
    struct ObjectRef: Codable, Sendable {
        let sha256: String
        let byteCount: Int64
    }
    struct Destination: Codable, Sendable {
        let grantID: String
        let pathHint: String
    }
    struct Context: Codable, Sendable {
        let submittedAt: Date
        let filenames: [String]
    }
    struct Source: Codable, Sendable {
        let projectID: String
        let assetID: String
        let contentSHA256: String
        let byteCount: Int64
        let admissionFingerprint: String

        init(_ snapshot: EditingSourceSnapshot) {
            projectID = snapshot.projectID
            assetID = snapshot.assetID
            contentSHA256 = snapshot.contentSHA256
            byteCount = snapshot.byteCount
            admissionFingerprint = snapshot.admissionFingerprint
        }
    }
    struct Item: Codable, Sendable {
        let ordinal: Int
        let assetID: String
        let stem: String
        let workID: String
        let versionID: String
        let source: Source
        let body: ObjectRef?
    }
    let schema: Int
    let batchID: String
    let libraryID: String
    let destination: Destination
    let sourceContext: Context
    let namingTemplate: String
    let collision: String
    let configuration: ObjectRef?
    let items: [Item]
}

struct WorkbenchDeliveryCatalog: Sendable {
    struct Batch: Decodable, Identifiable, Sendable {
        enum Phase: String, Decodable, Sendable {
            case running, interrupted, cancelled, done, historical
        }
        let batchID: String
        let phase: Phase
        let generation: Int64
        let itemCount: Int
        let createdAtMs: Int64
        var id: String { batchID }
    }
    struct Item: Decodable, Identifiable, Sendable {
        enum State: String, Decodable, Sendable {
            case pending, running, prepared, delivered, skipped, failed, cancelled
        }
        let ordinal: Int
        let state: State
        let filename: String?
        let sha256: String?
        let reason: String?
        let sceneExecution: DevelopmentSceneExecutionReceiptV1?
        var id: Int { ordinal }
        var finished: Bool { state == .delivered || state == .skipped }
    }
    struct Items: Decodable, Sendable {
        let available: Bool
        let complete: Bool
        let items: [Item]
    }
    struct Receipt: Sendable {
        let batch: Batch
        let manifest: WorkbenchDeliveryManifest?
        let items: Items
        var inlineConfiguration: PhotoBatchExportConfiguration? = nil
        var inlineInputs: [FrozenInput]? = nil
    }
    struct Lease: Sendable {
        let batchID: String
        let generation: Int64
        let token: String

        var fields: [String: CatalogJSON] {
            ["batchID": .string(batchID), "generation": .integer(generation), "token": .string(token)]
        }
    }
    struct ItemLease: Sendable {
        let parent: Lease
        let ordinal: Int
        let token: String

        var fields: [String: CatalogJSON] {
            var fields = parent.fields
            fields["ordinal"] = .integer(Int64(ordinal))
            fields["itemToken"] = .string(token)
            return fields
        }
    }
    struct ItemReply: Decodable, Sendable {
        let item: Item
        let itemToken: String?
        let status: String?
    }
    private enum LeaseActivity<T: Sendable>: Sendable {
        case result(T)
        case completedHeartbeat
    }
    struct FrozenInput: Codable, Sendable {
        let schema: Int
        let role: String
        let work: PhotoWork
        let version: EditingVersion

        init(work: PhotoWork, version: EditingVersion) {
            var work = work
            // The immutable version carries the selected recipe, including a submitted draft.
            work.liveRecipe = nil
            work.liveParentVersionID = nil
            work.liveRevision = nil
            work.livePresetAdoptions = nil
            self.work = work
            self.version = version
            schema = 1
            role = "item"
        }
    }
    private struct Settings: Codable, Sendable {
        let schema: Int
        let role: String
        let configuration: PhotoBatchExportConfiguration
    }
    private struct InlineManifest: Codable, Sendable {
        struct Item: Codable, Sendable {
            let ordinal: Int
            let assetID: String
            let stem: String
            let work: PhotoWork
            let version: EditingVersion
        }
        let schema: Int
        let batchID: String
        let libraryID: String
        let destination: WorkbenchDeliveryManifest.Destination
        let sourceContext: WorkbenchDeliveryManifest.Context
        let namingTemplate: String
        let collision: String
        let configuration: PhotoBatchExportConfiguration
        let items: [Item]

        var summary: WorkbenchDeliveryManifest {
            .init(schema: schema, batchID: batchID, libraryID: libraryID, destination: destination, sourceContext: sourceContext,
                namingTemplate: namingTemplate, collision: collision, configuration: nil, items: items.map {
                    .init(ordinal: $0.ordinal, assetID: $0.assetID, stem: $0.stem, workID: $0.work.id, versionID: $0.version.id,
                        source: .init($0.version.source), body: nil)
                })
        }
    }
    private struct InlineRegister<Manifest: Encodable & Sendable>: Encodable, Sendable {
        let action = "register"
        let manifest: Manifest
        let directory: String
        let leaseMs: Int64
    }

    private enum LoadedManifest: Decodable, Sendable {
        case inline(InlineManifest)
        case objects(WorkbenchDeliveryManifest)

        private enum CodingKeys: String, CodingKey { case schema }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            switch try fields.decode(Int.self, forKey: .schema) {
            case 1: self = .inline(try InlineManifest(from: decoder))
            case 2: self = .objects(try WorkbenchDeliveryManifest(from: decoder))
            default: throw WorkbenchDeliveryIssue.invalidReceipt
            }
        }
    }

    private struct LoadedBatch: Decodable, Sendable {
        let batch: Batch
        let manifest: LoadedManifest
    }

    private struct LoadedBody<T: Decodable & Sendable>: Decodable, Sendable {
        let body: T
    }

    private struct SchedulerRequest<T: Encodable>: Encodable {
        let op = "workbenchBatch"
        let command: T
    }

    let database: URL
    private static let leaseMS: Int64 = 18_000

    private func request<T: Decodable>(_ action: String, _ payload: [String: CatalogJSON], as type: T.Type) throws -> T {
        var command = payload
        command["action"] = .string(action)
        return try LibraryEngine.shared().request("scheduler", at: database, payload: SchedulerRequest(command: command), as: type)
    }

    private func call(_ action: String, _ fields: [String: CatalogJSON], fileIO: Bool = false) async throws -> CatalogJSON {
        try await call(action, fields, as: CatalogJSON.self, fileIO: fileIO)
    }

    private func call<T: Decodable & Sendable>(_ action: String, _ fields: [String: CatalogJSON], as type: T.Type,
                                                fileIO: Bool = false) async throws -> T {
        if fileIO {
            return try await ProcessingAdmission.shared.withPermit(.export, resources: .init(cpu: 1, io: 1, memoryBytes: 1 << 20)) {
                try await Task.detached { try request(action, fields, as: type) }.value
            }
        }
        return try await Task.detached { try request(action, fields, as: type) }.value
    }

    private func stage<T: Encodable>(_ value: T, at file: URL) throws -> WorkbenchDeliveryManifest.ObjectRef {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let reference = WorkbenchDeliveryManifest.ObjectRef(sha256: digest, byteCount: Int64(bytes.count))
        _ = try request("stageResource", ["path": .string(file.path), "sha256": .string(digest), "byteCount": .integer(reference.byteCount)],
            as: CatalogJSON.self)
        return reference
    }

    private func stageBody<T: Encodable & Sendable>(_ value: T, at file: URL) async throws -> WorkbenchDeliveryManifest.ObjectRef {
        try await ProcessingAdmission.shared.withPermit(.export, resources: .init(cpu: 1, io: 1, memoryBytes: 16 << 20)) {
            try await Task.detached { try stage(value, at: file) }.value
        }
    }

    func register(batchID: String, libraryID: String, destination: WorkbenchDeliveryManifest.Destination,
                  context: WorkbenchDeliveryManifest.Context, naming: String, collision: String, stems: [String],
                  configuration: PhotoBatchExportConfiguration, frozen: [(PhotoWork, EditingVersion)]) async throws -> (WorkbenchDeliveryManifest, Lease) {
        let smallInputs = frozen.allSatisfy { _, version in
            version.recipe == DevelopmentRecipe() && version.artifact == nil && version.presetAdoptions == nil && version.configuration.isEmpty
        }
        if smallInputs {
            let inline = InlineManifest(schema: 1, batchID: batchID, libraryID: libraryID, destination: destination,
                sourceContext: context, namingTemplate: naming, collision: collision, configuration: configuration,
                items: zip(stems, frozen).enumerated().map { index, value in
                    let (stem, (work, version)) = value
                    let input = FrozenInput(work: work, version: version)
                    return .init(ordinal: index + 1, assetID: version.source.assetID, stem: stem, work: input.work, version: version)
                })
            let reply: CatalogJSON? = try await ProcessingAdmission.shared.withPermit(.export,
                resources: .init(cpu: 1, io: 1, memoryBytes: 8 << 20)) {
                try await Task.detached {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.withoutEscapingSlashes]
                    let command = InlineRegister(manifest: inline, directory: destination.pathHint, leaseMs: Self.leaseMS)
                    let request = try LibraryEngine.prepare("scheduler", payload: SchedulerRequest(command: command), encoder: encoder)
                    let limit = 1 << 20
                    // Only the manifest counts. Measure the same envelope around {} for boundary cases.
                    if request.byteCount > limit {
                        let empty = InlineRegister(manifest: LibraryEmpty(), directory: destination.pathHint, leaseMs: Self.leaseMS)
                        let header = try LibraryEngine.prepare("scheduler", payload: SchedulerRequest(command: empty), encoder: encoder)
                        let overhead = header.byteCount - (try encoder.encode(LibraryEmpty()).count)
                        if request.byteCount - overhead > limit { return nil }
                    }
                    return try LibraryEngine.shared().request(request, at: database, as: CatalogJSON.self)
                }.value
            }
            if let reply { return (inline.summary, try lease(from: reply)) }
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "rawmaster-batch-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let settings = try await stageBody(Settings(schema: 1, role: "configuration", configuration: configuration),
            at: scratch.appending(path: "configuration.json"))
        let workers = smallInputs ? min(3, ProcessingAdmission.shared.capacity.io) : 1
        let items = try await withThrowingTaskGroup(of: WorkbenchDeliveryManifest.Item.self) { group in
            func start(_ index: Int) {
                let (work, version) = frozen[index]
                let stem = stems[index]
                group.addTask {
                    let body = try await stageBody(FrozenInput(work: work, version: version), at: scratch.appending(path: "item-\(index).json"))
                    return WorkbenchDeliveryManifest.Item(ordinal: index + 1, assetID: version.source.assetID,
                        stem: stem, workID: work.id, versionID: version.id, source: .init(version.source), body: body)
                }
            }
            let initial = min(workers, frozen.count)
            for index in 0 ..< initial { start(index) }
            var pending = initial
            var ordered = [WorkbenchDeliveryManifest.Item]()
            while let done = try await group.next() {
                ordered.append(done)
                if pending < frozen.count {
                    start(pending)
                    pending += 1
                }
            }
            return ordered.sorted { $0.ordinal < $1.ordinal }
        }
        let manifest = WorkbenchDeliveryManifest(schema: 2, batchID: batchID, libraryID: libraryID, destination: destination,
            sourceContext: context, namingTemplate: naming, collision: collision, configuration: settings, items: items)
        return (manifest, try await registerManifest(.encoding(manifest), destination: destination))
    }

    private func registerManifest(_ encoded: CatalogJSON, destination: WorkbenchDeliveryManifest.Destination) async throws -> Lease {
        try Task.checkCancellation()
        let reply = try await call("register", ["manifest": encoded, "directory": .string(destination.pathHint),
            "leaseMs": .integer(Self.leaseMS)], fileIO: true)
        return try lease(from: reply)
    }

    func history() async throws -> [Batch] {
        var result: [Batch] = []
        var after: String?
        repeat {
            try Task.checkCancellation()
            let reply = try await call("list", ["limit": .integer(64), "after": after.map(CatalogJSON.string) ?? .null])
            guard let batches = try reply["batches"]?.decoded([Batch].self) else { throw WorkbenchDeliveryIssue.invalidReceipt }
            result.append(contentsOf: batches)
            after = reply["nextAfter"]?.stringValue
        } while after != nil
        return result.sorted { $0.createdAtMs > $1.createdAtMs }
    }

    func receipt(batchID: String) async throws -> Receipt {
        let key = ["batchID": CatalogJSON.string(batchID)]
        let items = try await call("items", key, as: Items.self)
        guard items.available else {
            let response = try await call("load", key)
            guard let batch = try response["batch"]?.decoded(Batch.self) else { throw WorkbenchDeliveryIssue.invalidReceipt }
            return Receipt(batch: batch, manifest: nil, items: items)
        }
        let frozen = try await call("load", key, as: LoadedBatch.self)
        switch frozen.manifest {
        case .inline(let inline):
            return Receipt(batch: frozen.batch, manifest: inline.summary, items: items, inlineConfiguration: inline.configuration,
                inlineInputs: inline.items.map { .init(work: $0.work, version: $0.version) })
        case .objects(let manifest):
            return Receipt(batch: frozen.batch, manifest: manifest, items: items)
        }
    }

    func configuration(batchID: String) async throws -> PhotoBatchExportConfiguration {
        try await call("loadResource", ["batchID": .string(batchID), "role": .string("configuration")],
            as: LoadedBody<Settings>.self, fileIO: true).body.configuration
    }

    func input(batchID: String, ordinal: Int) async throws -> FrozenInput {
        try await call("loadResource", ["batchID": .string(batchID), "role": .string("item"), "ordinal": .integer(Int64(ordinal))],
            as: LoadedBody<FrozenInput>.self, fileIO: true).body
    }

    private func lease(from reply: CatalogJSON) throws -> Lease {
        guard let batch = try reply["batch"]?.decoded(Batch.self), let token = reply["token"]?.stringValue else {
            throw WorkbenchDeliveryIssue.leaseUnavailable
        }
        return Lease(batchID: batch.batchID, generation: batch.generation, token: token)
    }

    func begin(_ batch: Batch) async throws -> Lease {
        let reply = try await call("begin", ["batchID": .string(batch.batchID), "expectedGeneration": .integer(batch.generation),
            "leaseMs": .integer(Self.leaseMS)], fileIO: true)
        return try lease(from: reply)
    }

    func checkDirectory(batchID: String, directory: URL) async throws {
        let checked = try await call("checkDirectory", ["batchID": .string(batchID), "directory": .string(directory.path)], fileIO: true)
        guard checked["valid"] == .boolean(true) else { throw WorkbenchDeliveryIssue.targetOffline }
    }

    func stop(batchID: String, generation: Int64, token: String?, cancel: Bool) async throws {
        _ = try await call("stop", ["batchID": .string(batchID), "expectedGeneration": .integer(generation),
            "reason": .string(cancel ? "cancelled" : "interrupted"), "token": token.map(CatalogJSON.string) ?? .null])
    }

    func maintain<T: Sendable>(_ lease: Lease, item: ItemLease? = nil,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: LeaseActivity<T>.self) { group in
            group.addTask { .result(try await operation()) }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(4))
                    var fields = item?.fields ?? lease.fields
                    fields["leaseMs"] = .integer(Self.leaseMS)
                    do {
                        _ = try await call(item == nil ? "renew" : "renewItem", fields)
                    } catch {
                        try Task.checkCancellation()
                        // The receipt can clear the lease while the successful call is still cleaning the stage.
                        let latest = try? await receipt(batchID: lease.batchID)
                        if latest?.batch.phase == .done || (item.map { child in
                            latest?.items.items.contains { $0.ordinal == child.ordinal && $0.finished } == true
                        } ?? false) { return .completedHeartbeat }
                        throw error
                    }
                }
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if case let .result(value) = next { return value }
            }
            throw WorkbenchDeliveryIssue.leaseUnavailable
        }
    }

    func finish(_ lease: Lease) async throws {
        _ = try await call("finishBatch", lease.fields)
    }

    func claim(_ lease: Lease, ordinal: Int) async throws -> ItemReply {
        var fields = lease.fields
        fields["ordinal"] = .integer(Int64(ordinal))
        fields["leaseMs"] = .integer(Self.leaseMS)
        return try await call("claimItem", fields).decoded(ItemReply.self)
    }

    func prepare(_ lease: ItemLease, directory: URL, stage: URL, suffix: Int, sceneExecution: DevelopmentSceneExecutionReceiptV1? = nil) async throws -> ItemReply {
        var fields = lease.fields
        fields["directory"] = .string(directory.path)
        fields["stage"] = .string(stage.deletingLastPathComponent().lastPathComponent + "/" + stage.lastPathComponent)
        fields["suffix"] = .integer(Int64(suffix))
        if let sceneExecution { fields["sceneExecution"] = try .encoding(sceneExecution) }
        return try await call("prepareItem", fields, fileIO: true).decoded(ItemReply.self)
    }

    // Called while the imaging export stage holds its I/O permit. Rust owns the write transaction and directory FDs.
    func publish(_ lease: ItemLease, directory: URL) throws -> ItemReply {
        var fields = lease.fields
        fields["directory"] = .string(directory.path)
        return try request("publishItem", fields, as: ItemReply.self)
    }

    func acknowledge(batchID: String, ordinal: Int, directory: URL) async throws -> ItemReply {
        try await call("acknowledgeItem", ["batchID": .string(batchID), "ordinal": .integer(Int64(ordinal)),
            "directory": .string(directory.path)], fileIO: true).decoded(ItemReply.self)
    }

    func skip(_ lease: ItemLease, directory: URL, suffix: Int) async throws -> ItemReply {
        var fields = lease.fields
        fields["directory"] = .string(directory.path)
        fields["suffix"] = .integer(Int64(suffix))
        return try await call("skipItem", fields, fileIO: true).decoded(ItemReply.self)
    }

    func fail(_ lease: ItemLease, reason: String) async throws {
        var fields = lease.fields
        fields["reason"] = .string(reason)
        _ = try await call("failItem", fields)
    }
}

enum WorkbenchDeliveryIssue: String, LocalizedError, Sendable {
    case invalidReceipt, leaseUnavailable, targetOffline, sourceOffline, conflictingPrepared, missingStage, writeFailed
    case hdrMasterRequired, pqSelectionChanged

    var errorDescription: String? {
        switch self {
        case .invalidReceipt: "无法读取这批交付的记录。"
        case .leaseUnavailable: "这批交付正在另一个窗口处理。请稍后再试。"
        case .targetOffline: "接回提交时使用的输出目录，然后继续。"
        case .sourceOffline: "接回原片后继续本项交付。"
        case .conflictingPrepared: "输出位置有同名文件。请核对原目标后重试。"
        case .missingStage: "找不到本项的暂存文件。请核对原目标目录。"
        case .hdrMasterRequired: "所选版本没有已保存的 HDR 母版；请返回选片或明确选择 SDR。"
        case .pqSelectionChanged: "照片或版本已变化，请重新核对 HDR 成片。"
        case .writeFailed: "写入未完成。请检查输出目录后重试。"
        }
    }
}
