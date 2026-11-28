import CCoreAI
import Foundation
import Security
import Synchronization

public enum CoreAIError: Int32, Error, Sendable {
    case invalidArgument = 1
    case incompatibleRuntime
    case modelRejected
    case invalidImage
    case invalidLandmarks
    case busy
    case budgetExceeded
    case cancelled
    case inferenceFailed
    case internalFailure

    fileprivate static func check(_ code: Int32) throws {
        if code == RM_CORE_AI_CANCELLED { throw CancellationError() }
        if code != RM_CORE_AI_OK { throw Self(rawValue: code) ?? .internalFailure }
    }
}

public struct CoreAIPixelBuffer: Sendable {
    public enum Format: UInt32, Sendable { case rgba8 = 1, bgra8 }

    public let bytes: Data
    public let width: UInt32
    public let height: UInt32
    public let stride: Int
    public let format: Format

    /// Supply upright, unassociated sRGB8 color bytes. The alpha channel is ignored.
    public init(bytes: Data, width: UInt32, height: UInt32, stride: Int, format: Format) {
        self.bytes = bytes
        self.width = width
        self.height = height
        self.stride = stride
        self.format = format
    }
}

public struct CoreAIFacePoint: Sendable {
    public let x: Double
    public let y: Double

    /// Coordinates are normalized by the full image dimensions in Discovery order.
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// One CoreAI engine may be open per process. Rust serializes session ownership and
/// rejects overlapping invocations. The Swift wrapper keeps buffers and handles live through each join.
public final class CoreAI: @unchecked Sendable {
    private let host: OpaquePointer
    private let submission = Mutex(false)

    private init(host: OpaquePointer) { self.host = host }
    deinit { rm_core_ai_host_close(host) }

    public static func open() async throws -> CoreAI {
        try Task.checkCancellation()
        let runtime = try await Task.detached(priority: .userInitiated) {
            try openMainBundle()
        }.value
        try Task.checkCancellation()
        return runtime
    }

    private static func openMainBundle() throws -> CoreAI {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        let frameworks = contents.appending(path: "Frameworks", directoryHint: .isDirectory)
        let bridge = frameworks.appending(path: "librawmaster_core_ai.dylib")
        let onnx = frameworks.appending(path: "libonnxruntime.1.27.0.dylib")
        try requireRegularFramework(bridge)
        try requireRegularFramework(onnx)
        try requireSealedApplication(bundle)
        let path = Array(contents.path.utf8)
        var status: Int32 = 0
        let result = path.withUnsafeBufferPointer { bytes in
            bridge.path.withCString { rm_core_ai_host_open($0, bytes.baseAddress, bytes.count, &status) }
        }
        try CoreAIError.check(status)
        guard let result else { throw CoreAIError.internalFailure }
        return CoreAI(host: result)
    }

    private static func requireRegularFramework(_ file: URL) throws {
        guard file.resolvingSymlinksInPath().path == file.path,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CoreAIError.incompatibleRuntime
        }
    }

    private static func requireSealedApplication(_ bundle: URL) throws {
        var signature: SecStaticCode?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode))
        guard SecStaticCodeCreateWithPath(bundle as CFURL, SecCSFlags(), &signature) == errSecSuccess,
              let signature, SecStaticCodeCheckValidity(signature, flags, nil) == errSecSuccess else {
            throw CoreAIError.incompatibleRuntime
        }
    }

    public func faceEmbedding(_ image: CoreAIPixelBuffer, landmarks: [CoreAIFacePoint]) async throws -> [Float] {
        try Task.checkCancellation()
        guard image.stride >= 0 else { throw CoreAIError.invalidImage }
        guard landmarks.count == 5 else { throw CoreAIError.invalidLandmarks }
        try reserveSubmission()
        defer { submission.withLock { $0 = false } }
        let cancellation = try Cancellation(runtime: self)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .userInitiated) {
                try self.embedding(image, points: landmarks, cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func embedding(_ image: CoreAIPixelBuffer, points: [CoreAIFacePoint], cancellation: Cancellation) throws -> [Float] {
        let landmarks = points.map { RMCoreAIPointV1(x: $0.x, y: $0.y) }
        var result = [Float](repeating: 0, count: Int(RM_CORE_AI_FACE_EMBEDDING_LENGTH))
        let status = image.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var input = RMCoreAIImageV1(data: bytes.bindMemory(to: UInt8.self).baseAddress, len: bytes.count,
                stride: image.stride, width: image.width, height: image.height, format: image.format.rawValue,
                roi_x: 0, roi_y: 0, roi_width: image.width, roi_height: image.height)
            return landmarks.withUnsafeBufferPointer { points in
                result.withUnsafeMutableBufferPointer { output in
                    rm_core_ai_host_embed_face(host, cancellation.token, &input, points.baseAddress, points.count,
                        output.baseAddress, output.count)
                }
            }
        }
        try CoreAIError.check(status)
        return result
    }

    /// Use this when the consumer goes idle to release the loaded model off the main actor.
    public func evictSession() async throws {
        try reserveSubmission()
        defer { submission.withLock { $0 = false } }
        try await Task.detached(priority: .utility) {
            try CoreAIError.check(rm_core_ai_host_evict(self.host))
        }.value
    }

    private func reserveSubmission() throws {
        try submission.withLock { inFlight in
            guard !inFlight else { throw CoreAIError.busy }
            inFlight = true
        }
    }

    private final class Cancellation: @unchecked Sendable {
        let runtime: CoreAI
        let token: OpaquePointer

        init(runtime: CoreAI) throws {
            guard let token = rm_core_ai_host_create_cancellation(runtime.host) else { throw CoreAIError.internalFailure }
            self.runtime = runtime
            self.token = token
        }

        func cancel() { rm_core_ai_host_request_cancellation(runtime.host, token) }
        deinit { rm_core_ai_host_close_cancellation(runtime.host, token) }
    }
}
