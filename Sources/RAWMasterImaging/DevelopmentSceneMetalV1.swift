import Metal

final class DevelopmentSceneMetalV1 {
  typealias Color = DevelopmentSceneColorV1

  struct Image {
    // The producer must supply its actual reference and leave the texture immutable during rendering.
    let texture: MTLTexture
    let port: Color.Port
    let origin: SIMD2<Int>

    init(texture: MTLTexture, port: Color.Port, origin: SIMD2<Int> = .zero) {
      self.texture = texture; self.port = port; self.origin = origin
    }
  }

  private struct Parameters {
    let red, green, blue: SIMD4<Float>
    let region: SIMD4<UInt32>
    let scale: Float
    let straight: UInt32
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState

  init(device: MTLDevice) throws {
    guard let queue = device.makeCommandQueue() else { throw Color.Failure.metalUnavailable }
    let options = MTLCompileOptions()
    options.mathMode = .safe // Non-finite values must reach the rejection check.
    let library = try device.makeLibrary(source: Self.source, options: options)
    guard let function = library.makeFunction(name: "rmSceneColorV1") else { throw Color.Failure.metalUnavailable }
    self.pipeline = try device.makeComputePipelineState(function: function)
    self.device = device; self.queue = queue
  }

  func render(_ image: Image, to target: Color.Space = .acescg, exposureEV: Float = 0,
              region: MTLRegion? = nil) throws -> Image {
    try Task.checkCancellation()
    let transform = try Color.makeTransform(from: image.port, to: target, exposureEV: exposureEV)
    let source = image.texture
    guard source.device === device, source.textureType == .type2D, source.pixelFormat == .rgba32Float,
          !source.isFramebufferOnly, source.storageMode != .memoryless,
          source.usage.isEmpty || source.usage.contains(.shaderRead) else { throw Color.Failure.invalidTexture }
    let rect = region ?? MTLRegionMake2D(0, 0, source.width, source.height)
    let (x, y, z) = (rect.origin.x, rect.origin.y, rect.origin.z)
    let (width, height) = (rect.size.width, rect.size.height)
    let (originX, overflowX) = image.origin.x.addingReportingOverflow(x)
    let (originY, overflowY) = image.origin.y.addingReportingOverflow(y)
    guard z == 0, rect.size.depth == 1, x >= 0, y >= 0, width > 0, height > 0,
          width <= source.width, height <= source.height, x <= source.width - width, y <= source.height - height,
          !overflowX, !overflowY, !originX.addingReportingOverflow(width - 1).overflow,
          !originY.addingReportingOverflow(height - 1).overflow else { throw Color.Failure.invalidRegion }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let destination = device.makeTexture(descriptor: descriptor),
          let invalid = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
          let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
      throw Color.Failure.metalUnavailable
    }
    let flag = invalid.contents().bindMemory(to: UInt32.self, capacity: 1)
    flag.pointee = 0
    var parameters = Parameters(red: transform.rows.0, green: transform.rows.1, blue: transform.rows.2,
      region: .init(UInt32(x), UInt32(y), UInt32(width), UInt32(height)), scale: transform.scale,
      straight: image.port.alpha == .straight ? 1 : 0)
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source, index: 0)
    encoder.setTexture(destination, index: 1)
    encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.setBuffer(invalid, offset: 0, index: 1)
    let lanes = pipeline.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: lanes, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? Color.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    guard flag.pointee == 0 else { throw Color.Failure.invalidPixel }
    return Image(texture: destination, port: transform.output, origin: SIMD2(originX, originY))
  }

  private static let source = #"""
#include <metal_stdlib>
using namespace metal;
struct Parameters { float4 red, green, blue; uint4 region; float scale; uint straight; };
kernel void rmSceneColorV1(texture2d<float, access::read> input [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant Parameters& p [[buffer(0)]], device atomic_uint& invalid [[buffer(1)]],
                           uint2 xy [[thread_position_in_grid]]) {
  if (any(xy >= p.region.zw)) return;
  float4 pixel = input.read(xy + p.region.xy);
  if (!all(isfinite(pixel)) || pixel.a < 0 || pixel.a > 1) {
    atomic_store_explicit(&invalid, 1, memory_order_relaxed);
    return;
  }
  if (pixel.a == 0) { output.write(float4(0), xy); return; }
  float3 rgb = pixel.rgb * (p.straight ? pixel.a : 1.0f);
  float3 result = float3(dot(p.red.xyz, rgb), dot(p.green.xyz, rgb), dot(p.blue.xyz, rgb)) * p.scale;
  if (!all(isfinite(result))) {
    atomic_store_explicit(&invalid, 1, memory_order_relaxed);
    return;
  }
  output.write(float4(result, pixel.a), xy);
}
"""#
}
