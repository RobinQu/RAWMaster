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

  float3 readRGB(const device half *source, int2 p, uint sw, uint sh) {
    uint2 pixel = uint2(clamp(p, int2(0), int2(sw - 1, sh - 1)));
    uint i = (pixel.y * sw + pixel.x) * 3;
    return float3(source[i], source[i + 1], source[i + 2]);
  }

  float2 sensorPosition(float2 p, uint orientation, uint sw, uint sh) {
    float W = float(sw), H = float(sh);
    switch (orientation) {
      case 2: return float2(W - p.x, p.y);
      case 3: return float2(W - p.x, H - p.y);
      case 4: return float2(p.x, H - p.y);
      case 5: return float2(p.y, p.x);
      case 6: return float2(p.y, H - p.x);
      case 7: return float2(W - p.y, H - p.x);
      case 8: return float2(W - p.y, p.x);
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
    if (u.scale == 1.0f) {
      destination.write(float4(readRGB(source, lo, u.sw, u.sh), 1.0), id);
      return;
    }
    float2 t = fract(p);
    float3 a = mix(readRGB(source, lo, u.sw, u.sh),
                   readRGB(source, lo + int2(1, 0), u.sw, u.sh), t.x);
    float3 b = mix(readRGB(source, lo + int2(0, 1), u.sw, u.sh),
                   readRGB(source, lo + int2(1, 1), u.sw, u.sh), t.x);
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
    let nativeF16 = texture.pixelFormat == .rgba16Float
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: nativeF16 ? "FlashRaw.linearToRGBA16F" : "FlashRaw.linearToRGBA32F",
      stage: nativeF16 ? "F16 上传 · 原生方向" : "F16 上传 · 方向与缩放", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer {
      ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome,
        pixelCount: texture.width * texture.height, byteCount: texture.width * texture.height * (nativeF16 ? 8 : 16))
    }
    guard nativeF16 || texture.pixelFormat == .rgba32Float, outputSize.width > 0, outputSize.height > 0 else {
      throw FlashRawError.invalidFrame("invalid FlashRaw output texture")
    }
    let input = try frame.linearMetalBuffer(device: device)
    try convert(input, sourceWidth: frame.info.width, sourceHeight: frame.info.height,
      orientation: frame.info.orientation, into: texture, outputSize: outputSize)
    outcome = .succeeded
  }

  func convert(_ input: MTLBuffer, sourceWidth: Int, sourceHeight: Int, orientation: Int,
               into texture: MTLTexture, outputSize: CGSize) throws {
    guard sourceWidth > 0, sourceHeight > 0, (1...8).contains(orientation),
          sourceWidth <= Int(UInt32.max), sourceHeight <= Int(UInt32.max),
          sourceWidth <= input.length / 6 / sourceHeight, Int(outputSize.width) == texture.width,
          Int(outputSize.height) == texture.height else { throw FlashRawError.invalidFrame("invalid Metal conversion geometry") }
    var parameters = Parameters(sourceWidth: UInt32(sourceWidth), sourceHeight: UInt32(sourceHeight),
      orientation: UInt32(orientation), scale: Float(max(sourceWidth, sourceHeight)) / Float(max(texture.width, texture.height)))
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
    guard command.status == .completed else { throw FlashRawError.decode(command.error?.localizedDescription ?? "Metal command failed") }
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

/// The export worker installs this capture only while constructing a native 2× TIFF graph.
final class FlashRawBandedUpload {
  @TaskLocal static var sourceCapture: URL?
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_SUPER_RESOLUTION_BANDED_UPLOAD"] != "0"

  private struct Band {
    let width: UInt32
    let height: UInt32
    let outputY: UInt32
  }

  private static let shader = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Band { uint width, height, outputY; };
  kernel void uploadNativeF16Band(const device half *source [[buffer(0)]],
                                  texture2d<float, access::write> destination [[texture(0)]],
                                  constant Band &band [[buffer(1)]],
                                  uint2 id [[thread_position_in_grid]]) {
    if (id.x >= band.width || id.y >= band.height) return;
    uint i = (id.y * band.width + id.x) * 3;
    float3 rgb = float3(source[i], source[i + 1], source[i + 2]);
    destination.write(float4(rgb, 1.0), uint2(id.x, id.y + band.outputY));
  }
  """#

  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private static let shared = Result { try FlashRawBandedUpload() }

  private init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw FlashRawError.unavailable("FlashRaw band upload queue unavailable")
    }
    self.queue = queue
    let library = try device.makeLibrary(source: Self.shader, options: nil)
    guard let function = library.makeFunction(name: "uploadNativeF16Band") else {
      throw FlashRawError.unavailable("FlashRaw band upload kernel unavailable")
    }
    pipeline = try device.makeComputePipelineState(function: function)
  }

  static func convertIfEligible(_ frame: FlashRawFrame, source: FlashRawSource, into texture: MTLTexture,
                                device: MTLDevice) throws -> Bool {
    let info = frame.info
    guard source.decoderVersion == "0.3.1", device.hasUnifiedMemory, texture.device.registryID == device.registryID,
          texture.pixelFormat == .rgba16Float, texture.storageMode == .private, texture.textureType == .type2D,
          info.orientation == 1, info.originX == 0, info.originY == 0, info.width == texture.width,
          info.height == texture.height, let width = UInt32(exactly: info.width),
          UInt32(exactly: info.height) != nil else { return false }
    let geometry = source.geometry
    guard (geometry.width, geometry.height, geometry.orientation) == (info.width, info.height, 1) else { return false }
    let rgb = try frame.linearRGBF16Data()
    guard rgb.count >= 64 * 1024 * 1024 else { return false }
    let rowBytes = info.width * 6
    let rows = min(info.height, min(256, (16 * 1024 * 1024) / rowBytes))
    guard rows > 0 else { return false }
    try Task.checkCancellation()
    guard case let .success(converter) = shared,
          converter.queue.device.registryID == device.registryID else {
      try Task.checkCancellation()
      return false
    }
    try converter.upload(rgb, width: width, into: texture, rows: rows, rowBytes: rowBytes)
    return true
  }

  private func upload(_ rgb: Data, width: UInt32, into texture: MTLTexture, rows: Int, rowBytes: Int) throws {
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: "FlashRaw.linearToRGBA16F.banded",
      stage: "F16 分带上传 · 超分辨率 TIFF", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    var uploaded = 0, joinedRows = 0
    defer {
      ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome, pixelCount: joinedRows * texture.width, byteCount: uploaded)
    }
    guard let staging = queue.device.makeBuffer(length: rows * rowBytes, options: .storageModeShared) else {
      throw FlashRawError.invalidFrame("cannot allocate the shared FlashRaw upload band")
    }
    do {
      // rgb retains FlashRaw's original C frame. No outstanding reader may span a staging-buffer reuse.
      try rgb.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let source = raw.baseAddress else { throw FlashRawError.invalidFrame("missing linear pixels") }
        for y in stride(from: 0, to: texture.height, by: rows) {
          try autoreleasepool {
            try Task.checkCancellation()
            let height = min(rows, texture.height - y)
            memcpy(staging.contents(), source.advanced(by: y * rowBytes), height * rowBytes)
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
              throw FlashRawError.unavailable("FlashRaw band upload command unavailable")
            }
            var range = Band(width: width, height: UInt32(height), outputY: UInt32(y))
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(staging, offset: 0, index: 0)
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&range, length: MemoryLayout<Band>.size, index: 1)
            encoder.dispatchThreadgroups(.init(width: (texture.width + 15) / 16, height: (height + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: .init(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            try Task.checkCancellation()
            command.commit()
            uploaded += height * rowBytes
            command.waitUntilCompleted()
            guard command.status == .completed else {
              throw FlashRawError.decode(command.error?.localizedDescription ?? "Metal band upload failed")
            }
            joinedRows += height
            try Task.checkCancellation()
          }
        }
      }
      outcome = .succeeded
    } catch is CancellationError {
      outcome = .cancelled
      throw CancellationError()
    }
  }
}
