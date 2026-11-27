import CoreImage
import Darwin
import Foundation
import ImageIO
import RAWMasterCore
import RAWMasterPhotoExport
import UniformTypeIdentifiers

public struct PhotoBatchExportConfiguration: Equatable, Codable, Sendable {
    public var format: PhotoRenderFormat
    public var maximumLongEdge: Int?
    public var jpegQuality: Double
    public var layout: PhotoExportLayout
    public var metadataPolicy: PhotoExportMetadataPolicy
    public var includeGPS: Bool

    public init(format: PhotoRenderFormat = .jpeg8, maximumLongEdge: Int? = nil,
                jpegQuality: Double = 0.9, layout: PhotoExportLayout = .init(),
                metadataPolicy: PhotoExportMetadataPolicy = .none, includeGPS: Bool = false) {
        self.format = format; self.maximumLongEdge = maximumLongEdge; self.jpegQuality = jpegQuality
        self.layout = layout; self.metadataPolicy = metadataPolicy; self.includeGPS = includeGPS
    }

    public func validate() throws {
        guard jpegQuality.isFinite, (0.05...1).contains(jpegQuality) else { throw EditingError.invalidRecipe }
        if let maximumLongEdge, !(64...100000).contains(maximumLongEdge) { throw DevelopmentError.invalidGeometry }
        try layout.validate()
        let look = layout.resolvedAppearance
        if format == .avif10 {
            guard maximumLongEdge == nil, look.frame == "none", look.mark == "off", metadataPolicy == .none,
                  !includeGPS, jpegQuality == 0.95 else { throw DevelopmentError.unsupportedEngine }
        }
        if ["signature", "both"].contains(look.mark), layout.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EditingError.invalidRecipe
        }
        if ["exif", "both"].contains(look.mark), look.fields.isEmpty { throw EditingError.invalidRecipe }
        if look.mark == "logo", look.logo == nil { throw EditingError.invalidRecipe }
    }
}

public typealias BatchPhotoCommit = @Sendable () throws -> Void
public typealias BatchPhotoPublication = @Sendable (_ stage: URL, _ destination: URL) async throws -> BatchPhotoCommit
package struct PreparedPhotoDestinationConflict: Error {}

public struct BatchPhotoExecution: Sendable {
    public let retainStageForRecovery: Bool
    public let bufferedThumbnail: Bool
    /// The durable queue attaches the measured scene execution to the same ticket as the encoded bytes.
    package var prepareWithExecution: (@Sendable (URL, URL, DevelopmentSceneExecutionReceiptV1?) async throws -> BatchPhotoCommit)?

    public init(retainStageForRecovery: Bool = false, bufferedThumbnail: Bool = false) {
        self.retainStageForRecovery = retainStageForRecovery
        self.bufferedThumbnail = bufferedThumbnail
    }
}

/// Bounds the app-owned compressed backing across decode and bitmap rendering.
final class NeutralJPEGInput: @unchecked Sendable {
    private final class Budget: @unchecked Sendable {
        let lock = NSLock()
        var retained = 0

        func reserve(_ count: Int) -> Bool {
            lock.withLock {
                guard count <= 8 * 1024 * 1024 - retained else { return false }
                retained += count
                return true
            }
        }

        func release(_ count: Int) { lock.withLock { retained -= count } }
    }

    private static let budget = Budget()
    static var retainedBytes: Int { budget.lock.withLock { budget.retained } }

    let data: CFData
    private let size: Int

    private init(data: CFData, size: Int) {
        self.data = data
        self.size = size
    }

    deinit { Self.budget.release(size) }

    static func capture(file: URL, byteCount: Int64) throws -> NeutralJPEGInput? {
        try Task.checkCancellation()
        guard (1 ... 2 * 1024 * 1024).contains(byteCount), let count = Int(exactly: byteCount),
              budget.reserve(count) else { return nil }
        var retained = false
        defer { if !retained { budget.release(count) } }
        guard let backing = CFDataCreateMutable(nil, count) else { return nil }
        CFDataSetLength(backing, count)
        guard let buffer = CFDataGetMutableBytePtr(backing) else { return nil }
        let file = try FileHandle(forReadingFrom: file)
        defer { try? file.close() }
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let read = Darwin.read(file.fileDescriptor, buffer.advanced(by: offset), count - offset)
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw EditingError.staleSource }
            offset += read
        }
        guard try file.read(upToCount: 1)?.isEmpty != false else { throw EditingError.staleSource }
        retained = true
        return NeutralJPEGInput(data: backing, size: count)
    }
}

public actor PhotoBatchRenderExporter {
    public init() {}

    /// The caller resolves naming tokens and removes the source extension once. A period inside the resulting stem is valid.
    public func export(work: PhotoWork, version: EditingVersion, archive: EditingArchive, directory: URL,
                       filename: String, configuration: PhotoBatchExportConfiguration,
                       protectedURLs: [URL] = [], execution: BatchPhotoExecution = .init(),
                       preparePublication: BatchPhotoPublication? = nil) async throws -> URL {
        try configuration.validate()
        guard version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidSource }
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else { throw EditingError.unsafePath }
        let final = directory.appendingPathComponent(filename).appendingPathExtension(configuration.format.filenameExtension)
        let protected = protectedURLs + [work.source.sourceLocation, version.source.sourceLocation, archive.root]
        try RenderFiles.check(final, protected: protected)
        let temporary = directory.appendingPathComponent(".rawmaster-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retainPreparedStage = false
        defer { if !retainPreparedStage { try? FileManager.default.removeItem(at: temporary) } }
        let stage = temporary.appendingPathComponent("pixels").appendingPathExtension(configuration.format.filenameExtension)
        if configuration.format == .avif10 {
            let ticket = try DevelopmentSceneDeliveryV1(work: work, version: version, format: .avif10)
            let sceneExecution = try await renderingTask(lane: .export, resources: .init(cpu: 1, gpu: 1, io: 1, memoryBytes: 2 << 30)) {
                try DevelopmentSceneDeliveryServiceV1.encodePQForBatch(ticket, to: stage)
            }
            return try await publishBatchPayload(stage, final: final, protected: protected, execution: execution,
                preparePublication: preparePublication, retainPreparedStage: &retainPreparedStage,
                sceneExecution: sceneExecution, verify: { try RenderFiles.verify(version.source) })
        }
        let look = configuration.layout.resolvedAppearance
        let needsMetadata = look.mark == "exif" || look.mark == "both" || configuration.metadataPolicy != .none
        let tagged = temporary.appendingPathComponent("delivery").appendingPathExtension(configuration.format.filenameExtension)
        let artifactURL = try version.artifact.map { try archive.artifactURL($0) }

        let raster: DeliveryRaster
        var sceneExecution: DevelopmentSceneExecutionReceiptV1?
        let metadataURL: URL
        let verify: @Sendable () throws -> Void
        var stagingCapture: URL?
        defer {
            if let stagingCapture { try? FileManager.default.removeItem(at: stagingCapture.deletingLastPathComponent()) }
        }
        if let graph = version.recipe.sceneGraph {
            let format: DevelopmentSceneDeliveryV1.Format = configuration.format == .jpeg8 ? .jpeg8 : .png16
            guard configuration.format == .jpeg8 || configuration.format == .png16 else { throw DevelopmentError.unsupportedEngine }
            _ = try DevelopmentSceneDeliveryV1(work: work, version: version, format: format)
            verify = { try RenderFiles.verify(version.source) }
            metadataURL = version.source.sourceLocation
            (raster, sceneExecution) = try await renderingTask(lane: .export) {
                let capture = try RenderFiles.verifiedPreviewCapture(version.source)
                defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
                return try capture.withCurrent(at: capture.url) {
                    let (image, receipt) = try DevelopmentSceneDeliveryServiceV1.renderSDRForComposition(capture: capture.url, graph: graph)
                    return (try Self.rasterize(image, source: capture.url, configuration: configuration), receipt)
                }
            }
            if needsMetadata {
                stagingCapture = try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
                    try RenderFiles.capture(version.source, synchronize: false)
                }
            }
        } else if let artifactURL, let artifact = version.artifact {
            if needsMetadata {
                stagingCapture = try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
                    do { return try RenderFiles.capture(version.source, synchronize: false) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return nil }
                }
            }
            metadataURL = stagingCapture ?? artifactURL
            verify = {
                guard try RenderFiles.hash(artifactURL) == artifact.sha256 else { throw EditingError.archiveMismatch }
            }
            raster = try await renderingTask(lane: .export) {
                try verify()
                guard let image = CIImage(contentsOf: artifactURL, options: [.applyOrientationProperty: true])
                else { throw DevelopmentError.unreadable }
                return try Self.rasterize(image, source: metadataURL, configuration: configuration)
            }
        } else if DevelopmentBrilliancePublicV1.active(version.recipe) {
            let intermediate = temporary.appendingPathComponent("development.tiff")
            _ = try await RenderExportService().export(work: work, version: version, archive: archive, destination: intermediate,
                                                       format: .tiff16, protectedURLs: protected)
            if needsMetadata {
                stagingCapture = try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
                    try RenderFiles.capture(version.source, synchronize: false)
                }
            }
            metadataURL = stagingCapture ?? intermediate
            verify = {}
            raster = try await renderingTask(lane: .export) {
                guard let image = CIImage(contentsOf: intermediate, options: [.applyOrientationProperty: true])
                else { throw DevelopmentError.unreadable }
                return try Self.rasterize(image, source: metadataURL, configuration: configuration)
            }
        } else {
            let edge = Self.neutralJPEGEdge(for: version, configuration: configuration)
            let buffered = Self.thumbnailOverride ?? execution.bufferedThumbnail
            let (captured, eager, compressed) = try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
                let captured = try RenderFiles.capture(version.source, synchronize: false)
                do {
                    try Task.checkCancellation()
                    if let edge, edge <= 2048, buffered, ["jpg", "jpeg"].contains(version.source.sourceLocation.pathExtension.lowercased()),
                       let bytes = try NeutralJPEGInput.capture(file: captured, byteCount: version.source.byteCount) {
                        return (captured, nil as CGImage?, bytes as NeutralJPEGInput?)
                    }
                    let thumbnail = edge.flatMap { Self.neutralJPEGThumbnail(CGImageSourceCreateWithURL(captured as CFURL, nil), edge: $0) }
                    return (captured, thumbnail, nil)
                } catch {
                    try? FileManager.default.removeItem(at: captured.deletingLastPathComponent())
                    throw error
                }
            }
            stagingCapture = captured
            metadataURL = captured
            verify = { try RenderFiles.verify(version.source) }
            // ImageIO's returned CGImage can still retain the input provider.
            defer { withExtendedLifetime(compressed) {} }
            var thumbnail = eager
            if let compressed, let edge {
                thumbnail = try await renderingTask(lane: .export, resources: .init(cpu: 1)) {
                    Self.neutralJPEGThumbnail(CGImageSourceCreateWithData(compressed.data, nil), edge: edge)
                }
                if thumbnail == nil {
                    thumbnail = try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
                        Self.neutralJPEGThumbnail(CGImageSourceCreateWithURL(captured as CFURL, nil), edge: edge)
                    }
                }
            }
            if let thumbnail {
                // ImageIO has decoded the thumbnail. The unmarked raster holds no file-backed inputs.
                raster = try await renderingTask(lane: .export, resources: .init(cpu: 1, gpu: 1)) {
                    try Self.rasterize(CIImage(cgImage: thumbnail), source: captured, configuration: configuration)
                }
            } else {
                raster = try await renderingTask(lane: .export) {
                    if let scene = version.recipe.adjustmentsV3?.effects?.lensBlur?.sceneDepth,
                       scene.sourceSHA256 != version.source.contentSHA256 { throw EditingError.staleSource }
                    let ownedContext = version.recipe.adjustmentsV3.map { DevelopmentBrillianceAdaptiveV1.isActive($0.light) } == true
                        ? DevelopmentBrillianceAdaptiveV1.makeContext() : nil
                    defer { ownedContext?.clearCaches() }
                    let image = try PhotoRenderer.develop(captured, version.recipe, context: ownedContext).0
                    return try Self.rasterize(image, source: captured, configuration: configuration)
                }
            }
            thumbnail = nil
        }
        // The GPU permit ends after the joined bitmap render. Encoding and metadata may overlap a different frame.
        let frozenMetadataURL = stagingCapture ?? metadataURL
        let payload = try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
            try Self.encode(raster, source: frozenMetadataURL, configuration: configuration, stage: stage, tagged: tagged)
        }
        if execution.retainStageForRecovery {
            // Keep just the deliverable in the private folder for the durable receipt.
            for scratch in [stage, tagged, temporary.appendingPathComponent("development.tiff")] where scratch != payload {
                if FileManager.default.fileExists(atPath: scratch.path) { try FileManager.default.removeItem(at: scratch) }
            }
        }
        return try await publishBatchPayload(payload, final: final, protected: protected, execution: execution,
            preparePublication: preparePublication, retainPreparedStage: &retainPreparedStage, sceneExecution: sceneExecution, verify: verify)
    }

    private func publishBatchPayload(_ payload: URL, final: URL, protected: [URL], execution: BatchPhotoExecution,
                                     preparePublication: BatchPhotoPublication?, retainPreparedStage: inout Bool,
                                     sceneExecution: DevelopmentSceneExecutionReceiptV1?,
                                     verify: @escaping @Sendable () throws -> Void) async throws -> URL {
        try Task.checkCancellation()
        if execution.retainStageForRecovery {
            // The callback can commit a ticket before reporting failure; retain it for reconciliation.
            retainPreparedStage = execution.prepareWithExecution != nil || preparePublication != nil
        }
        let commit: BatchPhotoCommit?
        do {
            if let prepare = execution.prepareWithExecution {
                commit = try await prepare(payload, final, sceneExecution)
            } else { commit = try await preparePublication?(payload, final) }
        } catch DevelopmentError.outputExists {
            // This is the preflight conflict before a ticket exists.
            retainPreparedStage = false
            throw DevelopmentError.outputExists
        }
        retainPreparedStage = commit != nil
        do {
            try await renderingTask(lane: .export, resources: .init(cpu: 1, io: 1)) {
                try Task.checkCancellation()
                try verify()
                try RenderFiles.check(final, protected: protected)
                if let commit { try commit() }
                else { try PhotoExportKernel.publish(payload, at: final) }
            }
            retainPreparedStage = execution.retainStageForRecovery && commit != nil
        } catch DevelopmentError.outputExists, PhotoExportKernelError.destinationExists {
            retainPreparedStage = execution.retainStageForRecovery && commit != nil
            if retainPreparedStage { throw PreparedPhotoDestinationConflict() }
            throw DevelopmentError.outputExists
        }
        return final
    }

    package static func validatePreparedDelivery(work: PhotoWork, version: EditingVersion, archive: EditingArchive,
                                                 destination: URL, protectedURLs: [URL]) throws {
        guard version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidSource }
        if let artifact = version.artifact {
            guard try RenderFiles.hash(archive.artifactURL(artifact)) == artifact.sha256 else { throw EditingError.archiveMismatch }
        } else {
            try RenderFiles.verify(version.source)
        }
        try RenderFiles.check(destination, protected: protectedURLs + [work.source.sourceLocation, version.source.sourceLocation, archive.root])
    }

    package static func validateRelocatedSource(_ location: URL, expected: EditingSourceSnapshot) throws {
        var source = expected
        source.sourceLocation = location
        try RenderFiles.verify(source)
    }

    package static func neutralJPEGEdge(for version: EditingVersion, configuration: PhotoBatchExportConfiguration) -> Int? {
        let layout = configuration.layout.resolvedAppearance
        guard version.artifact == nil, version.recipe == DevelopmentRecipe(), configuration.format == .jpeg8,
              layout.frame == "none", layout.mark == "off" else { return nil }
        return configuration.maximumLongEdge
    }

    private static let thumbnailOverride = ProcessInfo.processInfo.environment["RAWMASTER_QA_CPU_JPEG_THUMBNAIL"]
        .flatMap { value in ["0", "1"].contains(value) ? value == "1" : nil }

    private static func neutralJPEGThumbnail(_ source: CGImageSource?, edge: Int) -> CGImage? {
        guard let input = source, CGImageSourceGetType(input) == UTType.jpeg.identifier as CFString else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
    }

    private static let bitmapContext = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputPremultiplied: false,
        .workingFormat: CIFormat.RGBAh.rawValue])

    private struct DeliveryRaster: Sendable {
        let bitmap: Data
        let width, height, stride: Int
    }

    private static func rasterize(_ developed: CIImage, source metadataURL: URL,
                                  configuration: PhotoBatchExportConfiguration) throws -> DeliveryRaster {
        let look = configuration.layout.resolvedAppearance
        let capture: PhotoExportMetadata
        if look.mark == "exif" || look.mark == "both" {
            capture = CGImageSourceCreateWithURL(metadataURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                .map(PhotoExportMetadata.from) ?? .init()
        } else {
            capture = .init()
        }
        let image = try configuration.layout.render(developed, metadata: capture, maximumLongEdge: configuration.maximumLongEdge)
        try Task.checkCancellation()
        return try bitmap(image, jpeg: configuration.format == .jpeg8)
    }

    private static func encode(_ raster: DeliveryRaster, source metadataURL: URL,
                               configuration: PhotoBatchExportConfiguration, stage: URL, tagged: URL) throws -> URL {
        try encodePixels(raster, format: configuration.format, quality: configuration.jpegQuality, to: stage)
        let metadata = configuration.metadataPolicy == .none ? nil :
            CGImageSourceCreateWithURL(metadataURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let payload: URL
        if configuration.metadataPolicy != .none, metadata != nil {
            try copyMetadata(from: metadata, policy: configuration.metadataPolicy, gps: configuration.includeGPS, on: stage, to: tagged)
            payload = tagged
        } else {
            payload = stage
        }
        return payload
    }

    /// Encode an already rendered display-linear SDR image using the same embedded-profile codecs as 032.
    /// Source metadata and layout do not participate in this path.
    static func encodeSceneSDRPixels(_ image: CIImage, format: PhotoRenderFormat, to stage: URL, context: CIContext) throws {
        guard format == .jpeg8 || format == .png16 else { throw DevelopmentError.invalidEncoding }
        try encodePixels(bitmap(image, jpeg: format == .jpeg8, context: context), format: format, quality: 0.95, to: stage)
    }

    private static func encodePixels(_ raster: DeliveryRaster, format: PhotoRenderFormat, quality: Double, to stage: URL) throws {
        guard format != .avif10 else { throw DevelopmentError.invalidEncoding }
        let jpeg = format == .jpeg8
        let codec: PhotoExportKernel.Codec = jpeg ? .jpeg : (format == .png16 ? .png : .tiff)
        let size = PhotoExportKernel.Dimensions(width: UInt32(raster.width), height: UInt32(raster.height))
        try raster.bitmap.withUnsafeBytes { bytes in
            try PhotoExportKernel.encode(to: stage, size: size, pixels: bytes, stride: raster.stride,
                pixelFormat: jpeg ? .rgbx8 : .rgba16, codec: codec, quality: UInt8((quality * 100).rounded()))
        }
    }

    private static func bitmap(_ image: CIImage, jpeg: Bool, context: CIContext = bitmapContext) throws -> DeliveryRaster {
        let extent = image.extent
        let (width, height) = (Int(extent.width), Int(extent.height))
        guard width > 0, height > 0, width <= 100_000, height <= 100_000, width * height <= 260_000_000
        else { throw DevelopmentError.invalidGeometry }
        let pixels = jpeg ? image.composited(over: CIImage(color: .white).cropped(to: extent)) : image
        let stride = width * (jpeg ? 4 : 8)
        var bitmap = Data(count: stride * height)
        try bitmap.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw DevelopmentError.invalidEncoding }
            let bandHeight = min(height, max(1, 32 * 1024 * 1024 / stride), 4096)
            let tileWidth = width > 8192 ? 8192 : width
            let bytesPerPixel = jpeg ? 4 : 8
            for row in Swift.stride(from: 0, to: height, by: bandHeight) {
                try Task.checkCancellation()
                let rows = min(bandHeight, height - row)
                for column in Swift.stride(from: 0, to: width, by: tileWidth) {
                    let tile = CGRect(x: column, y: height - row - rows, width: min(tileWidth, width - column), height: rows)
                    context.render(pixels, toBitmap: base.advanced(by: row * stride + column * bytesPerPixel),
                        rowBytes: stride, bounds: tile, format: jpeg ? .RGBA8 : .RGBA16, colorSpace: PhotoRenderer.sRGB)
                }

            }
        }
        return DeliveryRaster(bitmap: bitmap, width: width, height: height, stride: stride)
    }

    /// Replace descriptive tags without recompressing the newly rendered image. ICC and the encoded pixel payload
    /// belong to the output. Never import source orientation, dimensions, thumbnails, serial numbers or edit history.
    private static func copyMetadata(from original: CGImageSource?, policy: PhotoExportMetadataPolicy,
                                     gps: Bool, on pixels: URL, to target: URL) throws {
        let newTags = CGImageMetadataCreateMutable()
        if policy != .none, let original, let originalTags = CGImageSourceCopyMetadataAtIndex(original, 0, nil) {
            func copy(_ dict: CFString, _ keys: [CFString]) throws {
                for key in keys {
                    guard let tag = CGImageMetadataCopyTagMatchingImageProperty(originalTags, dict, key),
                          let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) else { continue }
                    // Retain the tag type, rational and coordinate hemisphere. Bridging an EXIF rational to NSNumber loses precision.
                    guard CGImageMetadataSetTagWithPath(newTags, nil, "\(prefix):\(name)" as CFString, tag)
                    else { throw DevelopmentError.invalidEncoding }
                }
            }
            try copy(kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright])
            try copy(kCGImagePropertyIPTCDictionary, [kCGImagePropertyIPTCByline, kCGImagePropertyIPTCCopyrightNotice,
                                                       kCGImagePropertyIPTCCredit])
            if policy == .photo {
                try copy(kCGImagePropertyTIFFDictionary, [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel])
                try copy(kCGImagePropertyExifDictionary, [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal,
                    kCGImagePropertyExifSubsecTimeOriginal, kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
                    kCGImagePropertyExifFocalLength, kCGImagePropertyExifFocalLenIn35mmFilm, kCGImagePropertyExifFNumber,
                    kCGImagePropertyExifExposureTime, kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifExposureBiasValue])
                if gps {
                    // ImageIO's XMP coordinate tags carry N/S and E/W together with the value.
                    try copy(kCGImagePropertyGPSDictionary, [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLongitude,
                                                            kCGImagePropertyGPSAltitude, kCGImagePropertyGPSAltitudeRef])
                }
            }
        }
        // These containers originate from Rust and contain only output pixels and the sRGB profile.
        guard let source = CGImageSourceCreateWithURL(pixels as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, type, 1, nil) else { throw DevelopmentError.invalidEncoding }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: newTags,
                                        kCGImageMetadataShouldExcludeGPS: !(policy == .photo && gps)]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw DevelopmentError.invalidEncoding
        }
    }

}

extension RenderExportService {
    /// Original capture tags can accompany an archived edit only when the original still identifies the same photo.
    /// Hashes file content and should be called off the main actor.
    public static func captureMetadataURL(work: PhotoWork, version: EditingVersion, archive: EditingArchive) throws -> URL {
        try Task.checkCancellation()
        guard version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidSource }
        do {
            try RenderFiles.verify(version.source)
            return version.source.sourceLocation
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let artifact = version.artifact else { throw error }
            let input = try archive.artifactURL(artifact)
            guard try RenderFiles.hash(input) == artifact.sha256 else { throw EditingError.archiveMismatch }
            return input
        }
    }
}
