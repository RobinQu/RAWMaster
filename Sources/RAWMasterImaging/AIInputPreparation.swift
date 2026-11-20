import Foundation
import CoreImage
import RAWMasterCore

extension DevelopmentService {
  /// A distinct provider input, never substituted for full-resolution development/export bytes.
  public func prepareAIInput(work: PhotoWork, version: EditingVersion, archive: EditingArchive, destination: URL, maxPixels: Int = 1_048_576) async throws -> RenderedPhoto {
    guard version.workID == work.id, version.source.hasSameIdentity(as: work.source), (1...16_777_216).contains(maxPixels) else { throw EditingError.invalidSource }
    return try await renderingTask {
      let renderContext = version.artifact == nil ? PhotoRenderer.renderingContext(version.recipe) : PhotoRenderer.context
      let original: CIImage
      let sourceDepth: Int?
      let priorChain: [String]
      let nativeWidth: Int, nativeHeight: Int
      var capture = version.source
      if let artifact = version.artifact {
        capture.sourceLocation = try archive.artifactURL(artifact); capture.contentSHA256 = artifact.sha256; capture.byteCount = artifact.byteCount
        let copied = try RenderFiles.capture(capture); defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        guard let decoded = CIImage(contentsOf: copied, options: [.applyOrientationProperty: true]) else { throw DevelopmentError.unreadable }
        // Materialize this immutable captured image before removing its backing file.
        guard let cg = renderContext.createCGImage(decoded, from: decoded.extent, format: .RGBA16, colorSpace: PhotoRenderer.sRGB, deferred:false) else { throw DevelopmentError.unreadable }
        original = CIImage(cgImage: cg)
        sourceDepth = artifact.sourceEffectiveBitDepth
        priorChain = artifact.resamplingChain; nativeWidth = artifact.nativePixelWidth; nativeHeight = artifact.nativePixelHeight
      } else {
        let copied = try RenderFiles.capture(capture); defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        let (decoded, depth) = try PhotoRenderer.develop(copied, version.recipe)
        guard let cg = renderContext.createCGImage(decoded, from: decoded.extent, format: .RGBA16, colorSpace: PhotoRenderer.sRGB, deferred:false) else { throw DevelopmentError.unreadable }
        original = CIImage(cgImage: cg); sourceDepth = depth
        nativeWidth = Int(original.extent.width); nativeHeight = Int(original.extent.height)
        priorChain = version.recipe.straightenDegrees == 0 ? [] : ["CoreImage straighten \(version.recipe.straightenDegrees) degrees; inscribed crop"]
      }
      let factor = min(1, sqrt(Double(maxPixels) / (original.extent.width * original.extent.height)))
      var image = original
      var chain = priorChain
      if factor < 1 {
        let width = max(1, Int(floor(original.extent.width * factor))), height = max(1, Int(floor(original.extent.height * factor)))
        image = original.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
          .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        chain.append("Lanczos downsample \(Int(original.extent.width))x\(Int(original.extent.height))->\(width)x\(height); maxPixels=\(maxPixels)")
      }
      image = image.composited(over: CIImage(color: .white).cropped(to: image.extent))
      let protected = [work.source.sourceLocation, archive.root]
      try RenderFiles.check(destination, protected: protected)
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let stage = destination.deletingLastPathComponent().appendingPathComponent(".rawmaster-ai-input-\(UUID().uuidString).png")
      defer { try? FileManager.default.removeItem(at: stage) }
      try renderContext.writePNGRepresentation(of: image, to: stage, format: .RGBA8, colorSpace: PhotoRenderer.sRGB)
      var artifact = try PhotoRenderer.inspect(stage, sourceDepth: sourceDepth)
      guard artifact.bitDepth == 8, artifact.pixelWidth * artifact.pixelHeight <= maxPixels, artifact.iccProfileSHA256 != nil else { throw DevelopmentError.invalidEncoding }
      artifact.alphaPolicy = .compositedWhite; artifact.nativePixelWidth = nativeWidth; artifact.nativePixelHeight = nativeHeight; artifact.resamplingChain = chain
      try Task.checkCancellation(); try RenderFiles.verify(capture); try RenderFiles.check(destination, protected: protected)
      try FileManager.default.moveItem(at: stage, to: destination)
      return RenderedPhoto(fileURL: destination, artifact: artifact)
    }
  }
}
