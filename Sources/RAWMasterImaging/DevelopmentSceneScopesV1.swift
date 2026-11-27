import CoreGraphics
import Foundation
import Metal
import RAWMasterCore
import simd

package struct DevelopmentSceneScopesV1: Sendable {
  package enum Stage: String, CaseIterable, Identifiable, Sendable {
    case scene, target, derivative
    package var id: Self { self }
  }
  package enum Overlay: String, CaseIterable, Identifiable, Hashable, Sendable {
    case sensor, target, screen, bands
    package var id: Self { self }
  }
  package struct Sample: Sendable {
    package let sceneRGB, targetRGB, derivativeRGB: SIMD3<Float>
    package let sensorBits: UInt8?
    package let targetExceeded: Bool?
    package let monitorMaximum: Float?

    package func rgb(_ stage: Stage) -> SIMD3<Float> {
      switch stage { case .scene: return sceneRGB; case .target: return targetRGB; case .derivative: return derivativeRGB }
    }
    package func luminance(_ stage: Stage) -> Float {
      let weights: SIMD3<Float>
      switch stage {
      case .scene: weights = .init(0.27222872, 0.67408174, 0.053689517)
      case .target: weights = .init(0.2627, 0.6780, 0.0593)
      case .derivative: weights = .init(0.2126, 0.7152, 0.0722)
      }
      return simd_dot(rgb(stage), weights)
    }
  }
  package struct Plot: Sendable {
    /// negative, 16 linear bins through white, and four 1 EV bins above white; last includes overflow.
    package let bins: [Int]
    package let minimum, maximum: Float
  }
  package let size: SIMD2<Int>
  package let samples: [Sample]
  package let plots: [Stage: Plot]
  package let canMeasureSensor, canMeasureTarget, canMeasureScreen: Bool
  package let execution: DevelopmentSceneExecutionReceiptV1?

  package func forMonitor(_ monitor: SceneScopesMonitorV1?) -> Self {
    .init(size: size, samples: samples.map { row in
      .init(sceneRGB: row.sceneRGB, targetRGB: row.targetRGB, derivativeRGB: row.derivativeRGB, sensorBits: row.sensorBits,
            targetExceeded: row.targetExceeded, monitorMaximum: monitor?.maximum(row.targetRGB))
    }, plots: plots, canMeasureSensor: canMeasureSensor, canMeasureTarget: canMeasureTarget,
       canMeasureScreen: monitor != nil, execution: execution)
  }

  package func sample(at unit: CGPoint) -> Sample? {
    guard unit.x.isFinite, unit.y.isFinite, (0...1).contains(unit.x), (0...1).contains(unit.y) else { return nil }
    let x = min(size.x - 1, Int(unit.x * CGFloat(size.x))), y = min(size.y - 1, Int(unit.y * CGFloat(size.y)))
    return samples[y * size.x + x]
  }
  package func marked(_ kind: Overlay, in sample: Sample, headroom: Float) -> Bool? {
    switch kind {
    case .sensor: return sample.sensorBits.map { $0 != 0 }
    case .target: return sample.targetExceeded
    case .screen: return sample.monitorMaximum.map { $0 > headroom }
    case .bands: return sample.luminance(.target) > 1
    }
  }
  package func count(_ kind: Overlay, headroom: Float) -> Int? {
    switch kind {
    case .sensor where !canMeasureSensor, .target where !canMeasureTarget, .screen where !canMeasureScreen: return nil
    default: return samples.reduce(0) { $0 + (marked(kind, in: $1, headroom: headroom) == true ? 1 : 0) }
    }
  }
  // Fixed anchor regardless of monitor or sample range. Scene units are not nits.
  package static func bin(_ value: Float) -> Int {
    if value < 0 { return 0 }
    if value <= 1 { return 1 + min(15, Int(value * 16)) }
    return 17 + min(3, Int(log2(value)))
  }
}

/// Monitor ICC matrices are taken from an extended-linear ColorSync transform, not a PQ/code-value comparison.
/// Non-matrix profiles, clipped transforms or non-linear verification probes leave screen evidence unavailable.
package struct SceneScopesMonitorV1: Equatable, Sendable {
  let red, green, blue: SIMD3<Float> // rows
  package init?(icc: Data) {
    guard let device = CGColorSpace(iccData: icc as CFData),
          let linear = CGColorSpaceCreateExtendedLinearized(device), CGColorSpaceUsesExtendedRange(linear),
          let source = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { return nil }
    func convert(_ x: SIMD3<Float>) -> SIMD3<Float>? {
      guard let color = CGColor(colorSpace: source, components: [CGFloat(x.x), CGFloat(x.y), CGFloat(x.z), 1]),
            let y = color.converted(to: linear, intent: .relativeColorimetric, options: nil)?.components, y.count == 4 else { return nil }
      let v = SIMD3(Float(y[0]), Float(y[1]), Float(y[2]))
      return v.x.isFinite && v.y.isFinite && v.z.isFinite ? v : nil
    }
    guard let r = convert(.init(1,0,0)), let g = convert(.init(0,1,0)), let b = convert(.init(0,0,1)) else { return nil }
    for probe: SIMD3<Float> in [.zero, .init(1,1,1), .init(4,4,4), .init(-0.1, 2.5, 0.4), .init(2,0,0)] {
      guard let observed = convert(probe), simd_length(observed - (r * probe.x + g * probe.y + b * probe.z)) < 5e-3 else { return nil }
    }
    red = .init(r.x, g.x, b.x); green = .init(r.y, g.y, b.y); blue = .init(r.z, g.z, b.z)
  }

  func maximum(_ rgb: SIMD3<Float>) -> Float { max(simd_dot(red,rgb), simd_dot(green,rgb), simd_dot(blue,rgb)) }
}

final class SceneScopesAnalyzerV1 {
  private struct GPURecord {
    var scene, target, sdr, evidence: SIMD4<Float>
  }
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let emptySensor: MTLTexture

  init(device: MTLDevice) throws {
    let options = MTLCompileOptions(); options.mathMode = .safe
    let library = try device.makeLibrary(source: Self.shader, options: options)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: 1, height: 1, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let fn = library.makeFunction(name: "rmSceneScopesV1"), let q = device.makeCommandQueue(), let sensor = device.makeTexture(descriptor: descriptor) else {
      throw DevelopmentSceneColorV1.Failure.metalUnavailable
    }
    self.device = device; queue = q; emptySensor = sensor
    pipeline = try device.makeComputePipelineState(function: fn)
  }

  func analyze(scene: MTLTexture, target: MTLTexture, derivative: MTLTexture, preGamut: MTLTexture?,
               sourceSensor: MTLTexture?, monitor: SceneScopesMonitorV1?,
               execution: DevelopmentSceneExecutionReceiptV1? = nil) throws -> DevelopmentSceneScopesV1 {
    try Task.checkCancellation()
    let w = scene.width, h = scene.height
    guard (1...256).contains(w), (1...256).contains(h), [scene,target,derivative,preGamut ?? target].allSatisfy({
      $0.width == w && $0.height == h && $0.device === device && $0.pixelFormat == .rgba32Float
    }), sourceSensor.map({ $0.device === device && $0.pixelFormat == .r8Uint }) ?? true else { throw DevelopmentError.invalidEncoding }
    guard let buffer = device.makeBuffer(length: w*h*MemoryLayout<GPURecord>.stride, options: .storageModeShared),
          let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    var options = SIMD4<UInt32>(sourceSensor == nil ? 0 : 1, preGamut == nil ? 0 : 1, 0, 0)
    enc.setComputePipelineState(pipeline)
    enc.setTexture(scene,index:0); enc.setTexture(target,index:1); enc.setTexture(derivative,index:2)
    enc.setTexture(preGamut ?? target,index:3); enc.setTexture(sourceSensor ?? emptySensor,index:4)
    enc.setBuffer(buffer,offset:0,index:0); enc.setBytes(&options,length:16,index:1)
    let lanes = pipeline.threadExecutionWidth
    enc.dispatchThreads(.init(width:w,height:h,depth:1),threadsPerThreadgroup:.init(width:lanes,height:min(8,pipeline.maxTotalThreadsPerThreadgroup/lanes),depth:1))
    enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
    guard cmd.status == .completed else { throw cmd.error ?? DevelopmentSceneColorV1.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    let rows = UnsafeBufferPointer(start:buffer.contents().assumingMemoryBound(to:GPURecord.self),count:w*h)
    let samples: [DevelopmentSceneScopesV1.Sample] = try rows.map { record in
      func rgb(_ v: SIMD4<Float>) -> SIMD3<Float> { .init(v.x,v.y,v.z) }
      guard record.evidence.z == 0 else { throw DevelopmentSceneOutputV1.Failure.invalidPixel }
      let shown = rgb(record.target)
      return .init(sceneRGB:rgb(record.scene), targetRGB:shown, derivativeRGB:rgb(record.sdr),
                   sensorBits:sourceSensor == nil ? nil : UInt8(record.evidence.x),
                   targetExceeded:preGamut == nil ? nil : record.evidence.y != 0, monitorMaximum:monitor?.maximum(shown))
    }
    let plots = Dictionary(uniqueKeysWithValues: DevelopmentSceneScopesV1.Stage.allCases.map { stage in
      var bins = [Int](repeating:0,count:21), low = Float.infinity, high = -Float.infinity
      for row in samples {
        let y = row.luminance(stage)
        bins[DevelopmentSceneScopesV1.bin(y)] += 1; low = min(low,y); high = max(high,y)
      }
      return (stage, DevelopmentSceneScopesV1.Plot(bins:bins,minimum:low,maximum:high))
    })
    return .init(size:.init(w,h), samples:samples, plots:plots,
                 canMeasureSensor:sourceSensor != nil, canMeasureTarget:preGamut != nil, canMeasureScreen:monitor != nil,
                 execution:execution)
  }

  private static let shader = #"""
  #include <metal_stdlib>
  using namespace metal;
  struct Record { float4 scene, hdr, sdr, evidence; };
  float4 straight(float4 p) { return p.a > 0.0f ? float4(p.rgb/p.a,p.a) : float4(0); }
  kernel void rmSceneScopesV1(texture2d<float,access::read> scene [[texture(0)]],
    texture2d<float,access::read> hdr [[texture(1)]],texture2d<float,access::read> sdr [[texture(2)]],
    texture2d<float,access::read> unbounded [[texture(3)]],texture2d<uint,access::read> saturated [[texture(4)]],
    device Record* records [[buffer(0)]],constant uint4& mode [[buffer(1)]],uint2 xy [[thread_position_in_grid]]) {
    uint2 size=uint2(scene.get_width(),scene.get_height()),full=uint2(saturated.get_width(),saturated.get_height());
    uint2 source=min(uint2((float2(xy)+0.5f)*float2(full)/float2(size)),full-1);
    float4 a=straight(scene.read(xy)), b=straight(hdr.read(xy)), c=straight(sdr.read(xy)), u=straight(unbounded.read(xy));
    uint bits=mode.x ? saturated.read(source).x & 7u : 0u;
    float excess=mode.y && (any(u.rgb < -2e-4f)||any(u.rgb > 10.0002f)) ? 1.0f : 0.0f;
    float invalid=all(isfinite(a))&&all(isfinite(b))&&all(isfinite(c))&&all(isfinite(u)) ? 0.0f : 1.0f;
    records[xy.y*size.x+xy.x]={a,b,c,float4(float(bits),excess,invalid,0)};
  }
  """#
}
