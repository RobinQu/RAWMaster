import Foundation

/// The host executes mutations through its serialized SQLite transaction owner.
public struct CatalogActions: Sendable {
    public typealias Writer = @Sendable (CatalogJSON) throws -> CatalogJSON
    public let database: URL
    private let writer: Writer

    public init(database: URL, writer: @escaping Writer) {
        self.database = database
        self.writer = writer
    }

    public func read(_ operation: String, _ body: [String: CatalogJSON] = [:]) async throws -> CatalogJSON {
        let url = database
        return try await Task.detached(priority: .userInitiated) {
            try LibraryEngine.shared().request(operation, at: url, payload: CatalogJSON.object(body), as: CatalogJSON.self)
        }.value
    }

    public func perform(_ action: String, _ fields: [String: CatalogJSON] = [:],
                        commandID: String = UUID().uuidString) async throws -> CatalogJSON {
        var body = fields
        body["version"] = .integer(1)
        body["commandID"] = .string(commandID)
        body["action"] = .string(action)
        let command = CatalogJSON.object(body)
        let writer = writer
        return try await Task.detached(priority: .userInitiated) { try writer(command) }.value
    }
}

extension CatalogJSON {
    public subscript(_ key: String) -> CatalogJSON? {
        guard case let .object(fields) = self else { return nil }
        return fields[key]
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var arrayValue: [CatalogJSON]? { if case .array(let value) = self { value } else { nil } }
}
