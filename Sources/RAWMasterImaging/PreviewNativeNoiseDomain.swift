import CoreImage
import CryptoKit
import Foundation
import Metal
import RAWMasterCore

/// One native preview request and the actual two inputs read by rmNoiseDetail.
/// A completed bound may serve another strength on exactly the same resident operands.
final class PreviewNativeNoiseDomain {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_NATIVE_RAW_NOISE_DOMAIN"] == "1"

  final class Pair {
    let raw, based, gaussian: CIImage
    let key: FlashRawCanonicalTextureKey
    let camera: DevelopmentNoiseReductionV3
    fileprivate init(raw: CIImage, based: CIImage, key: FlashRawCanonicalTextureKey, camera: DevelopmentNoiseReductionV3) {
      self.key = key
      self.raw = raw
      self.based = based
      self.camera = camera
      self.gaussian = DevelopmentGlobalEngineV3.noiseDetailGaussian(based)
    }
  }

  /// Only a completed, joined FIT request can construct this resident proof. It never owns a pin or worker.
  final class Certificate {
    let pair: Pair
    fileprivate init(_ pair: Pair) { self.pair = pair }
  }

  static let programIsKnown = matchesProgram(DevelopmentGlobalEngineV3.metalSource)

  static func matchesProgram(_ source: String) -> Bool {
    func definition(_ name: String, end: String) -> Substring? {
      guard let start = source.range(of: name), let stop = source[start.upperBound...].range(of: end) else { return nil }
      return source[start.lowerBound..<stop.upperBound]
    }
    guard let luma = definition("float gy(", end: "}"),
          let restore = definition("[[stitchable]] float4 rmNoiseDetail(", end: "\n}") else { return false }
    let digest = SHA256.hash(data: Data((String(luma) + "\n" + String(restore)).utf8))
    return digest.map { String(format: "%02x", $0) }.joined() == "98b2fefbfb31539ac11550ff1bd409e08ca4a86afb297756e83773ac51193617"
  }

  static func camera(for p: DevelopmentAdjustmentsV3) -> DevelopmentNoiseReductionV3? {
    let n = p.noiseReduction
    guard p.rawDecoder == .flashRaw031, p.rawDetails == nil, n.enabled, n.nativeMappingVersion == 1,
          n.sourceCapability == .raw, n.nonRawAmount == 0,
          (0...1).contains(n.luminanceNoise), (0...1).contains(n.colorNoise), (0...1).contains(n.detail) else { return nil }
    let luminance = n.luminanceContrast ?? 0, color = n.colorDetail ?? 0
    let onlyLuminance = n.luminanceNoise > 0 && n.colorNoise == 0 && luminance > 0 && color == 0
    let onlyColor = n.colorNoise > 0 && n.luminanceNoise == 0 && n.detail == 0 && color > 0 && luminance == 0
    guard onlyLuminance || onlyColor, (0...1).contains(luminance), (0...1).contains(color) else { return nil }
    var allowed = p.neutralForSameSource
    allowed.noiseReduction = n
    guard p == allowed else { return nil }
    var camera = n
    camera.luminanceContrast = nil
    camera.colorDetail = nil
    return camera
  }

  private let pair: Pair
  private let pending: Bool
  private let controls: DevelopmentNoiseReductionV3
  private let pin: FlashRawCanonicalTexturePool.Pin
  private let checkAuthority: () throws -> Void
  private var boundOutput: CIImage?
  private var checked = false
  var based: CIImage { pair.based }

  static func acquire(_ p: DevelopmentAdjustmentsV3, pin: FlashRawCanonicalTexturePool.Pin,
                      asShotWhiteBalance: DevelopmentAsShotWhiteBalance?, device: MTLDevice, checkAuthority: @escaping () throws -> Void) throws -> PreviewNativeNoiseDomain? {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    guard enabled, programIsKnown, os.majorVersion == 27, os.minorVersion == 0, os.patchVersion == 1,
          device.hasUnifiedMemory, device.name == "Apple M4 Max", MTLCopyAllDevices().map(\.registryID) == [device.registryID],
          let camera = camera(for: p), pin.image.extent.origin == .zero,
          [CGSize(width: 9504, height: 6336), CGSize(width: 8640, height: 5760)].contains(pin.image.extent.size),
          try pin.checkOpaqueUpload(pin.image, cancellation: checkAuthority) else { return nil }
    try checkAuthority()
    let cached = pin.checkedNoiseCertificate()?.pair
    if let cached, cached.camera == camera {
      return PreviewNativeNoiseDomain(pair: cached, pending: false, controls: p.noiseReduction, pin: pin, checkAuthority: checkAuthority)
    }
    let based = try FlashRawImageFactory.applyInputAdjustments(p, to: pin.image, asShotWhiteBalance: asShotWhiteBalance)
    guard based.extent == pin.image.extent else { return nil }
    let pair = Pair(raw: pin.image, based: based, key: pin.noiseIdentity, camera: camera)
    return PreviewNativeNoiseDomain(pair: pair, pending: true, controls: p.noiseReduction, pin: pin, checkAuthority: checkAuthority)
  }

  private init(pair: Pair, pending: Bool, controls: DevelopmentNoiseReductionV3, pin: FlashRawCanonicalTexturePool.Pin,
               checkAuthority: @escaping () throws -> Void) {
    self.pair = pair
    self.pending = pending
    self.controls = controls
    self.pin = pin
    self.checkAuthority = checkAuthority
  }

  func requireCurrent() throws {
    try Task.checkCancellation()
    try checkAuthority()
    guard pin.isCurrent(for: pair.raw) else { throw PreviewPresentationError.allocationProtocol }
  }

  func gaussian(for input: CIImage, controls: DevelopmentNoiseReductionV3) -> CIImage? {
    input === pair.based && self.controls == controls ? pair.gaussian : nil
  }

  func bind(input: CIImage, gaussian: CIImage, controls: DevelopmentNoiseReductionV3, uniforms: CIVector, output: CIImage) {
    guard input === pair.based, gaussian === pair.gaussian, self.controls == controls,
          uniforms.count == 4, uniforms.x == (controls.luminanceContrast ?? 0), uniforms.y == (controls.colorDetail ?? 0) else { return }
    boundOutput = output
  }

  func proves(_ image: CIImage, using context: CIContext) throws -> Bool {
    guard boundOutput === image, image.extent == pair.raw.extent, context.workingFormat == .RGBAf,
          let space = context.workingColorSpace, CFEqual(space, DevelopmentColorEngineV3.linearSRGB) else { return false }
    try requireCurrent()
    let event = ImagePerformanceTelemetry.shared.begin(operation: "NativeRawNoiseDomain",
      stage: pending ? "验证原生降噪输入与高斯邻域" : "复用已验证的同一降噪输入与高斯邻域",
      queue: pending ? "Metal GPU" : "图像引擎", boundary: pending ? .gpuCompletion : .apiReturn)
    var outcome = ImagePerformanceOutcome.failed
    defer { ImagePerformanceTelemetry.shared.end(event, outcome: outcome, pixelCount: Int(image.extent.width * image.extent.height)) }
    if pending {
      guard let mask = Self.predicate?.apply(extent: pair.raw.extent, roiCallback: { _, r in r },
                                            arguments: [pair.raw, pair.based, pair.gaussian]),
            try DevelopmentCanonicalFiniteGPU.check(mask, domain: pair.raw.extent, context: context,
              workingBudget: DevelopmentCanonicalFiniteGPU.spatialWorkingBudget, allowPredicateMiss: true,
              cancellation: requireCurrent) else { return false }
    }
    try requireCurrent()
    checked = true
    outcome = .succeeded
    return true
  }

  /// Called only after the ordinary fitted CGImage has been joined and the caller has rechecked its revision.
  func finish(for output: CIImage) throws {
    guard checked, output === boundOutput else { return }
    try requireCurrent()
    if pending {
      let certificate = Certificate(pair)
      if try pin.installNoiseCertificate(certificate) {
        do { try requireCurrent() }
        catch { pin.discardNoiseCertificate(certificate); throw error }
      }
    }
  }

  // With unit alpha and |RGB| <= 8, both lumas are <= 8.01, their difference <= 16.02,
  // the chroma channels <= 16.01 and their differences <= 32.02. For coefficients
  // in [0,1], even the sum before the original final multiply has magnitude < 40.
  // This examines all three actual native operands, including every Gaussian edge sample.
  private static let predicate: CIKernel? = {
    let source = #"""
    #include <metal_stdlib>
    #include <CoreImage/CoreImage.h>
    using namespace metal;
    extern "C" { namespace coreimage {
    bool inOpaqueNoiseRange(float4 value) {
      uint4 bits = as_type<uint4>(value);
      return all((bits.rgb & uint3(0x7fffffffu)) <= uint3(0x41000000u)) && bits.a == 0x3f800000u;
    }
    [[stitchable]] float4 checkedNoiseInputs(sampler raw, sampler src, sampler local) {
      bool inside = inOpaqueNoiseRange(raw.sample(raw.coord())) && inOpaqueNoiseRange(src.sample(src.coord())) &&
                    inOpaqueNoiseRange(local.sample(local.coord()));
      return float4(inside ? 0.0f : 1.0f, 0.0f, 0.0f, 1.0f);
    }
    } }
    """#
    return try? CIKernel.kernels(withMetalString: source).first { $0.name == "checkedNoiseInputs" }
  }()
}
