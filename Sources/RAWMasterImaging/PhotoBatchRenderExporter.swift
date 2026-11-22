import CoreImage
import Foundation
import ImageIO
import RAWMasterCore
import RAWMasterPhotoExport
import UniformTypeIdentifiers

public struct PhotoBatchExportConfiguration: Equatable, Sendable {
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
        if ["signature", "both"].contains(look.mark), layout.signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EditingError.invalidRecipe
        }
        if ["exif", "both"].contains(look.mark), look.fields.isEmpty { throw EditingError.invalidRecipe }
        if look.mark == "logo", look.logo == nil { throw EditingError.invalidRecipe }
    }
}

public actor PhotoBatchRenderExporter {
    public init() {}

    /// The caller resolves naming tokens and removes the source extension once. A period inside the resulting stem is valid.
    public func export(work: PhotoWork, version: EditingVersion, archive: EditingArchive, directory: URL,
                       filename: String, configuration: PhotoBatchExportConfiguration,
                       protectedURLs: [URL] = []) async throws -> URL {
        try configuration.validate()
        guard version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidSource }
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else { throw EditingError.unsafePath }
        let final = directory.appendingPathComponent(filename).appendingPathExtension(configuration.format.filenameExtension)
        let protected = protectedURLs + [work.source.sourceLocation, version.source.sourceLocation, archive.root]
        try RenderFiles.check(final, protected: protected)
        let temporary = directory.appendingPathComponent(".rawmaster-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stage = temporary.appendingPathComponent("pixels").appendingPathExtension(configuration.format.filenameExtension)
        let look = configuration.layout.resolvedAppearance
        let needsMetadata = look.mark == "exif" || look.mark == "both" || configuration.metadataPolicy != .none
        let tagged = temporary.appendingPathComponent("delivery").appendingPathExtension(configuration.format.filenameExtension)
        let artifactURL = try version.artifact.map { try archive.artifactURL($0) }

        if artifactURL == nil, DevelopmentBrilliancePublicV1.active(version.recipe) {
            // The experimental renderer owns its finite-output transport until that graph is retired.
            let intermediate = temporary.appendingPathComponent("development.tiff")
            _ = try await RenderExportService().export(work: work, version: version, archive: archive, destination: intermediate,
                                                       format: .tiff16, protectedURLs: protected)
            try await renderingTask {
                guard let image = CIImage(contentsOf: intermediate, options: [.applyOrientationProperty: true])
                else { throw DevelopmentError.unreadable }
                try Self.deliverPixels(image, source: version.source.sourceLocation, configuration: configuration,
                    stage: stage, tagged: tagged, final: final, protected: protected)
            }
        } else {
            try await renderingTask {
                if let artifactURL, let artifact = version.artifact {
                    guard try RenderFiles.hash(artifactURL) == artifact.sha256 else { throw EditingError.archiveMismatch }
                    let metadataURL = needsMetadata ? try RenderExportService.captureMetadataURL(
                        work: work, version: version, archive: archive) : artifactURL
                    guard let image = CIImage(contentsOf: artifactURL, options: [.applyOrientationProperty: true])
                    else { throw DevelopmentError.unreadable }
                    try Self.deliverPixels(image, source: metadataURL, configuration: configuration,
                        stage: stage, tagged: tagged, final: final, protected: protected) {
                        guard try RenderFiles.hash(artifactURL) == artifact.sha256 else { throw EditingError.archiveMismatch }
                    }
                    return
                }

                let captured = try RenderFiles.capture(version.source, synchronize: false)
                defer { try? FileManager.default.removeItem(at: captured.deletingLastPathComponent()) }
                if let scene = version.recipe.adjustmentsV3?.effects?.lensBlur?.sceneDepth,
                   scene.sourceSHA256 != version.source.contentSHA256 { throw EditingError.staleSource }
                let ownedContext = version.recipe.adjustmentsV3.map { DevelopmentBrillianceAdaptiveV1.isActive($0.light) } == true
                    ? DevelopmentBrillianceAdaptiveV1.makeContext() : nil
                defer { ownedContext?.clearCaches() }
                let image = try Self.neutralJPEG(captured, version: version, configuration: configuration)
                    ?? PhotoRenderer.develop(captured, version.recipe, context: ownedContext).0
                try Self.deliverPixels(image, source: captured, configuration: configuration,
                    stage: stage, tagged: tagged, final: final, protected: protected) {
                    try RenderFiles.verify(version.source)
                }
            }
        }
        return final
    }

    private static func neutralJPEG(_ url: URL, version: EditingVersion, configuration: PhotoBatchExportConfiguration) -> CIImage? {
        let layout = configuration.layout.resolvedAppearance
        guard version.recipe == DevelopmentRecipe(), configuration.format == .jpeg8,
              layout.frame == "none", layout.mark == "off", let edge = configuration.maximumLongEdge,
              let input = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(input) == UTType.jpeg.identifier as CFString else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary).map { CIImage(cgImage: $0) }
    }

    private static let bitmapContext = CIContext(options: [.cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputPremultiplied: false,
        .workingFormat: CIFormat.RGBAh.rawValue])

    private static func deliverPixels(_ developed: CIImage, source metadataURL: URL,
                                      configuration: PhotoBatchExportConfiguration,
                                      stage: URL, tagged: URL, final: URL, protected: [URL],
                                      verify: () throws -> Void = {}) throws {
        let look = configuration.layout.resolvedAppearance
        let usesCapture = look.mark == "exif" || look.mark == "both"
        let metadata: CGImageSource?
        if usesCapture || configuration.metadataPolicy != .none {
            metadata = CGImageSourceCreateWithURL(metadataURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else { metadata = nil }
        let capture = usesCapture ? metadata.map(PhotoExportMetadata.from) ?? .init() : .init()
        let image = try configuration.layout.render(developed, metadata: capture, maximumLongEdge: configuration.maximumLongEdge)
        try Task.checkCancellation()
        try encode(image, configuration: configuration, to: stage)
        let payload: URL
        if configuration.metadataPolicy != .none, metadata != nil {
            try copyMetadata(from: metadata, policy: configuration.metadataPolicy, gps: configuration.includeGPS, on: stage, to: tagged)
            payload = tagged
        } else {
            payload = stage
        }
        try Task.checkCancellation()
        try verify()
        try RenderFiles.check(final, protected: protected)
        do { try PhotoExportKernel.publish(payload, at: final) }
        catch PhotoExportKernelError.destinationExists { throw DevelopmentError.outputExists }
    }

    private static func encode(_ image: CIImage, configuration: PhotoBatchExportConfiguration, to url: URL) throws {
        let extent = image.extent
        let (width, height) = (Int(extent.width), Int(extent.height))
        guard width > 0, height > 0, width <= 100_000, height <= 100_000, width * height <= 260_000_000
        else { throw DevelopmentError.invalidGeometry }
        let jpeg = configuration.format == .jpeg8
        let codec: PhotoExportKernel.Codec = jpeg ? .jpeg : (configuration.format == .png16 ? .png : .tiff)
        let pixels = jpeg ? image.composited(over: CIImage(color: .white).cropped(to: extent)) : image
        let stride = width * (jpeg ? 4 : 8)
        let size = PhotoExportKernel.Dimensions(width: UInt32(width), height: UInt32(height))
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
                    bitmapContext.render(pixels, toBitmap: base.advanced(by: row * stride + column * bytesPerPixel),
                        rowBytes: stride, bounds: tile, format: jpeg ? .RGBA8 : .RGBA16, colorSpace: PhotoRenderer.sRGB)
                }

            }
        }
        try bitmap.withUnsafeBytes { bytes in
            try PhotoExportKernel.encode(to: url, size: size, pixels: bytes, stride: stride,
                pixelFormat: jpeg ? .rgbx8 : .rgba16, codec: codec, quality: UInt8((configuration.jpegQuality * 100).rounded()))
        }
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
