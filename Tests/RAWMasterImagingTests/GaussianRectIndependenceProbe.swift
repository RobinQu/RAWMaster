import XCTest
import CoreImage
import Metal
@testable import RAWMasterImaging

/// Is `CIGaussianBlur` a function of its input alone, or of the rectangle you ask for?
///
/// `DevelopmentAdvancedDetailEngineV3` materializes the whole extent before handing the result
/// on, with the comment that this stops Core Image from choosing a different Gaussian path per
/// destination rect. If that is true, a windowed 1:1 frame can never match the whole-frame
/// result without replacing the blur. If it is false, the materialize is only a cache and the
/// windowed path can drop it.
final class GaussianRectIndependenceProbe: XCTestCase {
  private func context() -> CIContext {
    CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 256])
  }

  /// Deterministic RGBA32F pattern with high-contrast edges so a path change cannot hide.
  private func source(width: Int, height: Int) throws -> CIImage {
    var pixels = [Float](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let i = (y * width + x) * 4
        let checker = ((x / 7) + (y / 5)) % 2 == 0
        pixels[i] = checker ? 0.9 : 0.05
        pixels[i + 1] = Float(x) / Float(width)
        pixels[i + 2] = Float(y) / Float(height)
        pixels[i + 3] = 1
      }
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    return try XCTUnwrap(CIImage(bitmapData: data, bytesPerRow: width * 16,
      size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil))
  }

  private func read(_ image: CIImage, from rect: CGRect, context: CIContext) throws -> [Float] {
    var buffer = [Float](repeating: .nan, count: Int(rect.width) * Int(rect.height) * 4)
    try buffer.withUnsafeMutableBytes { raw in
      let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
      guard let ci = context.createCGImage(image, from: rect, format: .RGBAf,
                                           colorSpace: space, deferred: false) else {
        throw DevelopmentError.unreadable
      }
      let target = CIContext()
      _ = target
      let width = ci.width, height = ci.height
      guard let cg = CGContext(data: raw.baseAddress, width: width, height: height,
        bitsPerComponent: 32, bytesPerRow: width * 16, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue) else { throw DevelopmentError.unreadable }
      cg.draw(ci, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buffer
  }

  private func blur(_ image: CIImage, radius: Double) -> CIImage {
    image.clampedToExtent().applyingFilter("CIGaussianBlur",
      parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
  }

  func testGaussianResultDependsOnTheRequestedRectangle() throws {
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let width = 1024, height = 768
    let input = try source(width: width, height: height)
    let window = CGRect(x: 256, y: 192, width: 320, height: 240)
    for radius in [4.0, 18.0, 60.0] {
      let full = blur(input, radius: radius)
      let fullContext = context()
      let whole = try read(full, from: window, context: fullContext)
      fullContext.clearCaches()
      // A fresh context requesting only the window: no whole-frame target involved.
      let scopedContext = context()
      let scoped = try read(full, from: window, context: scopedContext)
      scopedContext.clearCaches()
      var maxDiff: Float = 0, sum: Double = 0
      var differing = 0
      for i in 0..<whole.count {
        let diff = abs(whole[i] - scoped[i])
        if !diff.isFinite { continue }
        maxDiff = max(maxDiff, diff); sum += Double(diff)
        if diff > 1e-6 { differing += 1 }
      }
      print("GAUSSIAN-RECT radius=\(radius) max=\(maxDiff) mean=\(sum / Double(whole.count)) differing=\(differing)/\(whole.count)")
    }
  }

  /// Same question, but comparing a whole-frame render with a render of a *cropped input*.
  /// This is what a windowed pipeline does when the upstream graph is scoped too.
  func testGaussianDiffersWhenOnlyTheInputIsScoped() throws {
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let width = 1024, height = 768
    let input = try source(width: width, height: height)
    let window = CGRect(x: 256, y: 192, width: 320, height: 240)
    for radius in [4.0, 18.0, 60.0] {
      let context = context()
      defer { context.clearCaches() }
      let full = try read(blur(input, radius: radius), from: window, context: context)
      // Crop the input, then blur the crop. Edge clamping makes this differ unless the halo is
      // large enough.
      let cropped = input.cropped(to: window.insetBy(dx: -3 * radius, dy: -3 * radius))
      let scoped = try read(blur(cropped, radius: radius), from: window, context: context)
      var maxDiff: Float = 0
      for i in 0..<full.count where full[i].isFinite && scoped[i].isFinite {
        maxDiff = max(maxDiff, abs(full[i] - scoped[i]))
      }
      print("GAUSSIAN-HALO radius=\(radius) halo=\(3 * radius) max=\(maxDiff)")
    }
  }
}
