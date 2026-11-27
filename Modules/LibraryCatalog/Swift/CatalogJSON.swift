import Foundation

/// Opaque cursors and external rules retain integer precision when passed back across the ABI.
public enum CatalogJSON: Codable, Equatable, Sendable {
    case null, boolean(Bool), integer(Int64), number(Double), string(String)
    case array([CatalogJSON]), object([String: CatalogJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let flag = try? container.decode(Bool.self) { self = .boolean(flag) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let values = try? container.decode([CatalogJSON].self) { self = .array(values) }
        else { self = .object(try container.decode([String: CatalogJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .boolean(let flag): try container.encode(flag)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let fields): try container.encode(fields)
        }
    }

    public static func encoding<T: Encodable>(_ value: T) throws -> Self {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

public struct CatalogGridRequest<Query: Encodable & Sendable>: Encodable, Sendable {
    public var projectID: String?
    public var sessionID: String?
    public var groupID: String?
    public var collectionID: String?
    public var level: String
    public var nativeRenditions: Bool?
    public var sort: String
    public var query: Query
    public var predicate: CatalogJSON?
    public var orderBase: String?
    public var pageSize: Int
    public var cursor: CatalogJSON?
    public var includeOrderedIDs: Bool
    public var facets: [String]

    public init(query: Query, sort: String, level: String = "file", pageSize: Int = 60,
                projectID: String? = nil, sessionID: String? = nil, groupID: String? = nil,
                collectionID: String? = nil, cursor: CatalogJSON? = nil,
                includeOrderedIDs: Bool = false, facets: [String] = [], predicate: CatalogJSON? = nil,
                orderBase: String? = nil) {
        self.query = query
        self.predicate = predicate
        self.orderBase = orderBase
        self.sort = sort
        self.level = level
        self.pageSize = pageSize
        self.projectID = projectID
        self.sessionID = sessionID
        self.groupID = groupID
        self.collectionID = collectionID
        self.cursor = cursor
        self.includeOrderedIDs = includeOrderedIDs
        self.facets = facets
    }
}

public struct CatalogMatch: Decodable, Equatable, Sendable {
    public let assetID: String
    public let fileID: String
    public let captureID: String
    public let projectID: String
}

public struct CatalogCard<Asset: Decodable & Sendable>: Decodable, Sendable {
    public let assetID: String
    public let fileID: String
    public let captureID: String
    public let projectID: String
    public let asset: Asset
    public let matches: [CatalogMatch]
    public let matchedAssetIDs: [String]
    public let matchedFileIDs: [String]
}

public struct CatalogGridPage<Asset: Decodable & Sendable>: Decodable, Sendable {
    public let status: String
    public let libraryID: String
    public let generation: CatalogJSON
    public let watermark: Int64
    public let totalFiles: Int?
    public let totalCaptures: Int?
    public let total: Int?
    public let items: [CatalogCard<Asset>]?
    public let orderedAssetIDs: [String]?
    public let nextCursor: CatalogJSON?
    public let facets: CatalogJSON?
}

public struct CatalogFrozenSelection: Codable, Equatable, Sendable {
    public let libraryID: String
    public let watermark: Int64
    public let projectID: String?
    public let assetIDs: [String]

    public func replacingMembers(_ ids: [String]) -> Self {
        Self(libraryID: libraryID, watermark: watermark, projectID: projectID, assetIDs: ids)
    }
}

public enum CatalogSelectionError: LocalizedError {
    case changed
    public var errorDescription: String? { "资料库内容已更新，请返回网格核对选片后重新导出。" }
}
