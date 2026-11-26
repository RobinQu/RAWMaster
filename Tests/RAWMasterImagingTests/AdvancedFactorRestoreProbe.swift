import XCTest
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

/// Decisive PoC for the operator split: keep Core Image's Gaussian guides, but materialize the
/// per-pixel band factor once and apply it with a pointwise restore. If the restore is exact over
/// a window, amount changes and 1:1 pans stop re-running the Gaussian/band graph.
final class AdvancedFactorRestoreProbe: XCTestCase {
  private func context() -> CIContext {
    CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 768])
  }
  private func source() throws -> CIImage {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["RAWMASTER_REGION_PROBE_SOURCE"] {
      let url = URL(fileURLWithPath: path)
      if let image = try? FlashRawImageFactory.linearImage(capture: url) { return image }
      if let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage, !image.extent.isEmpty {
        return image
      }
    }
    let width = 4000, height = 3000
    var pixels = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        let edge = ((x / 9) + (y / 7)) % 2 == 0
        pixels[i] = edge ? 0.7 : 0.08
        pixels[i + 1] = Float(x) / Float(width)
        pixels[i + 2] = Float(y) / Float(height)
        pixels[i + 3] = 1
      }
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    return try XCTUnwrap(CIImage(bitmapData: data, bytesPerRow: width * 16,
      size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil))
  }
  private func freeze(_ image: CIImage, from rect: CGRect, using shared: CIContext? = nil) throws -> [Float] {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: Int(rect.width), height: Int(rect.height), mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = DevelopmentColorEngineV3.linearSRGB
    destination.alphaMode = .premultiplied
    destination.isFlipped = false
    let renderer = shared ?? context()
    let task = try renderer.startTask(toRender: image, from: rect, to: destination, at: .zero)
    _ = try task.waitUntilCompleted()
    var values = [Float](repeating: .nan, count: Int(rect.width) * Int(rect.height) * 4)
    values.withUnsafeMutableBytes { raw in
      texture.getBytes(raw.baseAddress!, bytesPerRow: Int(rect.width) * 16,
        from: MTLRegionMake2D(0, 0, Int(rect.width), Int(rect.height)), mipmapLevel: 0)
    }
    return values
  }
  private func freezeTexture(_ image: CIImage, from rect: CGRect) throws -> CIImage {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: Int(rect.width), height: Int(rect.height), mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = DevelopmentColorEngineV3.linearSRGB
    destination.alphaMode = .premultiplied
    destination.isFlipped = false
    let renderer = context()
    let task = try renderer.startTask(toRender: image, from: rect, to: destination, at: .zero)
    _ = try task.waitUntilCompleted()
    retained.append(texture)
    let drawn = try XCTUnwrap(CIImage(mtlTexture: texture,
      options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB]))
    return drawn.transformed(by: .init(translationX: rect.minX, y: rect.minY))
  }
  private var retained: [MTLTexture] = []
  private func compare(_ a: [Float], _ b: [Float]) -> (max: Float, differing: Int) {
    var maxDiff: Float = 0, differing = 0
    for i in 0..<min(a.count, b.count) {
      let x = a[i], y = b[i]
      guard x.isFinite, y.isFinite else { differing += 1; continue }
      let diff = abs(x - y)
      if diff > 0 { differing += 1; maxDiff = max(maxDiff, diff) }
    }
    return (maxDiff, differing)
  }
  private func elapsed(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
  }

  func testFactorRestoreIsExactAndWindowRestoreIsPointwise() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_FACTOR_PROBE"] == "1",
                      "Explicit probe opt-in is required")
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let input = try source()
    let extent = input.extent
    let size = DevelopmentPixelSize(width: Int(extent.width), height: Int(extent.height))
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize: size)
    let window = CGRect(x: (extent.width * 0.31).rounded(), y: (extent.height * 0.27).rounded(),
                        width: min(2400, extent.width - 100), height: min(1600, extent.height - 100))
    print("FACTOR-PROBE source=\(Int(extent.width))x\(Int(extent.height)) window=\(Int(window.width))x\(Int(window.height))")
    for (band, radius, amount) in [(DevelopmentAdvancedDetailEngineV3.Band.texture, radii.texture, 25.0),
                                   (.clarity, radii.clarity, 40.0)] {
      let factor = try DevelopmentAdvancedDetailEngineV3.bandFactor(input, radius: radius)
      let inline = try DevelopmentAdvancedDetailEngineV3.applyBand(band, amount: amount, to: input, radius: radius)
      let restored = try DevelopmentAdvancedDetailEngineV3.applyBand(band, amount: amount, to: input, factor: factor)
      let wholeInline = try freeze(inline, from: extent)
      let wholeRestored = try freeze(restored, from: extent)
      let wholeDiff = compare(wholeInline, wholeRestored)
      let windowRestored = try DevelopmentAdvancedDetailEngineV3.applyBandWindow(
        band, amount: amount, to: input, factor: factor, extent: window)
      let crop = try freeze(restored, from: window)
      let windowValues = try freeze(windowRestored, from: window)
      let windowDiff = compare(crop, windowValues)
      print("FACTOR-PROBE band=\(band) inline-vs-restore max=\(wholeDiff.max) differing=\(wholeDiff.differing)/\(wholeRestored.count)")
      print("FACTOR-PROBE band=\(band) window-vs-crop max=\(windowDiff.max) differing=\(windowDiff.differing)/\(windowValues.count)")

      // Amount changes should be restore-only. Freeze the factor once, then time three
      // windowed restores against three full inline band evaluations.
      let frozen = try freezeTexture(factor, from: extent)
      let timingContext = context()
      let restoreMs = try elapsed {
        for value in [15.0, 35.0, 55.0] {
          let rendered = try DevelopmentAdvancedDetailEngineV3.applyBandWindow(
            band, amount: value, to: input, factor: frozen, extent: window)
          _ = try freeze(rendered, from: window, using: timingContext)
        }
      } / 3
      let inlineMs = try elapsed {
        for value in [15.0, 35.0, 55.0] {
          let rendered = try DevelopmentAdvancedDetailEngineV3.applyBand(
            band, amount: value, to: input, radius: radius)
          _ = try freeze(rendered, from: window, using: timingContext)
        }
      } / 3
      let factorMs = try elapsed {
        let computed = try DevelopmentAdvancedDetailEngineV3.bandFactor(input, radius: radius)
        _ = try freeze(computed, from: extent, using: timingContext)
      }
      let inlineFullMs = try elapsed {
        for value in [15.0, 35.0, 55.0] {
          let rendered = try DevelopmentAdvancedDetailEngineV3.applyBand(
            band, amount: value, to: input, radius: radius)
          _ = try freeze(rendered, from: extent, using: timingContext)
        }
      } / 3
      let restoreFullMs = try elapsed {
        for value in [15.0, 35.0, 55.0] {
          let rendered = try DevelopmentAdvancedDetailEngineV3.applyBand(
            band, amount: value, to: input, factor: frozen)
          _ = try freeze(rendered, from: extent, using: timingContext)
        }
      } / 3
      print("FACTOR-PROBE band=\(band) factorFull=\(String(format: "%.1f", factorMs))ms inlineFull=\(String(format: "%.1f", inlineFullMs))ms restoreFull=\(String(format: "%.1f", restoreFullMs))ms inlineWindow=\(String(format: "%.1f", inlineMs))ms restoreWindow=\(String(format: "%.1f", restoreMs))ms")
      XCTAssertEqual(wholeDiff.max, 0, "factor/restore must match the inline band")
      XCTAssertEqual(windowDiff.max, 0, "windowed restore must match the crop")
    }

    // The real sequence applies clarity to the texture result, so its factor is computed from
    // the restored texture output, not from the original input.
    let textureFactor = try DevelopmentAdvancedDetailEngineV3.bandFactor(input, radius: radii.texture)
    let textureRestored = try DevelopmentAdvancedDetailEngineV3.applyBand(
      .texture, amount: 25, to: input, factor: textureFactor)
    let clarityFactor = try DevelopmentAdvancedDetailEngineV3.bandFactor(
      textureRestored, radius: radii.clarity)
    let restoredPair = try DevelopmentAdvancedDetailEngineV3.applyBand(
      .clarity, amount: 40, to: textureRestored, factor: clarityFactor)
    let inlineTexture = try DevelopmentAdvancedDetailEngineV3.applyBand(
      .texture, amount: 25, to: input, radius: radii.texture)
    let inlinePair = try DevelopmentAdvancedDetailEngineV3.applyBand(
      .clarity, amount: 40, to: inlineTexture, radius: radii.clarity)
    let pairDiff = compare(try freeze(inlinePair, from: extent), try freeze(restoredPair, from: extent))
    print("FACTOR-PROBE sequence texture25+clarity40 max=\(pairDiff.max) differing=\(pairDiff.differing)")
    XCTAssertEqual(pairDiff.max, 0, "the factor/restore sequence must match the inline bands")
  }

  /// If the guide Gaussian is local with a sufficient halo, computing the factor only over
  /// window+halo and restoring only the window must equal the full-frame crop. This is the
  /// difference between "factor/restore" and "windowed factor/restore", and the only route to
  /// skipping the 60 MP materialize for 1:1.
  func testWindowFactorAndRestoreAreByteExact() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_FACTOR_PROBE"] == "1",
                      "Explicit probe opt-in is required")
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let input = try source()
    let extent = input.extent
    let size = DevelopmentPixelSize(width: Int(extent.width), height: Int(extent.height))
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize: size)
    let window = CGRect(x: (extent.width * 0.31).rounded(), y: (extent.height * 0.27).rounded(),
                        width: min(2400, extent.width - 100), height: min(1600, extent.height - 100))
    for (band, radius, amount) in [(DevelopmentAdvancedDetailEngineV3.Band.texture, radii.texture, 25.0),
                                   (.clarity, radii.clarity, 40.0)] {
      let fullFactor = try DevelopmentAdvancedDetailEngineV3.bandFactor(input, radius: radius)
      let halo = CGFloat((radius * 12).rounded(.up) + 8)
      let region = window.insetBy(dx: -halo, dy: -halo).intersection(extent)
      let regional = input.cropped(to: region)
      let regionalFactor = try DevelopmentAdvancedDetailEngineV3.bandFactor(regional, radius: radius)
      let factorCrop = try freeze(fullFactor, from: window)
      let factorWindow = try freeze(regionalFactor, from: window)
      let factorDiff = compare(factorCrop, factorWindow)

      let fullRestored = try DevelopmentAdvancedDetailEngineV3.applyBand(
        band, amount: amount, to: input, factor: fullFactor)
      let fullCrop = try freeze(fullRestored, from: window)
      let windowRestored = try DevelopmentAdvancedDetailEngineV3.applyBandWindow(
        band, amount: amount, to: input, factor: regionalFactor, extent: window)
      let windowValues = try freeze(windowRestored, from: window)
      let restoreDiff = compare(fullCrop, windowValues)
      print("FACTOR-PROBE window-local band=\(band) halo=\(Int(halo)) factor max=\(factorDiff.max) differing=\(factorDiff.differing)/\(factorWindow.count)")
      print("FACTOR-PROBE window-local band=\(band) restore max=\(restoreDiff.max) differing=\(restoreDiff.differing)/\(windowValues.count)")

      let timingContext = context()
      let factorMs = try elapsed {
        _ = try freeze(regionalFactor, from: region, using: timingContext)
      }
      let restoreMs = try elapsed {
        for value in [15.0, 35.0, 55.0] {
          let rendered = try DevelopmentAdvancedDetailEngineV3.applyBandWindow(
            band, amount: value, to: input, factor: regionalFactor, extent: window)
          _ = try freeze(rendered, from: window, using: timingContext)
        }
      } / 3
      print("FACTOR-PROBE window-local band=\(band) factorRegion=\(String(format: "%.1f", factorMs))ms restoreWindow=\(String(format: "%.1f", restoreMs))ms")
      XCTAssertEqual(factorDiff.max, 0, "window-local factor must match the full factor crop")
      XCTAssertEqual(restoreDiff.max, 0, "window-local restore must match the full restore crop")
    }
  }
}
