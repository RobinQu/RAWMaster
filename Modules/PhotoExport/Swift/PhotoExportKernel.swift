import Darwin
import Foundation

public enum PhotoExportKernelError: LocalizedError {
    case unavailable
    case invalid(String)
    case capturedDateRequired
    case destinationExists
    case writeFailed
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "无法加载 RAWMaster 导出组件。"
        case .invalid(let value): value
        case .capturedDateRequired: "命名模板需要拍摄日期。"
        case .destinationExists: "目标文件已存在。"
        case .writeFailed: "无法写入目标目录。请检查目录权限或可用空间。"
        case .encodingFailed: "导出组件无法编码此照片。"
        }
    }

    static func decode(_ status: Int32, detail: String? = nil) -> Self {
        switch status {
        case 2: .destinationExists
        case 3: .writeFailed
        case 4: .capturedDateRequired
        case 5: .encodingFailed
        default: .invalid(detail ?? "导出参数无效。")
        }
    }
}

public enum PhotoExportKernel {
    public enum Codec: UInt32 { case jpeg = 1, png, tiff }
    public enum PixelFormat: UInt32 { case rgbx8 = 1, rgba16 }

    public struct Dimensions: Codable, Equatable {
        public let width: UInt32
        public let height: UInt32
        public init(width: UInt32, height: UInt32) {
            self.width = width
            self.height = height
        }
    }

    public struct Region: Decodable {
        public let x, y, width, height: UInt32
    }

    public struct Geometry: Decodable {
        public let canvas: Dimensions
        public let photo, footer: Region
        public let crop: [Double]
    }

    public struct Frame: Encodable {
        public let ratio: [UInt32]?
        public let marginPercent: Int
        public let footerPerMille: Int
        public let cover: Bool

        public init(ratio: [UInt32]?, marginPercent: Int, footerPerMille: Int, cover: Bool) {
            self.ratio = ratio
            self.marginPercent = marginPercent
            self.footerPerMille = footerPerMille
            self.cover = cover
        }

        private enum CodingKeys: String, CodingKey {
            case ratio, cover
            case marginPercent = "margin_percent"
            case footerPerMille = "footer_per_mille"
        }
    }

    private typealias Version = @convention(c) () -> UInt32
    private typealias Limit = @convention(c) () -> Int
    private typealias Request = @convention(c) (UInt32, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UInt8>?
    private typealias Free = @convention(c) (UnsafeMutablePointer<UInt8>, Int) -> Void
    private typealias Encode = @convention(c) (UnsafePointer<CChar>, UnsafePointer<UInt8>, UInt32, UInt32, Int, Int, UInt32, UInt32, UInt8) -> Int32
    private typealias Publish = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32

    private struct Runtime {
        let limit: Limit
        let request: Request
        let free: Free
        let encode: Encode
        let publish: Publish

        init() throws {
            let url: URL?
            #if RAWMASTER_LOCAL_RAW_VALIDATION
            let library = Bundle.main.bundleURL.resolvingSymlinksInPath()
                .appendingPathComponent("Contents/Frameworks/librawmaster_photo_export.dylib")
            guard library.path == library.resolvingSymlinksInPath().path,
                  (try? library.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw PhotoExportKernelError.unavailable
            }
            url = library
            #else
            url = Bundle.module.url(forResource: "rawmaster-photo-export", withExtension: "runtime")
            #endif
            guard let url, let library = dlopen(url.path, RTLD_LOCAL | RTLD_NOW) else { throw PhotoExportKernelError.unavailable }
            func load<T>(_ name: String, as type: T.Type) throws -> T {
                guard let address = dlsym(library, name) else { throw PhotoExportKernelError.unavailable }
                return unsafeBitCast(address, to: type)
            }
            do {
                let version = try load("rm_photo_export_abi", as: Version.self)
                guard version() == 1 else { throw PhotoExportKernelError.unavailable }
                limit = try load("rm_photo_export_limit", as: Limit.self)
                request = try load("rm_photo_export_request", as: Request.self)
                free = try load("rm_photo_export_free", as: Free.self)
                encode = try load("rm_photo_export_encode", as: Encode.self)
                publish = try load("rm_photo_export_publish", as: Publish.self)
            } catch {
                dlclose(library)
                throw error
            }
            // Loaded function pointers remain valid for the lifetime of the process.
        }
    }

    private static let runtime = Result { try Runtime() }

    /// The fallback keeps the UI label readable if the runtime is missing, while execution fails explicitly.
    public static var maximumBatchPhotos: Int { (try? runtime.get().limit()) ?? 200 }

    private static func invoke(_ op: UInt32, data: Data) throws -> Any {
        let library = try runtime.get()
        var count = 0
        let result = data.withUnsafeBytes { bytes in
            library.request(op, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &count)
        }
        guard let result, count > 0 else { throw PhotoExportKernelError.invalid("无法读取导出设置。") }
        defer { library.free(result, count) }
        let envelope = try JSONSerialization.jsonObject(with: Data(bytes: result, count: count)) as? [String: Any]
        if let error = envelope?["error"] as? String {
            throw PhotoExportKernelError.decode(envelope?["code"] as? Int32 ?? 1, detail: error)
        }
        guard let value = envelope?["value"] else { throw PhotoExportKernelError.invalid("无法读取导出设置。") }
        return value
    }

    public static func validatePhotoCount(_ count: Int) throws {
        _ = try invoke(5, data: JSONEncoder().encode(count))
    }

    public static func validateTemplate(_ template: String) throws {
        _ = try invoke(4, data: Data(template.utf8))
    }

    public static func normalizePreset(_ data: Data) throws -> Data {
        guard data.count <= 2 * 1024 * 1024 else { throw PhotoExportKernelError.invalid("请选择 2 MiB 以内的导出预设。") }
        return try JSONSerialization.data(withJSONObject: invoke(1, data: data),
                                          options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    public static func name(template: String, stem: String, index: Int, exportDate: String, captureDate: String?) throws -> String {
        struct Parameters: Encodable {
            let template, stem: String
            let index: Int
            let exportDate: String
            let captureDate: String?
        }
        let parameters = Parameters(template: template, stem: stem, index: index, exportDate: exportDate, captureDate: captureDate)
        guard let value = try invoke(3, data: JSONEncoder().encode(parameters)) as? String else {
            throw PhotoExportKernelError.invalid("文件名无效。")
        }
        return value
    }

    public static func geometry(source: Dimensions, longEdge: Int?, frame: Frame?) throws -> Geometry {
        struct Parameters: Encodable {
            let source: Dimensions
            let long_edge: Int?
            let frame: Frame?
        }
        let parameters = Parameters(source: source, long_edge: longEdge, frame: frame)
        let value = try invoke(2, data: JSONEncoder().encode(parameters))
        return try JSONDecoder().decode(Geometry.self, from: JSONSerialization.data(withJSONObject: value))
    }

    public static func encode(to url: URL, size: Dimensions, pixels: UnsafeRawBufferPointer, stride: Int,
                              pixelFormat: PixelFormat, codec: Codec, quality: UInt8) throws {
        let library = try runtime.get()
        guard url.isFileURL, stride > 0, let base = pixels.bindMemory(to: UInt8.self).baseAddress else {
            throw PhotoExportKernelError.encodingFailed
        }
        let result = url.path.withCString { path in
            library.encode(path, base, size.width, size.height, stride, pixels.count, pixelFormat.rawValue, codec.rawValue, quality)
        }
        if result != 0 { throw PhotoExportKernelError.decode(result) }
    }

    public static func publish(_ stage: URL, at destination: URL) throws {
        let library = try runtime.get()
        let result = stage.path.withCString { from in
            destination.path.withCString { to in library.publish(from, to) }
        }
        if result != 0 { throw PhotoExportKernelError.decode(result) }
    }
}
