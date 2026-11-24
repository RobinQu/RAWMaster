import Foundation
import Metal
import RAWMasterCore

/// A read-only check of the uploaded texture. Only the owning preview can bind
/// a successful check to the corresponding Core Image source.
enum FlashRawNativeFiniteCheck {
  static let enabled = DevelopmentCanonicalFiniteGPU.enabled &&
    ProcessInfo.processInfo.environment["RAWMASTER_CANONICAL_F16_SOURCE_CHECK"] != "0" &&
    ProcessInfo.processInfo.environment["RAWMASTER_RESCAN_RESIDENT_GLOBAL_FINITE"] != "1"

  struct Request {
    let mayCheckTexture: Bool
    let checkAuthority: () throws -> Void
  }

  private struct Pipeline {
    let queue: MTLCommandQueue
    let reduce: MTLComputePipelineState
  }

  private static let pipeline: Pipeline? = {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
          let queue = device.makeCommandQueue() else { return nil }
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void verifyOpaqueNativeHalf(texture2d<half, access::read> image [[texture(0)]],
      device uint *results [[buffer(0)]], uint2 tile [[threadgroup_position_in_grid]],
      uint index [[thread_index_in_threadgroup]], uint lane [[thread_index_in_simdgroup]],
      uint group [[simdgroup_index_in_threadgroup]]) {
      threadgroup uint checks[8];
      const uint width = image.get_width(), height = image.get_height();
      const uint y = tile.y * 16 + index / 16;
      uint count = 0, invalid = 0;
      for (uint step = 0; step < 4; ++step) {
        uint x = tile.x * 64 + index % 16 + step * 16;
        if (x >= width || y >= height) continue;
        ushort4 bits = as_type<ushort4>(image.read(uint2(x, y)));
        invalid |= any((bits.rgb & ushort3(0x7c00u)) == ushort3(0x7c00u)) || bits.a != 0x3c00u;
        count++;
      }
      uint check = simd_sum(count) | (simd_max(invalid) << 16);
      if (lane == 0) checks[group] = check;
      threadgroup_barrier(mem_flags::mem_threadgroup);
      if (index == 0) {
        uint result = 0;
        for (uint i = 0; i < 8; ++i) result += checks[i];
        results[tile.y * ((width + 63) / 64) + tile.x] = result;
      }
    }
    """
    guard let library = try? device.makeLibrary(source: source, options: nil),
          let function = library.makeFunction(name: "verifyOpaqueNativeHalf"),
          let reduce = try? device.makeComputePipelineState(function: function),
          reduce.threadExecutionWidth == 32, reduce.maxTotalThreadsPerThreadgroup >= 256 else { return nil }
    return Pipeline(queue: queue, reduce: reduce)
  }()

  /// A failed or unavailable check leaves the existing Core Image validation in charge.
  static func check(_ texture: MTLTexture, cancellation: () throws -> Void) throws -> Bool {
    try cancellation()
    try Task.checkCancellation()
    guard texture.pixelFormat == .rgba16Float, texture.storageMode == .private,
          texture.textureType == .type2D, texture.mipmapLevelCount == 1, texture.sampleCount == 1,
          texture.usage.contains(.shaderRead), texture.hazardTrackingMode != .untracked,
          (1...16_384).contains(texture.width), (1...16_384).contains(texture.height) else { return false }
    let telemetry = ImagePerformanceTelemetry.shared.begin(operation: "FlashRawNativeFiniteCheck",
      stage: "原生半浮点源纹理校验", queue: "Metal GPU", boundary: .gpuCompletion)
    var outcome = ImagePerformanceOutcome.failed
    defer {
      ImagePerformanceTelemetry.shared.end(telemetry, outcome: outcome,
        pixelCount: outcome == .succeeded ? texture.width * texture.height : 0)
    }
    let columns = (texture.width + 63) / 64, rows = (texture.height + 15) / 16
    let count = columns * rows
    let length = count * MemoryLayout<UInt32>.stride
    guard let pipeline, pipeline.queue.device.registryID == texture.device.registryID,
          let results = texture.device.makeBuffer(length: length, options: .storageModeShared),
          let command = pipeline.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      try cancellation()
      try Task.checkCancellation()
      return false
    }
    memset(results.contents(), 0xff, length)
    encoder.setComputePipelineState(pipeline.reduce)
    encoder.setTexture(texture, index: 0)
    encoder.setBuffer(results, offset: 0, index: 0)
    encoder.dispatchThreadgroups(.init(width: columns, height: rows, depth: 1),
                                 threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
    encoder.endEncoding()
    try cancellation()
    try Task.checkCancellation()
    command.commit()
    command.waitUntilCompleted()
    try cancellation()
    try Task.checkCancellation()
    guard command.status == .completed else { return false }
    let values = results.contents().bindMemory(to: UInt32.self, capacity: count)
    for row in 0..<rows {
      let height = min(16, texture.height - row * 16)
      for column in 0..<columns {
        let expected = min(64, texture.width - column * 64) * height
        guard values[row * columns + column] == UInt32(expected) else { return false }
      }
    }
    try cancellation()
    try Task.checkCancellation()
    outcome = .succeeded
    return true
  }
}
