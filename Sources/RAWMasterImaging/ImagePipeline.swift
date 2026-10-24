import AppKit
import CoreImage
import ImageIO
import Darwin
import RAWMasterCore

public enum ImagePipelineError: LocalizedError {
    case unreadable(String), noEmbeddedPreview(String), unsupportedRAW(String), renderFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "无法读取图像：\(name)"
        case .noEmbeddedPreview(let name): return "文件没有可用的内嵌预览：\(name)"
        case .unsupportedRAW(let name): return "当前 macOS RAW 解码器不支持此文件：\(name)"
        case .renderFailed(let name): return "无法渲染原始分辨率细节：\(name)"
        }
    }
}

/// A cancellation-aware permit queue. CPU/GPU work finishes before handing its permit on.
private actor DecodeGate {
    private var available: Int
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(_ count: Int) { available = count }
    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, continuation))
            }
        }, onCancel: { Task { await self.cancel(id) } })
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiting.isEmpty { available += 1 }
        else { waiting.removeFirst().1.resume() }
    }
}

/// The image cache is independent of authoritative catalogue metadata. No source is ever written.
public actor ImagePipeline {
    public static let shared = ImagePipeline()
    private struct CachedImage { let image: NSImage; let cost: Int; var access: UInt64 }
    private struct Flight { let task: Task<NSImage, Error>; let generation: UUID; var users: Set<UUID> }
    private var previewCache: [String: CachedImage] = [:]
    private var detailCache: [String: CachedImage] = [:]
    private var flights: [String: Flight] = [:]
    private var clock: UInt64 = 0
    private var previewRequests = 0, detailRequests = 0
    private var previewDecodeStarts = 0, detailDecodeStarts = 0
    private let previewBudget: Int
    private let detailBudget: Int
    private let decoder: @Sendable (URL, Int, Bool) throws -> NSImage
    private let previewGate = DecodeGate(2)
    private let detailGate = DecodeGate(1)
    private static let rawExtensions: Set<String> = ["arw", "dng", "raw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "pef", "srw", "3fr", "iiq"]
    // Core Image contexts are thread safe; retaining one avoids repeatedly compiling kernels.
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        previewBudget = 128 * 1024 * 1024
        detailBudget = 512 * 1024 * 1024
        decoder = { try Self.decode(url: $0, maxPixel: $1, detail: $2) }
    }
    /// Internal deterministic seam: production always uses the decoder above.
    init(previewBudget: Int, detailBudget: Int,
         decoder: @escaping @Sendable (URL, Int, Bool) throws -> NSImage) {
        self.previewBudget = max(0, previewBudget); self.detailBudget = max(0, detailBudget)
        self.decoder = decoder
    }
    struct Snapshot {
        let previewBytes: Int; let detailBytes: Int
        let previewEntries: Int; let detailEntries: Int
        let inFlightRequests: Int; let inFlightUsers: Int
        let previewRequests: Int; let detailRequests: Int
        let previewDecodeStarts: Int; let detailDecodeStarts: Int
    }
    func testingSnapshot() -> Snapshot {
        Snapshot(previewBytes: previewCache.values.reduce(0) { $0 + $1.cost },
            detailBytes: detailCache.values.reduce(0) { $0 + $1.cost },
            previewEntries: previewCache.count, detailEntries: detailCache.count,
            inFlightRequests: flights.count, inFlightUsers: flights.values.reduce(0) { $0 + $1.users.count },
            previewRequests: previewRequests, detailRequests: detailRequests,
            previewDecodeStarts: previewDecodeStarts, detailDecodeStarts: detailDecodeStarts)
    }

    public func preview(for asset: AssetRecord, maxPixel: Int = 600) async throws -> NSImage {
        try await preview(at: URL(fileURLWithPath: asset.currentPath), maxPixel: maxPixel)
    }
    public func detail(for asset: AssetRecord) async throws -> NSImage {
        try await detail(at: URL(fileURLWithPath: asset.currentPath))
    }
    /// URL variants allow diagnostics to exercise the identical shipped decoding path.
    public func preview(at url: URL, maxPixel: Int = 600) async throws -> NSImage {
        try await request(url: url, maxPixel: max(64, min(maxPixel, 4096)), detail: false)
    }
    public func detail(at url: URL) async throws -> NSImage {
        try await request(url: url, maxPixel: 0, detail: true)
    }
    public func clearCaches() { previewCache.removeAll(); detailCache.removeAll(); Self.context.clearCaches() }

    private func request(url: URL, maxPixel: Int, detail: Bool) async throws -> NSImage {
        if detail { detailRequests += 1 } else { previewRequests += 1 }
        try Task.checkCancellation()
        // URL.resourceValues may reuse metadata cached inside a caller-retained URL.
        // A fresh filesystem stat must invalidate a bitmap after an external file replacement.
        var attributes = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &attributes, 0) }) == 0 else {
            throw ImagePipelineError.unreadable(url.lastPathComponent)
        }
        let key = "\(url.standardizedFileURL.path)|\(attributes.st_size)|\(attributes.st_mtimespec.tv_sec).\(attributes.st_mtimespec.tv_nsec)|\(detail ? "raw" : String(maxPixel))"
        clock &+= 1
        if var cached = detail ? detailCache[key] : previewCache[key] {
            cached.access = clock
            if detail { detailCache[key] = cached } else { previewCache[key] = cached }
            return cached.image
        }
        let user = UUID()
        let generation: UUID
        let work: Task<NSImage, Error>
        if var flight = flights[key] {
            flight.users.insert(user); flights[key] = flight
            generation = flight.generation; work = flight.task
        } else {
            generation = UUID()
            let gate = detail ? detailGate : previewGate
            let decode = decoder
            work = Task.detached(priority: detail ? .userInitiated : .utility) {
                try await gate.acquire()
                do {
                    try Task.checkCancellation()
                    await self.recordDecodeStart(detail: detail)
                    let image = try autoreleasepool { try decode(url, maxPixel, detail) }
                    try Task.checkCancellation()
                    await gate.release()
                    return image
                } catch {
                    await gate.release()
                    throw error
                }
            }
            flights[key] = Flight(task: work, generation: generation, users: [user])
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                let result = try await work.value
                try Task.checkCancellation()
                cache(result, key: key, detail: detail)
                release(key: key, generation: generation, user: user)
                return result
            } catch {
                release(key: key, generation: generation, user: user)
                throw error
            }
        }, onCancel: {
            Task { await self.release(key: key, generation: generation, user: user) }
        })
    }
    private func recordDecodeStart(detail: Bool) {
        if detail { detailDecodeStarts += 1 } else { previewDecodeStarts += 1 }
    }
    private func release(key: String, generation: UUID, user: UUID) {
        guard var flight = flights[key], flight.generation == generation else { return }
        flight.users.remove(user)
        if flight.users.isEmpty { flight.task.cancel(); flights.removeValue(forKey: key) }
        else { flights[key] = flight }
    }
    private func cache(_ image: NSImage, key: String, detail: Bool) {
        let rep = image.representations.first
        let cost = (rep as? NSBitmapImageRep).map { $0.bytesPerRow * $0.pixelsHigh }
            ?? ((rep?.pixelsWide ?? 0) * (rep?.pixelsHigh ?? 0) * 4)
        let budget = detail ? detailBudget : previewBudget
        guard cost > 0, cost <= budget else { return }
        clock &+= 1
        var entries = detail ? detailCache : previewCache
        entries[key] = CachedImage(image: image, cost: cost, access: clock)
        var total = entries.values.reduce(0) { $0 + $1.cost }
        while total > budget, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            total -= oldest.value.cost; entries.removeValue(forKey: oldest.key)
        }
        if detail { detailCache = entries } else { previewCache = entries }
    }
    private nonisolated static func decode(url: URL, maxPixel: Int, detail: Bool) throws -> NSImage {
        let isRAW = rawExtensions.contains(url.pathExtension.lowercased())
        let cgImage: CGImage
        if detail && isRAW {
            guard let raw = CIRAWFilter(imageURL: url) else { throw ImagePipelineError.unsupportedRAW(url.lastPathComponent) }
            raw.scaleFactor = 1
            raw.isDraftModeEnabled = false
            // CIRAWFilter applies its metadata orientation. Applying EXIF again would rotate twice.
            guard let output = raw.outputImage,
                  !output.extent.isEmpty, !output.extent.isInfinite,
                  let rendered = context.createCGImage(output, from: output.extent.integral,
                        format: .RGBA8, colorSpace: displayColorSpace, deferred: false) else {
                throw ImagePipelineError.renderFailed(url.lastPathComponent)
            }
            cgImage = rendered
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ImagePipelineError.unreadable(url.lastPathComponent)
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let fullSize = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? 1,
                               properties?[kCGImagePropertyPixelHeight] as? Int ?? 1)
            // For RAW previews, never ask ImageIO to synthesize a full RAW thumbnail.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: !isRAW,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: !isRAW,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: detail ? fullSize : maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw isRAW ? ImagePipelineError.noEmbeddedPreview(url.lastPathComponent) : ImagePipelineError.unreadable(url.lastPathComponent)
            }
            cgImage = thumbnail
        }
        // An explicit bitmap representation preserves physical pixel dimensions on Retina.
        // NSImage(cgImage:size:) can expose a display-scaled snapshot representation.
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let image = NSImage(size: NSSize(width: cgImage.width, height: cgImage.height))
        image.addRepresentation(bitmap)
        return image
    }
}
