import Foundation
import CONNXRuntime

public final class ONNXCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var active: (options: OpaquePointer, api: UnsafePointer<OrtApi>)?

    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    public func cancel() {
        lock.lock()
        cancelled = true
        let active = self.active
        lock.unlock()
        if let active { _ = active.api.pointee.RunOptionsSetTerminate(active.options) }
    }

    public func throwIfCancelled() throws {
        if isCancelled { throw MaskAIError.cancelled }
    }

    fileprivate func attach(_ options: OpaquePointer, api: UnsafePointer<OrtApi>) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw MaskAIError.cancelled }
        active = (options, api)
    }

    fileprivate func detach() {
        lock.lock(); active = nil; lock.unlock()
    }
}

public enum ONNXElementType: String, Codable, Sendable {
    case float32, float16, int64, int32, bool, uint8

    var ortType: ONNXTensorElementDataType {
        switch self {
        case .float32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
        case .float16: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16
        case .int64: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
        case .int32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32
        case .bool: return ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL
        case .uint8: return ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8
        }
    }

    var byteCount: Int {
        switch self {
        case .float32, .int32: return 4
        case .float16: return 2
        case .int64: return 8
        case .bool, .uint8: return 1
        }
    }

    static func fromORT(_ type: ONNXTensorElementDataType) throws -> ONNXElementType {
        switch type {
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT: return .float32
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16: return .float16
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64: return .int64
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32: return .int32
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL: return .bool
        case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8: return .uint8
        default: throw MaskAIError.unsupportedTensor("ONNX element type \(type.rawValue).")
        }
    }
}

public struct ONNXTensor: Sendable {
    public let type: ONNXElementType
    public let shape: [Int]
    public let data: Data

    public init(type: ONNXElementType, shape: [Int], data: Data) throws {
        let count = shape.reduce(1, *)
        guard count >= 0, data.count == count * type.byteCount else {
            throw MaskAIError.invalidInput("Tensor \(shape) \(type) expects \(count * type.byteCount) bytes, got \(data.count).")
        }
        self.type = type; self.shape = shape; self.data = data
    }

    public static func floats(_ values: [Float], shape: [Int]) throws -> ONNXTensor {
        let data = values.withUnsafeBytes { Data($0) }
        return try ONNXTensor(type: .float32, shape: shape, data: data)
    }
    public static func int64s(_ values: [Int64], shape: [Int]) throws -> ONNXTensor {
        let data = values.withUnsafeBytes { Data($0) }
        return try ONNXTensor(type: .int64, shape: shape, data: data)
    }
    public static func int32s(_ values: [Int32], shape: [Int]) throws -> ONNXTensor {
        let data = values.withUnsafeBytes { Data($0) }
        return try ONNXTensor(type: .int32, shape: shape, data: data)
    }
    public static func bools(_ values: [Bool], shape: [Int]) throws -> ONNXTensor {
        try ONNXTensor(type: .bool, shape: shape, data: Data(values.map { $0 ? 1 : 0 }))
    }

    public var elementCount: Int { shape.reduce(1, *) }

    public func floats() throws -> [Float] {
        switch type {
        case .float32:
            return data.withUnsafeBytes { raw in
                raw.bindMemory(to: Float.self).map { $0 }
            }
        case .float16:
            return data.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt16.self).map { Float(Float16(bitPattern: $0)) }
            }
        case .int64:
            return data.withUnsafeBytes { raw in raw.bindMemory(to: Int64.self).map { Float($0) } }
        case .int32:
            return data.withUnsafeBytes { raw in raw.bindMemory(to: Int32.self).map { Float($0) } }
        case .bool, .uint8:
            return data.map { Float($0) }
        }
    }

    public func int64s() throws -> [Int64] {
        if type == .int64 { return data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int64.self)) } }
        if type == .int32 { return data.withUnsafeBytes { raw in raw.bindMemory(to: Int32.self).map { Int64($0) } } }
        throw MaskAIError.unsupportedTensor("Expected an integer tensor, got \(type).")
    }
}

private final class ONNXRuntimeContext {
    static let shared = try! ONNXRuntimeContext()
    let api: UnsafePointer<OrtApi>
    let env: OpaquePointer

    init() throws {
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw MaskAIError.inferenceFailed("ONNX Runtime API \(ORT_API_VERSION) is unavailable.")
        }
        self.api = api
        var environment: OpaquePointer?
        try Self.check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "MaskAI", &environment))
        guard let environment else { throw MaskAIError.inferenceFailed("ONNX Runtime returned no environment.") }
        env = environment
    }

    static func check(_ api: UnsafePointer<OrtApi>, _ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "Unknown ONNX Runtime error"
        api.pointee.ReleaseStatus(status)
        throw MaskAIError.inferenceFailed(message)
    }

    deinit { api.pointee.ReleaseEnv(env) }
}

public final class ONNXSession {
    private let context: ONNXRuntimeContext
    private let session: OpaquePointer
    public let inputNames: [String]
    public let outputNames: [String]

    public init(modelAt url: URL, threadCount: Int = 4) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MaskAIError.modelUnavailable(url.path) }
        context = ONNXRuntimeContext.shared
        let api = context.api.pointee
        var options: OpaquePointer?
        try ONNXRuntimeContext.check(context.api, api.CreateSessionOptions(&options))
        guard let options else { throw MaskAIError.inferenceFailed("Could not create session options.") }
        defer { api.ReleaseSessionOptions(options) }
        try ONNXRuntimeContext.check(context.api, api.SetIntraOpNumThreads(options, Int32(max(1, threadCount))))
        // KleidiAI has a documented ORT 1.27.0 reproducibility issue; deterministic validation opts out.
        _ = "mlas.disable_kleidiai".withCString { key in
            "1".withCString { value in
                api.AddSessionConfigEntry(options, key, value)
            }
        }
        var created: OpaquePointer?
        let nativePath = strdup(url.path)
        let status = api.CreateSession(context.env, nativePath, options, &created)
        free(nativePath)
        try ONNXRuntimeContext.check(context.api, status)
        guard let created else { throw MaskAIError.inferenceFailed("Could not create session for \(url.lastPathComponent).") }
        session = created
        inputNames = try Self.names(session: session, context: context, input: true)
        outputNames = try Self.names(session: session, context: context, input: false)
    }

    private static func names(session: OpaquePointer, context: ONNXRuntimeContext, input: Bool) throws -> [String] {
        let api = context.api.pointee
        var count = 0
        try ONNXRuntimeContext.check(context.api, input
            ? api.SessionGetInputCount(session, &count)
            : api.SessionGetOutputCount(session, &count))
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try ONNXRuntimeContext.check(context.api, api.GetAllocatorWithDefaultOptions(&allocator))
        guard let allocator else { throw MaskAIError.inferenceFailed("Could not create ONNX allocator.") }
        var names: [String] = []
        for index in 0..<count {
            var pointer: UnsafeMutablePointer<CChar>?
            try ONNXRuntimeContext.check(context.api, input
                ? api.SessionGetInputName(session, index, allocator, &pointer)
                : api.SessionGetOutputName(session, index, allocator, &pointer))
            guard let pointer else { throw MaskAIError.inferenceFailed("Missing tensor name at index \(index).") }
            names.append(String(cString: pointer))
            try ONNXRuntimeContext.check(context.api, api.AllocatorFree(allocator, pointer))
        }
        return names
    }

    public func run(inputs: [String: ONNXTensor], cancellation: ONNXCancellation? = nil) throws -> [String: ONNXTensor] {
        try cancellation?.throwIfCancelled()
        let api = context.api.pointee
        let names = inputNames
        let tensors = try names.map { name -> ONNXTensor in
            guard let tensor = inputs[name] else { throw MaskAIError.invalidInput("Missing model input \(name).") }
            return tensor
        }
        var nativeAllocations: [UnsafeMutablePointer<UInt8>] = []
        var inputValues: [OpaquePointer?] = []
        var inputNamePointers: [UnsafePointer<CChar>?] = []
        var outputNamePointers: [UnsafePointer<CChar>?] = []
        var outputs: [OpaquePointer?] = [OpaquePointer?](repeating: nil, count: outputNames.count)
        var memoryInfo: OpaquePointer?

        defer {
            for value in inputValues { if let value { api.ReleaseValue(value) } }
            for allocation in nativeAllocations { allocation.deallocate() }
            for name in inputNamePointers + outputNamePointers { if let name { free(UnsafeMutablePointer(mutating: name)) } }
            if let memoryInfo { api.ReleaseMemoryInfo(memoryInfo) }
        }

        try ONNXRuntimeContext.check(context.api, api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeCPU, &memoryInfo))
        for tensor in tensors {
            let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, tensor.data.count))
            tensor.data.copyBytes(to: allocation, count: tensor.data.count)
            nativeAllocations.append(allocation)
            var value: OpaquePointer?
            var shape = tensor.shape.map { Int64($0) }
            let status = api.CreateTensorWithDataAsOrtValue(memoryInfo, allocation, tensor.data.count,
                                                            &shape, shape.count, tensor.type.ortType, &value)
            try ONNXRuntimeContext.check(context.api, status)
            inputValues.append(value)
        }
        inputNamePointers = names.map { UnsafePointer(strdup($0)) }
        outputNamePointers = outputNames.map { UnsafePointer(strdup($0)) }
        var runOptions: OpaquePointer?
        if let cancellation {
            try ONNXRuntimeContext.check(context.api, api.CreateRunOptions(&runOptions))
            guard let runOptions else { throw MaskAIError.inferenceFailed("Could not create run options.") }
            try cancellation.attach(runOptions, api: context.api)
        }
        defer {
            cancellation?.detach()
            if let runOptions { api.ReleaseRunOptions(runOptions) }
        }
        let runStatus = api.Run(session, runOptions,
                                &inputNamePointers, &inputValues, inputValues.count,
                                &outputNamePointers, outputNames.count, &outputs)
        if let runStatus, cancellation?.isCancelled == true {
            api.ReleaseStatus(runStatus)
            throw MaskAIError.cancelled
        }
        try ONNXRuntimeContext.check(context.api, runStatus)
        try cancellation?.throwIfCancelled()

        var result: [String: ONNXTensor] = [:]
        for (index, name) in outputNames.enumerated() {
            guard let value = outputs[index] else { throw MaskAIError.inferenceFailed("Missing output \(name).") }
            defer { api.ReleaseValue(value) }
            var info: OpaquePointer?
            try ONNXRuntimeContext.check(context.api, api.GetTensorTypeAndShape(value, &info))
            guard let info else { throw MaskAIError.inferenceFailed("Missing output metadata for \(name).") }
            defer { api.ReleaseTensorTypeAndShapeInfo(info) }
            var elementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            try ONNXRuntimeContext.check(context.api, api.GetTensorElementType(info, &elementType))
            let type = try ONNXElementType.fromORT(elementType)
            var dimensionCount = 0
            try ONNXRuntimeContext.check(context.api, api.GetDimensionsCount(info, &dimensionCount))
            var dimensions = [Int64](repeating: 0, count: dimensionCount)
            try ONNXRuntimeContext.check(context.api, api.GetDimensions(info, &dimensions, dimensionCount))
            guard dimensions.allSatisfy({ $0 >= 0 && $0 <= Int.max }) else {
                throw MaskAIError.unsupportedTensor("Dynamic output shape for \(name).")
            }
            var elementCount = 0
            try ONNXRuntimeContext.check(context.api, api.GetTensorShapeElementCount(info, &elementCount))
            var pointer: UnsafeMutableRawPointer?
            try ONNXRuntimeContext.check(context.api, api.GetTensorMutableData(value, &pointer))
            guard let pointer else { throw MaskAIError.inferenceFailed("Missing output storage for \(name).") }
            let data = Data(bytes: pointer, count: elementCount * type.byteCount)
            result[name] = try ONNXTensor(type: type, shape: dimensions.map { Int($0) }, data: data)
        }
        return result
    }

    deinit { context.api.pointee.ReleaseSession(session) }
}
