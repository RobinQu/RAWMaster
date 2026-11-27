import CryptoKit
import Foundation
import Metal
import RAWMasterCore

extension DevelopmentSceneOutputStateV1.Target {
    fileprivate var pins: (shader: String, reach: String, cusp: String) {
      switch self {
      case .sdr709:
        return ("b0a886a004d8bad6967b852abb8220d1237bb8de19e40ca4d8f32d6b7dae98ab",
                "52704966e56829e171dcd42e02ca3e6b54139681ee8bc9565f9701fe5eda4595",
                "555941af92c7de847a4cb8ce5f305ea6d046687c3b3a8fa4176abd9e24d15641")
      case .hdr2020:
        return ("d58fea9391f80050ab4eb0a78684d66a4d116f546bd110a66240a71a0c601512",
                "021ddbf56b4a5eaf5ed9efc50a697a2cc7bbb69f15ccf8bdbc5b9fb90df67ca3",
                "f186cf616bdee5c375c3ddbd77ac0e9fe019d185b1b53cd2094c8adc9b0eca84")
      }
    }

    // Input is straight display linear; this function only encodes, never applies a DRT.
    func encodeChannel(_ value: Float) throws -> Float {
      guard value.isFinite, value >= 0, value <= peakNits / referenceWhiteNits else { throw DevelopmentSceneOutputV1.Failure.invalidPixel }
      let v = Double(value)
      if self == .sdr709 { return Float(v <= 0.0031308 ? 12.92*v : 1.055*pow(v,1/2.4)-0.055) }
      let m1=2610.0/16384, m2=2523.0/32, c1=3424.0/4096, c2=2413.0/128, c3=2392.0/128
      let p=pow(v * Double(referenceWhiteNits) / 10_000, m1)
      return Float(pow((c1+c2*p)/(1+c3*p),m2))
    }
}

final class DevelopmentSceneOutputV1 {
  typealias Target = DevelopmentSceneOutputStateV1.Target

  enum Boundary { case display, beforeGamut }

  struct DisplayImage {
    let texture: MTLTexture
    let target: Target
    let origin: SIMD2<Int>
    fileprivate init(texture: MTLTexture, target: Target, origin: SIMD2<Int>) {
      self.texture=texture; self.target=target; self.origin=origin
    }
    /// The compositor copies already transformed, typed tiles into this full-size texture.
    init(assembled texture: MTLTexture, like tile: Self) {
      self.init(texture: texture, target: tile.target, origin: .zero)
    }
  }

  enum Failure: Error, Equatable { case invalidResource, invalidInput, invalidPixel }
  typealias MetalFailure = DevelopmentSceneColorV1.Failure

  private let boundary: Boundary
  private let target: Target
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let reach, cusp: MTLTexture
  private let sampler: MTLSamplerState

  init(device: MTLDevice, target: Target, boundary: Boundary = .display) throws {
    let pins=target.pins
    func data(_ suffix: String, _ ext: String, _ pin: String) throws -> Data {
      guard let url=Bundle.module.url(forResource:target.rawValue+suffix,withExtension:ext,subdirectory:"SceneColor") else {
        throw Failure.invalidResource
      }
      let value=try Data(contentsOf:url)
      var digest=""
      for byte in SHA256.hash(data:value) { digest += String(format:"%02x",byte) }
      guard digest == pin else { throw Failure.invalidResource }
      return value
    }
    var shader=String(decoding:try data("","metal",pins.shader),as:UTF8.self)
    if boundary == .beforeGamut {
      // Derived only from the pinned shader. Tone and chroma rendering are retained;
      // export still runs the *unaltered* gamut compressor and final range operator.
      guard target == .hdr2020,
            let gamut = shader.range(of: "// Add GamutCompress (fwd)"),
            let conversion = shader.range(of: "// Add JMh to RGB", range: gamut.upperBound..<shader.endIndex) else {
        throw Failure.invalidResource
      }
      shader.removeSubrange(gamut.lowerBound..<conversion.lowerBound)
      guard let range = shader.range(of: "// Add Range processing"),
            let end = shader.range(of: "return outColor;", range: range.upperBound..<shader.endIndex) else { throw Failure.invalidResource }
      shader.removeSubrange(range.lowerBound..<end.lowerBound)
    }
    func table(_ suffix: String,_ pin: String,_ format: MTLPixelFormat,_ bytesPerPixel: Int) throws -> MTLTexture {
      let value=try data(suffix,"f32",pin)
      let width=362, length=width*bytesPerPixel
      guard value.count == length else { throw Failure.invalidResource }
      let d=MTLTextureDescriptor(); d.textureType = .type1D; d.pixelFormat=format
      d.width=width; d.storageMode = .shared; d.usage = .shaderRead
      guard let texture=device.makeTexture(descriptor:d) else { throw MetalFailure.metalUnavailable }
      value.withUnsafeBytes { bytes in
        texture.replace(region:MTLRegionMake1D(0,width),mipmapLevel:0,withBytes:bytes.baseAddress!,bytesPerRow:length)
      }
      return texture
    }
    let options=MTLCompileOptions(); options.mathMode = .safe
    let source="#include <metal_stdlib>\nusing namespace metal;\n"+shader+Self.wrapper
    let library=try device.makeLibrary(source:source,options:options)
    guard let function=library.makeFunction(name:"rmSceneViewV1"), let queue=device.makeCommandQueue() else {
      throw MetalFailure.metalUnavailable
    }
    let s=MTLSamplerDescriptor(); s.normalizedCoordinates=true; s.sAddressMode = .clampToEdge
    s.minFilter = .nearest; s.magFilter = .nearest
    guard let sampler=device.makeSamplerState(descriptor:s) else { throw MetalFailure.metalUnavailable }
    self.reach=try table("-reach",pins.reach,.r32Float,4); self.cusp=try table("-cusp",pins.cusp,.rgba32Float,16)
    self.pipeline=try device.makeComputePipelineState(function:function)
    self.device=device; self.queue=queue; self.target=target; self.sampler=sampler; self.boundary=boundary
  }

  func render(_ image: DevelopmentSceneMetalV1.Image, hdrLimitEV: Double? = nil) throws -> DisplayImage {
    guard boundary == .display else { throw Failure.invalidInput }
    var peak: Float = 0
    if target == .hdr2020, let hdrLimitEV {
      guard (0...DevelopmentSceneOutputStateV1.Version.maximumHDRLimitEV).contains(hdrLimitEV) else { throw Failure.invalidInput }
      peak = Float(exp2(hdrLimitEV))
    }
    return DisplayImage(texture: try evaluate(image, peak: peak), target: target, origin: image.origin)
  }

  struct TargetEvidence { let texture: MTLTexture }
  func preGamutEvidence(_ image: DevelopmentSceneMetalV1.Image) throws -> TargetEvidence {
    guard boundary == .beforeGamut else { throw Failure.invalidInput }
    return .init(texture: try evaluate(image))
  }

  private func evaluate(_ image: DevelopmentSceneMetalV1.Image, peak: Float = 0) throws -> MTLTexture {
    try Task.checkCancellation()
    let source=image.texture
    guard image.port == .working, source.device === device, source.textureType == .type2D,
          source.pixelFormat == .rgba32Float, !source.isFramebufferOnly, source.storageMode != .memoryless,
          source.usage.isEmpty || source.usage.contains(.shaderRead) else { throw Failure.invalidInput }
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:source.width,height:source.height,mipmapped:false)
    d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
    guard let output=device.makeTexture(descriptor:d), let flag=device.makeBuffer(length:4,options:.storageModeShared),
          let command=queue.makeCommandBuffer(), let encoder=command.makeComputeCommandEncoder() else { throw MetalFailure.metalUnavailable }
    let invalid=flag.contents().bindMemory(to:UInt32.self,capacity:1); invalid.pointee=0
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source,index:0); encoder.setTexture(output,index:1)
    encoder.setTexture(reach,index:2); encoder.setTexture(cusp,index:3)
    encoder.setSamplerState(sampler,index:0); encoder.setBuffer(flag,offset:0,index:0)
    var limit = peak
    encoder.setBytes(&limit, length: MemoryLayout<Float>.stride, index: 1)
    let lanes=pipeline.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width:source.width,height:source.height,depth:1),
      threadsPerThreadgroup:MTLSize(width:lanes,height:min(8,pipeline.maxTotalThreadsPerThreadgroup/lanes),depth:1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? MetalFailure.gpuExecutionFailed }
    try Task.checkCancellation()
    guard invalid.pointee == 0 else { throw Failure.invalidPixel }
    return output
  }

  private static let wrapper = #"""

kernel void rmSceneViewV1(texture2d<float,access::read> scene [[texture(0)]],
                          texture2d<float,access::write> display [[texture(1)]],
                          texture1d<float> reach [[texture(2)]], texture1d<float> cusp [[texture(3)]],
                          sampler lookup [[sampler(0)]], device atomic_uint& invalid [[buffer(0)]],
                          constant float& limit [[buffer(1)]], uint2 xy [[thread_position_in_grid]]) {
  float4 p=scene.read(xy);
  if (!all(isfinite(p)) || p.a < 0 || p.a > 1) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  if (p.a == 0) { display.write(float4(0),xy); return; }
  float3 rgb=p.rgb/p.a;
  if (!all(isfinite(rgb))) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  float3 shown=OCIOMain(reach,lookup,cusp,lookup,float4(rgb,1)).rgb;
  if (!all(isfinite(shown))) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  // Preserve Rec.2020 chromaticity and leave every component below the ceiling untouched.
  float maximum = max(shown.r, max(shown.g, shown.b));
  if (limit > 0 && maximum > limit) { shown *= limit / maximum; }
  display.write(float4(shown*p.a,p.a),xy);
}
"""#
}
