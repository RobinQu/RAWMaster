import CoreImage
import RAWMasterCore

/// The historical CIContext and the V3 F32 context can quantize the same protected input
/// differently. Select the historical sample after both graphs' original color conversions,
/// so adopting, disabling or removing the first semantic layer preserves the stored channel codes.
struct DevelopmentLegacyMaskOutput {
  private let reference: CIImage
  private let coverage: CIImage
  private let historicalContext: CIContext
  private static let matteContext = CIContext(options: [
    .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
    .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false
  ])

  static func make(capture: URL, recipe: DevelopmentRecipe, extent: CGRect, format: PhotoRenderFormat) throws -> Self? {
    guard var parameters = recipe.adjustmentsV3, parameters.rawDecoder == nil,
          parameters.geometry.version == .legacyV1 || parameters.geometry.version == .legacyV2 else { return nil }
    let layers = parameters.masks.filter { $0.semanticSnapshot != nil && $0.enabled && $0.opacity > 0 && !$0.adjustments.isNeutral }
    guard let source = layers.first?.semanticSnapshot?.source else { return nil }
    parameters.masks.removeAll { $0.semanticSnapshot != nil }
    var baseline = recipe
    baseline.adjustmentsV3 = parameters
    guard let legacy = try DevelopmentRendererV3.legacyEquivalent(baseline) else { return nil }

    let input = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: source.orientedWidth, height: source.orientedHeight))
    var union: CIImage?
    for layer in layers {
      let selection = DevelopmentMaskEngineV3.ScopeSelection(layer)
      try selection.capture(input)
      guard let coverage = selection.coverage else { throw DevelopmentV3Error.invalidGraph }
      union = union.map { $0.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: coverage]) } ?? coverage
    }
    guard let union else { throw DevelopmentV3Error.invalidGraph }
    let coverage = try PhotoRenderer.applyV2Geometry(union, legacy)
    var (reference, _) = try PhotoRenderer.develop(capture, legacy)
    guard coverage.extent == extent, reference.extent == extent else { throw DevelopmentV3Error.invalidGraph }
    if format == .jpeg8 { reference = reference.composited(over: CIImage(color: .white).cropped(to: extent)) }
    return Self(reference: reference, coverage: coverage, historicalContext: PhotoRenderer.renderingContext(legacy))
  }

  /// The destination already holds the edited output in top-first, unassociated integer samples.
  /// Keep the secondary matte/reference scratch bounded even for a large native TIFF.
  func restore(buffer: UnsafeMutableRawPointer, rowBytes: Int, top: Int, rows: Int, format: PhotoRenderFormat, colorSpace: CGColorSpace) throws {
    let bytesPerPixel = format == .jpeg8 ? 4 : 8
    let width = Int(reference.extent.width)
    for bandTop in stride(from: top, to: top + rows, by: 64) {
      let height = min(64, top + rows - bandTop)
      for x in stride(from: 0, to: width, by: 1536) {
        try Task.checkCancellation()
        try autoreleasepool {
          let w = min(1536, width - x), count = w * height
          let rect = CGRect(x: reference.extent.minX + CGFloat(x), y: reference.extent.maxY - CGFloat(bandTop + height),
                            width: CGFloat(w), height: CGFloat(height))
          var mask = [Float](repeating: 0, count: count)
          try mask.withUnsafeMutableBytes {
            try Self.render(coverage, in: rect, into: $0.baseAddress!, rowBytes: w * MemoryLayout<Float>.stride,
                            context: Self.matteContext, format: .Rf, colorSpace: nil)
          }
          guard mask.contains(0) else { return }
          let destination = buffer.advanced(by: (bandTop - top) * rowBytes + x * bytesPerPixel)
          let storage: CIFormat = format == .jpeg8 ? .RGBA8 : .RGBA16
          if !mask.contains(where: { $0 != 0 }) {
            try Self.render(reference, in: rect, into: destination, rowBytes: rowBytes,
                            context: historicalContext, format: storage, colorSpace: colorSpace)
            return
          }
          let referenceStride = w * bytesPerPixel
          var pixels = [UInt8](repeating: 0, count: referenceStride * height)
          try pixels.withUnsafeMutableBytes { original in
            let base = original.baseAddress!
            try Self.render(reference, in: rect, into: base, rowBytes: referenceStride,
                            context: historicalContext, format: storage, colorSpace: colorSpace)
            for y in 0..<height {
              var column = 0
              while column < w {
                let start = column
                while column < w, mask[y * w + column] == 0 { column += 1 }
                if start < column {
                  let offset = start * bytesPerPixel
                  destination.advanced(by: y * rowBytes + offset).copyMemory(
                    from: base.advanced(by: y * referenceStride + offset), byteCount: (column - start) * bytesPerPixel)
                }
                while column < w, mask[y * w + column] != 0 { column += 1 }
              }
            }
          }
        }
      }
    }
  }

  private static func render(_ image: CIImage, in rect: CGRect, into address: UnsafeMutableRawPointer, rowBytes: Int,
                             context: CIContext, format: CIFormat, colorSpace: CGColorSpace?) throws {
    let destination = CIRenderDestination(bitmapData: address, width: Int(rect.width), height: Int(rect.height),
                                          bytesPerRow: rowBytes, format: format)
    destination.colorSpace = colorSpace
    destination.alphaMode = .unpremultiplied
    destination.isFlipped = true
    destination.isClamped = true
    destination.isDithered = false
    let task = try context.startTask(toRender: image, from: rect, to: destination, at: .zero)
    do { _ = try task.waitUntilCompleted() }
    catch { let failure = error; _ = try? task.waitUntilCompleted(); throw failure }
  }
}
