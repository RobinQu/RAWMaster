import Foundation

public struct GroupRenderFrame: Codable, Sendable {
    public let captureID: String
    public let fileID: String
    public let assetID: String
    public let contentID: String
    public let sha256: String
    public let byteCount: Int64
    public let path: String
    public let workVersionID: String?
    public let exposureSeconds: Double?
    public let asset: CatalogJSON
}

public struct GroupRenderRequest: Codable, Sendable {
    public let jobID: String
    public let groupID: String
    public let revision: Int
    public let operation: String
    public let recipe: CatalogJSON
    public let frames: [GroupRenderFrame]
    public let outputURL: URL
}

public struct GroupRenderReceipt: Codable, Sendable {
    public let mediaKind: String
    public let format: String
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let engineVersion: String
    public let facts: CatalogJSON

    public init(mediaKind: String, format: String, width: Int, height: Int, frameCount: Int,
                engineVersion: String, facts: CatalogJSON) {
        self.mediaKind = mediaKind
        self.format = format
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.engineVersion = engineVersion
        self.facts = facts
    }
}

public struct GroupProcessingResult: Sendable {
    public let jobID: String
    public let workID: String
    public let resourceID: String
    public let outputURL: URL
}

@MainActor
public enum GroupProcessingRunner {
    public typealias Renderer = @MainActor (GroupRenderRequest) async throws -> GroupRenderReceipt
    private struct Run: Decodable {
        var jobID: String
        var groupID: String
        var revision: Int
        var operation: String
        var recipe: CatalogJSON
        var state: String
        var token: String?
        var frames: [GroupRenderFrame]?
        var outputPath: String?
        var receiptPath: String?
        var workID: String?
        var resourceID: String?
    }

    static func call(_ actions: CatalogActions, _ action: String,
                     _ fields: [String: CatalogJSON]) async throws -> CatalogJSON {
        var value = fields
        value["action"] = .string(action)
        return try await actions.read("groupProcessing", value)
    }

    public static func render(actions: CatalogActions, groupID: String, operation: String,
                              recipe: CatalogJSON, revision: Int? = nil,
                              selections: [CatalogJSON] = [], jobID: String = UUID().uuidString,
                              parentJobID: String? = nil,
                              render: @escaping Renderer) async throws -> GroupProcessingResult {
        var input: [String: CatalogJSON] = ["groupID": .string(groupID), "operation": .string(operation),
                                            "recipe": recipe, "jobID": .string(jobID), "selections": .array(selections)]
        let chosen: Int
        if let revision { chosen = revision }
        else {
            let response = try await call(actions, "draft", ["groupID": .string(groupID)])
            guard case .integer(let value) = response["revision"] else { throw failure("无法读取拍摄组修订。") }
            chosen = Int(value)
        }
        input["revision"] = .integer(Int64(chosen))
        if let parentJobID { input["parentJobID"] = .string(parentJobID) }
        _ = try await call(actions, "freeze", input)
        return try await resume(actions: actions, jobID: jobID, render: render)
    }

    public static func resume(actions: CatalogActions, jobID: String,
                              render: @escaping Renderer) async throws -> GroupProcessingResult {
        let key: [String: CatalogJSON] = ["jobID": .string(jobID)]
        var run = try await call(actions, "claim", key).decoded(Run.self)
        if run.state == "rendering", let token = run.token, let frames = run.frames,
           let destination = run.outputPath, let marker = run.receiptPath {
            let attempt: [String: CatalogJSON] = ["jobID": .string(jobID), "token": .string(token)]
            let heartbeat = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    try Task.checkCancellation()
                    _ = try await call(actions, "renew", attempt)
                }
            }
            defer { heartbeat.cancel() }
            do {
                try Task.checkCancellation()
                let request = GroupRenderRequest(jobID: jobID, groupID: run.groupID, revision: run.revision,
                    operation: run.operation, recipe: run.recipe, frames: frames, outputURL: URL(fileURLWithPath: destination))
                let receipt = try await render(request)
                try Task.checkCancellation()
                let encoded = try JSONEncoder().encode(receipt)
                try encoded.write(to: URL(fileURLWithPath: marker), options: .atomic)
                run = try await call(actions, "checkpoint", attempt).decoded(Run.self)
            } catch {
                var failed = attempt
                failed["detail"] = .string(error.localizedDescription)
                _ = try? await call(actions, Task.isCancelled ? "cancel" : "fail", failed)
                throw error
            }
        }
        if run.state == "staged" { run = try await call(actions, "publish", key).decoded(Run.self) }
        guard run.state == "published", let work = run.workID, let resource = run.resourceID else {
            throw failure("作业尚未生成可入库的成片。")
        }
        let output = try await call(actions, "inspectOutput", key)
        guard let path = output["path"]?.stringValue else { throw failure("成片资源不可用。") }
        return GroupProcessingResult(jobID: jobID, workID: work, resourceID: resource,
                                     outputURL: URL(fileURLWithPath: path))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "RAWMaster.GroupProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
