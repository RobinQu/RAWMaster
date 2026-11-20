import Metal
import Foundation

/// Converts FlashRaw's three-channel half-float linear RGB into the existing RGBA32F proxy.
/// The source buffer remains sensor-oriented; EXIF orientation is folded into the sampling pass.
final class FlashRawMetalConverter {
  private struct Parameters {
    var sourceWidth: UInt32
    var sourceHeight: UInt32
    var orientation: UInt32
    var scale: Float
  }

  private static let source = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Parameters { uint sw, sh, orientation; float scale; };

  float3 readRGB(const device half *source, uint2 p, uint sw, uint sh) {
    p = clamp(p, uint2(0), uint2(sw - 1, sh - 1));
    uint i = (p.y * sw + p.x) * 3;
    return float3(source[i], source[i + 1], source[i + 2]);
  }

  float2 sensorPosition(float2 p, uint orientation, uint sw, uint sh) {
    float W = float(sw), H = float(sh);
    switch (orientation) {
      case 2: return float2(W - p.x, p.y);
      case 3: return float2(W - p.x, H - p.y);
      case 4: return float2(p.x, H - p.y);
      case 5: return float2(p.y, p.x);
      case 6: return float2(p.y, W - p.x);
      case 7: return float2(H - p.y, W - p.x);
      case 8: return float2(H - p.y, p.x);
      default: return p;
    }
  }

  kernel void convertFlashRaw(const device half *source [[buffer(0)]],
                              texture2d<float, access::write> destination [[texture(0)]],
                              constant Parameters &u [[buffer(1)]],
                              uint2 id [[thread_position_in_grid]]) {
    if (id.x >= destination.get_width() || id.y >= destination.get_height()) return;
    float2 oriented = (float2(id.xy) + 0.5) * u.scale;
    float2 p = sensorPosition(oriented, u.orientation, u.sw, u.sh) - 0.5;
    int2 lo = int2(floor(p));
    float2 t = fract(p);
    float3 a = mix(readRGB(source, uint2(lo), u.sw, u.sh),
                   readRGB(source, uint2(lo + int2(1, 0)), u.sw, u.sh), t.x);
    float3 b = mix(readRGB(source, uint2(lo + int2(0, 1)), u.sw, u.sh),
                   readRGB(source, uint2(lo + int2(1, 1)), u.sw, u.sh), t.x);
    destination.write(float4(mix(a, b, t.y), 1.0), id);
  }
  """#

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice) throws {
    self.device = device
    guard let queue = device.makeCommandQueue() else { throw FlashRawError.unavailable("Metal command queue unavailable") }
    self.queue = queue
    let library = try device.makeLibrary(source: Self.source, options: nil)
    guard let function = library.makeFunction(name: "convertFlashRaw") else {
      throw FlashRawError.unavailable("FlashRaw Metal converter is missing")
    }
    pipeline = try device.makeComputePipelineState(function: function)
  }

  func convert(_ frame: FlashRawFrame, into texture: MTLTexture, outputSize: CGSize) throws {
    guard texture.pixelFormat == .rgba32Float, outputSize.width > 0, outputSize.height > 0 else {
      throw FlashRawError.invalidFrame("invalid FlashRaw output texture")
    }
    let input = try frame.linearMetalBuffer(device: device)
    var parameters = Parameters(sourceWidth: UInt32(frame.info.width), sourceHeight: UInt32(frame.info.height),
      orientation: UInt32(frame.info.orientation), scale: 0)
    let orientedWidth = frame.info.orientation >= 5 && frame.info.orientation <= 8 ? frame.info.height : frame.info.width
    let orientedHeight = frame.info.orientation >= 5 && frame.info.orientation <= 8 ? frame.info.width : frame.info.height
    parameters.scale = Float(max(orientedWidth, orientedHeight)) / Float(max(outputSize.width, outputSize.height))
    // The struct has no stored destination fields; these checks use the texture itself.
    guard Int(outputSize.width) == texture.width, Int(outputSize.height) == texture.height else {
      throw FlashRawError.invalidFrame("FlashRaw output size does not match its texture")
    }
    guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      throw FlashRawError.unavailable("Metal conversion command unavailable")
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setTexture(texture, index: 0)
    encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
    let groups = MTLSize(width: 16, height: 16, depth: 1)
    let count = MTLSize(width: (texture.width + 15) / 16, height: (texture.height + 15) / 16, depth: 1)
    encoder.dispatchThreadgroups(count, threadsPerThreadgroup: groups)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw FlashRawError.decode(error.localizedDescription) }
  }
}

/// One process-wide pipeline avoids recompiling the converter for each proxy fill.
enum FlashRawMetalConverterCache {
  private static let result: Result<FlashRawMetalConverter, Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw FlashRawError.unavailable("Metal device unavailable")
    }
    return try FlashRawMetalConverter(device: device)
  }

  static func convert(_ frame: FlashRawFrame, into texture: MTLTexture, outputSize: CGSize) throws {
    try result.get().convert(frame, into: texture, outputSize: outputSize)
  }
}
