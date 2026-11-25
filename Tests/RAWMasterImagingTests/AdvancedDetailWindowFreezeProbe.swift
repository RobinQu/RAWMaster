import XCTest
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

/// Decisive probe for the windowed-freeze direction: can the advanced-detail result be
/// materialized over a window only, and stay byte-identical to that window of the whole-frame
/// materialization?
///
/// The engine freezes the whole extent into RGBA32F because masked composites read the result
/// from more than one branch. If a windowed freeze reproduces the same texels, the freeze can be
/// scoped to a window and the operator becomes ROI-friendly; if not, the whole direction stops
/// here.
final class AdvancedDetailWindowFreezeProbe: XCTestCase {
  private func context() -> CIContext {
    CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 768])
  }

  /// Real sensor data when the environment provides one, otherwise a synthetic native-size image.
  private func source() throws -> CIImage {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["RAWMASTER_REGION_PROBE_SOURCE"],
       let image = try? FlashRawImageFactory.linearImage(capture: URL(fileURLWithPath: path)) {
      return image
    }
    let width = 1200, height = 800
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

  /// The engine's output graph without its freeze, built from the same pieces `apply` uses.
  private func bandGraph(_ image: CIImage) throws -> CIImage {
    let size = DevelopmentPixelSize(width: Int(image.extent.width), height: Int(image.extent.height))
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize: size)
    var output = image
    for amount in [25.0, 40.0] {
      let band: DevelopmentAdvancedDetailEngineV3.Band = amount == 25 ? .texture : .clarity
      let radius = band == .texture ? radii.texture : radii.clarity
      let guides = try DevelopmentAdvancedDetailEngineV3.guides(output, radius: radius)
      let kernel = try XCTUnwrap(CIKernel.kernels(withMetalString: DevelopmentAdvancedDetailEngineV3.metalSource)
        .first { $0.name == "rmAdvancedBandV1" })
      output = try XCTUnwrap(try kernel.apply(extent: output.extent, roiCallback: { _, rect in rect },
        arguments: [output.samplingNearest(), guides.fine.samplingNearest(),
                    guides.wide.samplingNearest(), CIVector(x: amount / 100, y: band == .texture ? 0 : 1, z: 0, w: 0)]))
    }
    return output
  }

  /// Each call uses its own context: a shared context would serve the second request from the
  /// first render's cache and hide any rectangle dependence.
  private func freeze(_ image: CIImage, from rect: CGRect) throws -> [Float] {
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
    let fresh = context()
    let task = try fresh.startTask(toRender: image, from: rect, to: destination, at: .zero)
    _ = try task.waitUntilCompleted()
    var values = [Float](repeating: .nan, count: Int(rect.width) * Int(rect.height) * 4)
    values.withUnsafeMutableBytes { raw in
      texture.getBytes(raw.baseAddress!, bytesPerRow: Int(rect.width) * 16,
        from: MTLRegionMake2D(0, 0, Int(rect.width), Int(rect.height)), mipmapLevel: 0)
    }
    return values
  }

  /// Render `image` over `rect` into a private RGBA32F texture and wrap it back as a CIImage
  /// placed at `rect`. Same ownership and orientation as the engine's own freeze.
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
    let fresh = context()
    let task = try fresh.startTask(toRender: image, from: rect, to: destination, at: .zero)
    _ = try task.waitUntilCompleted()
    retainedTextures.append(texture)
    let drawn = try XCTUnwrap(CIImage(mtlTexture: texture,
      options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB]))
    return drawn.transformed(by: .init(translationX: rect.minX, y: rect.minY))
  }
  private var retainedTextures: [MTLTexture] = []

  /// Does the texture round-trip itself preserve the guide, or is the wrap lossy?
  func testFrozenGuideTextureEqualsTheInlineGuide() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_ADVANCED_FREEZE_PROBE"] == "1",
                      "Explicit probe opt-in is required")
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let input = try source()
    let extent = input.extent
    let size = DevelopmentPixelSize(width: Int(extent.width), height: Int(extent.height))
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize: size)
    let guides = try DevelopmentAdvancedDetailEngineV3.guides(input, radius: radii.texture)
    let window = CGRect(x: (extent.width * 0.31).rounded(), y: (extent.height * 0.27).rounded(),
                        width: 2400, height: 1600)
    for halo in [0, 8, 32] {
      let region = window.insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo)).intersection(extent)
      let direct = try freeze(guides.fine, from: window)
      let wrapped = try freezeTexture(guides.fine, from: region)
      let viaTexture = try freeze(wrapped, from: window)
      var maxDiff: Float = 0, differing = 0
      for i in 0..<direct.count {
        let a = direct[i], b = viaTexture[i]
        guard a.isFinite, b.isFinite else { differing += 1; continue }
        let diff = abs(a - b)
        if diff > 0 { differing += 1; maxDiff = max(maxDiff, diff) }
      }
      print("GUIDE-ROUNDTRIP halo=\(halo) max=\(maxDiff) differing=\(differing)/\(direct.count)")
    }
  }

  /// Experiment 1: freeze the *guides* over window + halo instead of freezing the band output.
  ///
  /// Cropping a guide limits where Core Image evaluates the Gaussian. If the halo covers the
  /// blur taps, the band kernel — which samples every input at the same coordinate — must return
  /// exactly the whole-frame values inside the window. This is the precondition for windowing
  /// the operator without re-baselining any pixel.
  func testGuideWindowWithHaloKeepsTheBandValuesInsideTheWindow() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_ADVANCED_FREEZE_PROBE"] == "1",
                      "Explicit probe opt-in is required")
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let input = try source()
    let extent = input.extent
    let size = DevelopmentPixelSize(width: Int(extent.width), height: Int(extent.height))
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize: size)
    let window = CGRect(x: (extent.width * 0.31).rounded(), y: (extent.height * 0.27).rounded(),
                        width: 2400, height: 1600)
    let kernel = try XCTUnwrap(CIKernel.kernels(withMetalString: DevelopmentAdvancedDetailEngineV3.metalSource)
      .first { $0.name == "rmAdvancedBandV1" })

    for (band, radius, amount) in [(DevelopmentAdvancedDetailEngineV3.Band.texture, radii.texture, 25.0),
                                   (.clarity, radii.clarity, 40.0)] {
      let fullGuides = try DevelopmentAdvancedDetailEngineV3.guides(input, radius: radius)
      func banded(_ guides: DevelopmentAdvancedDetailEngineV3.Guides) throws -> CIImage {
        try XCTUnwrap(try kernel.apply(extent: extent, roiCallback: { _, rect in rect },
          arguments: [input.samplingNearest(), guides.fine.samplingNearest(), guides.wide.samplingNearest(),
                      CIVector(x: amount / 100, y: band == .texture ? 0 : 1, z: 0, w: 0)]))
      }
      let reference = try freeze(banded(fullGuides), from: window)
      let wideTaps = Int((radius * 4).rounded(.up))
      print("GUIDE-WINDOW band=\(band) radius=\(radius) wideTaps=\(wideTaps)")
      var sweep = [0, 2, 4, 8, 16, 32, 64]
      if wideTaps > 64 { sweep += [96, wideTaps, wideTaps + 8] }
      for halo in sweep {
        let region = window.insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo)).intersection(extent)
        // Real scoping: the guides are evaluated into textures over `region` only.
        let frozen = DevelopmentAdvancedDetailEngineV3.Guides(
          fine: try freezeTexture(fullGuides.fine, from: region),
          wide: try freezeTexture(fullGuides.wide, from: region))
        let candidate = try freeze(banded(frozen), from: window)
        var maxDiff: Float = 0, differing = 0
        for i in 0..<reference.count {
          let a = reference[i], b = candidate[i]
          if !a.isFinite || !b.isFinite { differing += 1; continue }
          let diff = abs(a - b)
          if diff > 0 { differing += 1; maxDiff = max(maxDiff, diff) }
        }
        print("  halo=\(halo) max=\(maxDiff) differing=\(differing)")
      }
    }
  }

  /// Same question for the guide blur alone at native scale. If this differs, Core Image's
  /// Gaussian is the rect-dependent step and only an owned blur can make the engine ROI-safe.
  func testGuideBlurIsRectIndependentAtNativeScale() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_ADVANCED_FREEZE_PROBE"] == "1",
                      "Explicit probe opt-in is required")
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let input = try source()
    let extent = input.extent
    let size = DevelopmentPixelSize(width: Int(extent.width), height: Int(extent.height))
    let radii = try DevelopmentAdvancedDetailEngineV3.radii(sourceSize: size)
    let guides = try DevelopmentAdvancedDetailEngineV3.guides(input, radius: radii.texture)
    let window = CGRect(x: (extent.width * 0.31).rounded(), y: (extent.height * 0.27).rounded(),
                        width: 2400, height: 1600)
    let whole = try freeze(guides.fine, from: extent)
    let scoped = try freeze(guides.fine, from: window)
    let width = Int(extent.width), windowWidth = Int(window.width)
    var maxDiff: Float = 0, differing = 0
    for y in 0..<Int(window.height) {
      for x in 0..<windowWidth {
        let global = ((Int(window.minY) + y) * width + Int(window.minX) + x) * 4
        let local = (y * windowWidth + x) * 4
        for channel in 0..<4 {
          let a = whole[global + channel], b = scoped[local + channel]
          guard a.isFinite, b.isFinite else { differing += 1; continue }
          let diff = abs(a - b)
          if diff > 0 { differing += 1; maxDiff = max(maxDiff, diff) }
        }
      }
    }
    print("GUIDE-PROBE radius=\(radii.texture) max=\(maxDiff) differing=\(differing)")
  }

  func testWindowedFreezeReproducesTheWholeFrameTexels() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RAWMASTER_ADVANCED_FREEZE_PROBE"] == "1",
                      "Explicit probe opt-in is required")
    try XCTSkipUnless(MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true)
    let input = try source()
    let extent = input.extent
    let graph = try bandGraph(input)
    // A 2400x1600 canvas window at an off-origin position, the same shape the 1:1 path asks for.
    let window = CGRect(x: (extent.width * 0.31).rounded(), y: (extent.height * 0.27).rounded(),
                        width: min(2400, extent.width - 100), height: min(1600, extent.height - 100))
    let whole = try freeze(graph, from: extent)
    let scoped = try freeze(graph, from: window)
    let width = Int(extent.width), windowWidth = Int(window.width)
    var maxDiff: Float = 0, differing = 0
    for y in 0..<Int(window.height) {
      for x in 0..<windowWidth {
        let global = ((Int(window.minY) + y) * width + Int(window.minX) + x) * 4
        let local = (y * windowWidth + x) * 4
        for channel in 0..<4 {
          let a = whole[global + channel], b = scoped[local + channel]
          if !a.isFinite || !b.isFinite { differing += 1; continue }
          let diff = abs(a - b)
          if diff > 0 { differing += 1; maxDiff = max(maxDiff, diff) }
        }
      }
    }
    print("FREEZE-PROBE window=\(Int(window.width))x\(Int(window.height)) max=\(maxDiff) differing=\(differing)")
    XCTAssertEqual(maxDiff, 0, "a windowed freeze must reproduce the whole-frame texels")
  }
}
