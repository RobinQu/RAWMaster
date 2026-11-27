import Foundation
import Metal
import RAWMasterCore

/// A model prefix is defined in native pixels. A viewport may sample its result, never
/// change the resolution or context seen by denoise, super-resolution or segmentation.
final class DevelopmentSceneModelPreviewV1 {
  private typealias Pipeline = DevelopmentSceneModelPipelineV1
  let program: DevelopmentSceneModelProgramV1
  let native: DevelopmentSceneModelPipelineV1.Result
  private let flags: MTLTexture
  private let availableSampleBytes: Int
  private let queue: MTLCommandQueue
  private let fit: MTLComputePipelineState

  init(program: DevelopmentSceneModelProgramV1, mosaic: DevelopmentSceneRAWV1.Mosaic,
       decoder: DevelopmentSceneRAWV1, provider: (any DevelopmentSceneModelProvider)?, budget: Int) throws {
    let device = mosaic.texture.device
    let width = Int(mosaic.sensor.size.x), height = Int(mosaic.sensor.size.y)
    let flagsBytes = Pipeline.surfaceBytes(.r8Uint, width: width, height: height, device: device)
    try Pipeline.checkBudget(program, width: width, height: height, device: device,
      maximumBytes: budget - mosaic.texture.allocatedSize - flagsBytes)
    let developed = try decoder.develop(mosaic, sampling: .native(nil), maximumBytes: budget)
    let fixed = mosaic.texture.allocatedSize + developed.sensorSaturation.allocatedSize
    let result = try Pipeline.run(program, image: developed.image,
      geometry: .init(width: developed.image.texture.width, height: developed.image.texture.height),
      maximumBytes: budget - fixed, provider: provider)
    self.program = program; native = result; flags = developed.sensorSaturation
    availableSampleBytes = budget - fixed - result.image.allocatedSize - result.masks.values.reduce(0) { $0 + $1.allocatedSize }
    guard let queue = device.makeCommandQueue() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    self.queue = queue
    let options = MTLCompileOptions(); options.mathMode = .safe
    let library = try device.makeLibrary(source: Self.kernel, options: options)
    guard let fn = library.makeFunction(name: "rmModelFit") else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    fit = try device.makeComputePipelineState(function: fn)
  }

  func sample(_ request: DevelopmentSceneRAWV1.Sampling, otherSampleBytes: Int = 0) throws
    -> (DevelopmentSceneRAWV1.Result, [UUID: MTLTexture], Int) {
    try Task.checkCancellation()
    let full = MTLRegionMake2D(0, 0, native.width, native.height)
    let rect: MTLRegion, isFit: Bool
    switch request {
    case .native(let region): rect = region ?? full; isFit = false
    case let .fit(width, height): rect = MTLRegionMake2D(0, 0, width, height); isFit = true
    }
    let w = rect.size.width, h = rect.size.height, x = rect.origin.x, y = rect.origin.y
    guard w > 0, h > 0, x >= 0, y >= 0, w <= native.width, h <= native.height, x <= native.width-w,
          y <= native.height-h, rect.origin.z == 0, rect.size.depth == 1 else { throw Pipeline.Failure.invalidImage }
    let origin = SIMD2(x,y)
    if w == native.width && h == native.height {
      return (.init(image: .init(texture: native.image, port: .working, origin: origin), sensorSaturation: flags), native.masks, 0)
    }
    let device = native.image.device
    let colorBytes = Pipeline.surfaceBytes(.rgba32Float, width: w, height: h, device: device)
    let maskBytes = isFit ? native.masks.count * Pipeline.surfaceBytes(.r32Float, width: w, height: h, device: device) : 0
    guard colorBytes + maskBytes + otherSampleBytes <= availableSampleBytes else { throw Pipeline.Failure.surfaceBudget }
    guard let cmd = queue.makeCommandBuffer() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    func sample(_ source: MTLTexture) throws -> MTLTexture {
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: w, height: h, mipmapped: false)
      d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
      guard let output = device.makeTexture(descriptor: d) else { throw Pipeline.Failure.surfaceBudget }
      if isFit {
        guard let e = cmd.makeComputeCommandEncoder() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
        e.setComputePipelineState(fit); e.setTexture(source, index: 0); e.setTexture(output, index: 1)
        let lanes = fit.threadExecutionWidth
        e.dispatchThreads(.init(width: w, height: h, depth: 1),
          threadsPerThreadgroup: .init(width: lanes, height: min(8, fit.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
        e.endEncoding()
      } else {
        guard let blit = cmd.makeBlitCommandEncoder() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: rect.origin, sourceSize: rect.size,
          to: output, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        blit.endEncoding()
      }
      return output
    }
    let color = try sample(native.image)
    // The graph takes masks in full geometry and applies the ROI origin itself.
    let masks = isFit ? try native.masks.mapValues(sample) : native.masks
    cmd.commit(); cmd.waitUntilCompleted()
    guard cmd.status == .completed else { throw cmd.error ?? DevelopmentSceneColorV1.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    let sampleBytes = color.allocatedSize + (isFit ? masks.values.reduce(0) { $0 + $1.allocatedSize } : 0)
    return (.init(image: .init(texture: color, port: .working, origin: origin), sensorSaturation: flags), masks, sampleBytes)
  }

  private static let kernel = #"""
  #include <metal_stdlib>
  using namespace metal;
  kernel void rmModelFit(texture2d<float,access::read> source [[texture(0)]],
      texture2d<float,access::write> target [[texture(1)]], uint2 xy [[thread_position_in_grid]]) {
    float2 size=float2(source.get_width(),source.get_height()), scale=size/float2(target.get_width(),target.get_height());
    float2 low=float2(xy)*scale, high=min(float2(xy+1)*scale,size);
    uint2 first=uint2(floor(low)), limit=uint2(ceil(high));
    float4 sum=0; float area=0;
    for (uint y=first.y; y<limit.y; ++y) {
      float wy=min(float(y+1),high.y)-max(float(y),low.y);
      for (uint x=first.x; x<limit.x; ++x) {
        float w=wy*(min(float(x+1),high.x)-max(float(x),low.x));
        sum+=source.read(uint2(x,y))*w; area+=w;
      }
    }
    float4 p=sum/area;
    target.write(float4(p.rgb,clamp(p.a,0.0f,1.0f)),xy);
  }
  """#
}
