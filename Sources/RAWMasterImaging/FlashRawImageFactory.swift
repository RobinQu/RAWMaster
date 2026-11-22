import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// The decoder choice is persisted with a new RAW work and its descendants. Opening an old
/// version never upgrades its colour rendition just because a different library is installed.
public enum DevelopmentRAWSourcePolicy {
  public static func decoderForNewWork(at url: URL) throws -> DevelopmentRAWDecoder? {
    guard PhotoRenderer.rawExtensions.contains(url.pathExtension.lowercased()), !DevelopmentPhotoDenoise.isOutputReferredDNG(url), FlashRawSource.isAvailable,
          let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
          let raw = CIRAWFilter(imageURL: url), let extent = raw.outputImage?.extent else { return nil }
    try Task.checkCancellation()
    do {
      let source = try FlashRawSource.open(url)
      let geometry = source.geometry
      let rotated = (5...8).contains(geometry.orientation)
      let width = rotated ? geometry.height : geometry.width
      let height = rotated ? geometry.width : geometry.height
      guard source.decoderVersion == "0.3.1", (1...8).contains(geometry.orientation),
            geometry.orientation == Int(raw.orientation.rawValue), width > 0, height > 0,
            max(width, height) <= 16_384, extent.size == CGSize(width: width, height: height) else { return nil }
      // Check the actual file's compression/GPU support without constructing a full-resolution RGB image.
      let region = CGRect(x: 0, y: 0, width: min(32, geometry.width), height: min(32, geometry.height))
      let sample = try source.decode(output: .linearRGBF16, backend: .gpu, demosaic: .bilinear, region: region)
      guard sample.info.channels == 3, sample.info.sampleType == 4, sample.info.source == 0,
            !sample.info.incomplete, sample.info.outputFormat == FlashRawOutput.linearRGBF16.rawValue else { return nil }
      try Task.checkCancellation()
      return .flashRaw031
    } catch is FlashRawError {
      try Task.checkCancellation()
      return nil
    }
  }

  static func rawDetailsCapability(at url: URL, nativeSize: CGSize, orientation: Int) -> DevelopmentRawDetails? {
    guard FlashRawSource.isAvailable, let source = try? FlashRawSource.open(url),
          source.decoderVersion == "0.3.1", let mode = source.rawDetails else { return nil }
    let geometry = source.geometry
    let rotated = (5...8).contains(geometry.orientation)
    let size = CGSize(width: rotated ? geometry.height : geometry.width, height: rotated ? geometry.width : geometry.height)
    guard geometry.orientation == orientation, size == nativeSize, max(size.width, size.height) <= 16_384,
          let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else { return nil }
    return mode
  }

  static func usesFlashRaw(_ p: DevelopmentAdjustmentsV3, experiment: Bool =
    ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_FLASHRAW"] == "1") -> Bool {
    if p.aiDenoise != nil { return false }
    let noise = p.noiseReduction
    // These historical controls address CIRAWFilter's original decoder defaults.
    let nativeNoise = noise.enabled && (noise.luminanceNoise != 0 || noise.colorNoise != 0 || noise.detail != 0)
    guard !p.blackAndWhite.requiresLegacyGrainCanonicalInput else { return false }
    if p.rawDecoder == .flashRaw031 || p.rawDetails != nil { return true }
    return !nativeNoise && experiment && FlashRawSource.isAvailable
  }
}

enum FlashRawImageFactory {
  static func applyInputAdjustments(_ p: DevelopmentAdjustmentsV3, to image: CIImage,
                                    asShotWhiteBalance: DevelopmentAsShotWhiteBalance?, proxyScale: Double = 1) throws -> CIImage {
    let reduced = p.rawDecoder == .flashRaw031 || p.rawDetails != nil || p.aiDenoise != nil
      ? try FlashRawNoiseReduction.apply(p.noiseReduction, to: image, proxyScale: proxyScale) : image
    return try DevelopmentWhiteBalanceEngineV3.applyFlashRaw(p, to: reduced, asShotWhiteBalance: asShotWhiteBalance)
  }

  static func linearImage(capture: URL, rawDetails: DevelopmentRawDetails? = nil) throws -> CIImage {
    let source = try FlashRawSource.open(capture)
    guard source.decoderVersion == "0.3.1" else { throw FlashRawError.unavailable("FlashRaw 0.3.1 is required by this recipe") }
    let frame = try source.decode(output: .linearRGBF16, backend: .gpu, demosaic: source.demosaic(for: rawDetails))
    let info = frame.info
    guard (1...8).contains(info.orientation), info.width > 0, info.height > 0,
          let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
      throw FlashRawError.invalidFrame("invalid full-resolution output")
    }
    let rotated = (5...8).contains(info.orientation)
    let width = rotated ? info.height : info.width
    let height = rotated ? info.width : info.height
    // Native samples are already F16. At native resolution rotation is an integer permutation.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let texture = device.makeTexture(descriptor: descriptor) else { throw FlashRawError.invalidFrame("cannot allocate full-resolution texture") }
    try FlashRawMetalConverterCache.convert(frame, into: texture, outputSize: .init(width: width, height: height))
    guard let image = CIImage(mtlTexture: texture, options: [.colorSpace: DevelopmentColorEngineV3.linearSRGB]) else {
      throw FlashRawError.invalidFrame("cannot create linear CIImage")
    }
    return image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
  }
}
