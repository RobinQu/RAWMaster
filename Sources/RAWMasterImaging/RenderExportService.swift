import CoreImage
import RAWMasterCore
import Foundation

public actor RenderExportService {
  public init() {}
  public func export(work: PhotoWork, version: EditingVersion, archive: EditingArchive, destination: URL, format: PhotoRenderFormat, protectedURLs: [URL] = [], preparePublication: RenderPublicationPreparation? = nil) async throws -> RenderedPhoto {
    guard version.workID == work.id, version.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidSource }
    let protected = protectedURLs + [work.source.sourceLocation, archive.root]
    if version.recipe.sceneGraph != nil {
      let rendition: DevelopmentSceneDeliveryV1.Format
      switch format {
      case .jpeg8: rendition = .jpeg8
      case .png16: rendition = .png16
      case .avif10: rendition = .avif10
      case .tiff16: throw DevelopmentError.unsupportedEngine
      }
      let ticket = try DevelopmentSceneDeliveryV1(work: work, version: version, format: rendition)
      let receipt = try await DevelopmentSceneDeliveryServiceV1.export(ticket, to: destination,
        protectedURLs: protected, preparePublication: preparePublication)
      return RenderedPhoto(fileURL: destination, artifact: receipt.artifact)
    }
    if let artifact = version.artifact {
      let input = try archive.artifactURL(artifact)
      return try await renderingTask(lane: .export) {
        guard try RenderFiles.hash(input) == artifact.sha256 else { throw EditingError.archiveMismatch }
        guard let image = CIImage(contentsOf: input, options: [.applyOrientationProperty: true]) else { throw DevelopmentError.unreadable }
        let preparation: RenderPublicationPreparation?
        if let callback = preparePublication {
          preparation = { stage, target, metadata in
            var frozen = metadata
            frozen.nativePixelWidth = artifact.nativePixelWidth; frozen.nativePixelHeight = artifact.nativePixelHeight
            frozen.resamplingChain = artifact.resamplingChain
            try callback(stage, target, frozen)
          }
        } else { preparation = nil }
        var output = try PhotoRenderer.write(image, format: format, destination: destination, protectedURLs: protected, sourceDepth: artifact.sourceEffectiveBitDepth, preparePublication: preparation,
          beforePublish: { guard try RenderFiles.hash(input) == artifact.sha256 else { throw EditingError.archiveMismatch } })
        var metadata = output.artifact
        metadata.nativePixelWidth = artifact.nativePixelWidth; metadata.nativePixelHeight = artifact.nativePixelHeight
        metadata.resamplingChain = artifact.resamplingChain
        output = RenderedPhoto(fileURL: output.fileURL, artifact: metadata)
        return output
      }
    }
    let graph = try DevelopmentCompatibilityGraphV1(version)
    return try await DevelopmentService().render(source: graph.source, recipe: graph.recipe, format: format, destination: destination, protectedURLs: protected, preparePublication: preparePublication)
  }
}
