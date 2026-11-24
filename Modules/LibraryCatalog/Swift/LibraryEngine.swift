import CLibraryCatalogABI
import Foundation

public struct LibraryEngineError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct LibraryEmpty: Codable, Sendable {
    public init() {}
}

private struct CatalogEnvelope<Payload: Encodable>: Encodable {
    var operation: String
    var indexPath: String?
    var request: Payload
}

private struct CatalogErrorReply: Decodable {
    var error: String
}

/// Per-call reads own their connections. A transaction call borrows the serialized host connection.
public final class LibraryEngine: @unchecked Sendable {
    private let runtime: OpaquePointer
    private static let instance: Result<LibraryEngine, Error> = Result { try LibraryEngine() }
    public static func shared() throws -> LibraryEngine { try instance.get() }

    private init() throws {
        #if os(macOS)
        let packaged = Bundle.main.privateFrameworksURL?.appendingPathComponent("librawmaster_library.dylib")
        #else
        let packaged: URL? = nil
        #endif
        let image: URL
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) {
            image = packaged
        } else if let build = Bundle.module.url(forResource: "rawmaster-library", withExtension: "runtime") {
            image = build
        } else {
            throw LibraryEngineError("无法找到资料库组件")
        }
        var message: UnsafeMutablePointer<CChar>?
        guard let handle = image.path.withCString({ rm_host_open($0, &message) }) else {
            defer { rm_host_free_message(message) }
            throw LibraryEngineError(message.map { String(cString: $0) } ?? "无法打开资料库组件")
        }
        runtime = handle
    }

    deinit { rm_host_close(runtime) }

    private func decode<T: Decodable>(_ type: T.Type, perform: (inout RMHostReply) -> Int32) throws -> T {
        var reply = RMHostReply()
        let status = perform(&reply)
        defer { rm_host_release(runtime, &reply) }
        guard let bytes = reply.data else { throw LibraryEngineError("资料库组件未返回数据") }
        let data = Data(bytes: bytes, count: reply.length)
        if status != 0 {
            let error = try? JSONDecoder().decode(CatalogErrorReply.self, from: data)
            throw LibraryEngineError(error?.error ?? "资料库操作失败")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Opaque wire data for callers that must decide whether an encoded request fits a bound.
    public struct PreparedRequest: Sendable {
        fileprivate let message: Data
        public var byteCount: Int { message.count }
    }

    public static func prepare<Payload: Encodable>(_ operation: String, index: URL? = nil,
                                                   payload: Payload, encoder: JSONEncoder) throws -> PreparedRequest {
        let envelope = CatalogEnvelope(operation: operation, indexPath: index?.path, request: payload)
        return PreparedRequest(message: try encoder.encode(envelope))
    }

    public func request<Payload: Encodable, Response: Decodable>(
        _ operation: String, at catalog: URL, index: URL? = nil, payload: Payload,
        as type: Response.Type
    ) throws -> Response {
        try request(Self.prepare(operation, index: index, payload: payload, encoder: JSONEncoder()), at: catalog, as: type)
    }

    public func request<Response: Decodable>(_ prepared: PreparedRequest, at catalog: URL,
                                              as type: Response.Type) throws -> Response {
        let message = prepared.message
        let path = Array(catalog.path.utf8)
        return try decode(type) { reply in
            path.withUnsafeBufferPointer { name in
                message.withUnsafeBytes { raw in
                    rm_host_request(runtime, name.baseAddress, name.count, raw.bindMemory(to: UInt8.self).baseAddress,
                                    raw.count, &reply)
                }
            }
        }
    }

    public func transaction<Payload: Encodable, Response: Decodable>(
        _ operation: String, on connection: OpaquePointer, payload: Payload, as type: Response.Type
    ) throws -> Response {
        let message = try JSONEncoder().encode(CatalogEnvelope(operation: operation, indexPath: nil, request: payload))
        return try decode(type) { reply in
            message.withUnsafeBytes { raw in
                rm_host_transaction(runtime, UnsafeMutableRawPointer(connection), raw.bindMemory(to: UInt8.self).baseAddress,
                                    raw.count, &reply)
            }
        }
    }
}
