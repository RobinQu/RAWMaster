import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import RAWMasterCore
import UniformTypeIdentifiers

/// Top-left, row-major, linear coverage. Every preview, brush, and archive uses these bytes.
public struct DevelopmentMaskBitmap: Equatable, Sendable {
  public let width, height: Int
  public private(set) var values: [UInt8]

  public init(width: Int, height: Int, values: [UInt8]) throws {
    guard (1...1536).contains(width), (1...1536).contains(height), values.count == width * height
    else {
      throw EditingError.invalidRecipe
    }
    self.width = width
    self.height = height
    self.values = values
  }

  public init(layer: DevelopmentMaskLayerV3) throws {
    try layer.validate()
    guard let png = layer.subjectPNG, let src = CGImageSourceCreateWithData(png as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
      let w = properties[kCGImagePropertyPixelWidth] as? Int,
      let h = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...1536).contains(w), (1...1536).contains(h)
    else { throw EditingError.invalidRecipe }
    if layer.semanticSnapshot != nil, let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
      image.bitsPerPixel == 8, image.bitsPerComponent == 8, let data = image.dataProvider?.data,
      let pointer = CFDataGetBytePtr(data), CFDataGetLength(data) >= image.bytesPerRow * h
    {
      var values = [UInt8]()
      values.reserveCapacity(w * h)
      for y in 0..<h {
        values.append(
          contentsOf: UnsafeBufferPointer(start: pointer + y * image.bytesPerRow, count: w))
      }
      try self.init(width: w, height: h, values: values)
    } else {
      guard
        let image = CIImage(
          data: png, options: layer.semanticSnapshot == nil ? [:] : [.colorSpace: NSNull()])
      else {
        throw EditingError.invalidRecipe
      }
      try self.init(coverage: image, width: w, height: h)
    }
  }

  init(coverage: CIImage, width: Int, height: Int) throws {
    let scaled = coverage.transformed(
      by: .init(translationX: -coverage.extent.minX, y: -coverage.extent.minY)
    )
    .transformed(
      by: .init(
        scaleX: CGFloat(width) / coverage.extent.width, y: CGFloat(height) / coverage.extent.height)
    )
    var bytes = [UInt8](repeating: 0, count: width * height)
    try bytes.withUnsafeMutableBytes { buffer in
      let destination = CIRenderDestination(
        bitmapData: buffer.baseAddress!, width: width, height: height, bytesPerRow: width,
        format: .L8)
      destination.colorSpace = nil
      destination.isFlipped = true
      destination.isDithered = false
      _ = try CIContext(options: [.cacheIntermediates: false]).startTask(
        toRender: scaled, from: CGRect(x: 0, y: 0, width: width, height: height), to: destination,
        at: .zero
      ).waitUntilCompleted()
    }
    try self.init(width: width, height: height, values: bytes)
  }

  public func png() throws -> Data {
    let output = NSMutableData()
    guard let provider = CGDataProvider(data: Data(values) as CFData),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
        shouldInterpolate: true, intent: .defaultIntent),
      let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw EditingError.invalidRecipe
    }
    CGImageDestinationAddImage(
      dest, image,
      [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0]] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw EditingError.invalidRecipe }
    return output as Data
  }

  public mutating func paint(
    from start: DevelopmentSourcePoint, to end: DevelopmentSourcePoint, diameter: Double,
    adding: Bool
  ) {
    guard diameter.isFinite, diameter > 0, (try? start.validate()) != nil,
      (try? end.validate()) != nil
    else { return }
    let radius = max(1, min(0.5, diameter) * Double(min(width, height)) / 2)
    let ax = start.x * Double(width)
    let ay = start.y * Double(height)
    let bx = end.x * Double(width)
    let by = end.y * Double(height)
    let dx = bx - ax
    let dy = by - ay
    let length = dx * dx + dy * dy
    let x0 = max(0, Int(floor(min(ax, bx) - radius - 1)))
    let x1 = min(width - 1, Int(ceil(max(ax, bx) + radius + 1)))
    let y0 = max(0, Int(floor(min(ay, by) - radius - 1)))
    let y1 = min(height - 1, Int(ceil(max(ay, by) + radius + 1)))
    guard x0 <= x1, y0 <= y1 else { return }
    for y in y0...y1 {
      for x in x0...x1 {
        let px = Double(x) + 0.5 - ax
        let py = Double(y) + 0.5 - ay
        let t = length > 0 ? min(1, max(0, (px * dx + py * dy) / length)) : 0
        let distance = hypot(px - t * dx, py - t * dy)
        let ink = UInt8((255 * min(1, max(0, radius + 0.5 - distance))).rounded())
        let i = y * width + x
        values[i] = adding ? max(values[i], ink) : min(values[i], 255 - ink)
      }
    }
  }

  /// Uses the same inverse geometry as the pointer, including projective transforms and EXIF.
  public func overlay(
    mapping: DevelopmentGeometryMappingV3, inverted: Bool, opacity: Double, maximumEdge: Int = 512
  ) throws -> CGImage {
    guard (1...1536).contains(maximumEdge), opacity.isFinite, (0...1).contains(opacity) else {
      throw EditingError.invalidRecipe
    }
    let inverse = try mapping.inverseMatrix
    let scale = min(
      1, Double(maximumEdge) / Double(max(mapping.outputSize.width, mapping.outputSize.height)))
    let w = max(1, Int((Double(mapping.outputSize.width) * scale).rounded()))
    let h = max(1, Int((Double(mapping.outputSize.height) * scale).rounded()))
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
      if y % 16 == 0 { try Task.checkCancellation() }
      for x in 0..<w {
        let px = (Double(x) + 0.5) * Double(mapping.outputSize.width) / Double(w)
        let py = (Double(y) + 0.5) * Double(mapping.outputSize.height) / Double(h)
        let z = inverse[6] * px + inverse[7] * py + inverse[8]
        guard abs(z) > 1e-12 else { continue }
        let sx =
          (inverse[0] * px + inverse[1] * py + inverse[2]) / (z * Double(mapping.sourceSize.width))
        let sy =
          (inverse[3] * px + inverse[4] * py + inverse[5]) / (z * Double(mapping.sourceSize.height))
        guard (0...1).contains(sx), (0...1).contains(sy) else { continue }
        if let projective = mapping.projective {
          let pre = projective.prePerspectiveMatrix
          let clip = projective.intermediateClip
          let nx = sx * Double(mapping.sourceSize.width)
          let ny = sy * Double(mapping.sourceSize.height)
          let qz = pre[6] * nx + pre[7] * ny + pre[8]
          guard abs(qz) > 1e-12 else { continue }
          let qx = (pre[0] * nx + pre[1] * ny + pre[2]) / qz
          let qy = (pre[3] * nx + pre[4] * ny + pre[5]) / qz
          guard qx >= clip.x, qy >= clip.y, qx <= clip.x + clip.width, qy <= clip.y + clip.height
          else { continue }
        }
        let ix = min(Double(width - 1), max(0, sx * Double(width) - 0.5))
        let iy = min(Double(height - 1), max(0, sy * Double(height) - 0.5))
        let x0 = Int(ix)
        let y0 = Int(iy)
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let dx = ix - Double(x0)
        let dy = iy - Double(y0)
        let top = (1 - dx) * Double(values[y0 * width + x0]) + dx * Double(values[y0 * width + x1])
        let bottom =
          (1 - dx) * Double(values[y1 * width + x0]) + dx * Double(values[y1 * width + x1])
        let value = (1 - dy) * top + dy * bottom
        let a = UInt8((min(255, max(0, inverted ? 255 - value : value)) * opacity * 0.58).rounded())
        let i = (y * w + x) * 4
        bytes[i] = a
        bytes[i + 1] = a / 6
        bytes[i + 2] = a / 4
        bytes[i + 3] = a
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
      let result = CGImage(
        width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * w,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { throw EditingError.invalidRecipe }
    return result
  }
}
