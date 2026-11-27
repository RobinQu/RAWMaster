import AppKit
import CoreImage
import ImageIO
import RAWMasterCore

extension RenderExportService {
    /// Requested only by the library's 1:1 viewer. Scene delivery supplies the full, color-managed SDR derivative.
    public func fullResolutionPreview(work: PhotoWork, version: EditingVersion, archive: EditingArchive) async throws -> CGImage {
        guard version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidSource }
        if version.recipe.sceneGraph != nil {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("preview.png")
            _ = try await export(work: work, version: version, archive: archive, destination: url, format: .png16)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw DevelopmentError.unreadable
            }
            return image
        }
        if let artifact = version.artifact {
            return try await preview(work: work, version: version, archive: archive, maxPixel: max(artifact.pixelWidth, artifact.pixelHeight)).image
        }
        let frame = try await DevelopmentService().preview(source: work.source, recipe: version.recipe, maxPixel: 0)
        guard let image = frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DevelopmentError.unreadable }
        return image
    }

    public func preview(work: PhotoWork, version: EditingVersion, archive: EditingArchive, maxPixel: Int) async throws -> (image: CGImage, metadata: PhotoExportMetadata) {
        guard maxPixel > 0, version.workID == work.id, version.source.hasSameIdentity(as: work.source) else {
            throw EditingError.invalidSource
        }
        let metadata = try await renderingTask {
            let url = try Self.captureMetadataURL(work: work, version: version, archive: archive)
            return PhotoExportMetadata.read(from: url)
        }
        if let graph = version.recipe.sceneGraph {
            let frame = try await DevelopmentScenePreviewV1().render(source: version.source, graph: graph, view: .init(),
                target: .sdr709, sampling: .fit(maximumEdge: min(2400, max(64, maxPixel))))
            let image = try await renderingTask {
                let image = try DevelopmentSceneDeliveryServiceV1.linearSDRImage(frame.texture)
                let context = CIContext(mtlDevice: frame.texture.device)
                guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB) else {
                    throw DevelopmentError.unreadable
                }
                return cg
            }
            return (image, metadata)
        }
        if let artifact = version.artifact {
            let url = try archive.artifactURL(artifact)
            let image = try await renderingTask {
                guard try RenderFiles.hash(url) == artifact.sha256 else { throw EditingError.archiveMismatch }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
                guard let input = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { throw DevelopmentError.unreadable }
                return image
            }
            return (image, metadata)
        }
        let frame = try await DevelopmentService().preview(source: work.source, recipe: version.recipe, maxPixel: maxPixel)
        guard let image = frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DevelopmentError.unreadable }
        return (image, metadata)
    }
}
