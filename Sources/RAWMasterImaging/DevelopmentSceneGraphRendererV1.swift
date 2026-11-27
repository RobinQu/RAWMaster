import Foundation
import Metal
import RAWMasterCore

/// Executes a validated AP1 graph without CPU pixel transport. Public delivery can only take `prepareFinal`.
final class DevelopmentSceneGraphRendererV1 {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Image = DevelopmentSceneMetalV1.Image
  typealias Target = DevelopmentSceneOutputStateV1.Target

  enum Failure: Error, Equatable { case invalidImage, invalidPixel, unsupportedSDRTrim, surfaceBudget }

  struct Geometry {
    let width, height: Int
  }

  struct Master {
    fileprivate let surface: Surface
    fileprivate let output: DevelopmentSceneOutputStateV1.Version
    var image: Image { Image(texture: surface.texture, port: .working, origin: surface.origin) }
  }

  fileprivate final class Budget {
    let maximum: Int
    var used: Int
    init(maximum: Int, input: Int) { self.maximum = maximum; used = input }
    func reserve(_ size: Int) throws {
      guard size <= maximum - used else { throw Failure.surfaceBudget }
      used += size
    }
  }

  fileprivate final class Surface {
    enum Domain { case image, coverage }
    let texture: MTLTexture
    let origin: SIMD2<Int>
    let domain: Domain
    private let budget: Budget?
    init(texture: MTLTexture, origin: SIMD2<Int>, domain: Domain, budget: Budget? = nil) {
      self.texture = texture; self.origin = origin; self.domain = domain; self.budget = budget
    }
    deinit { budget?.used -= texture.allocatedSize }
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let color, coverage: MTLComputePipelineState
  private let surfaceBudget: Int

  init(device: MTLDevice, surfaceBudget: Int = 1_536 * 1024 * 1024) throws {
    let options = MTLCompileOptions(); options.mathMode = .safe
    let library = try device.makeLibrary(source: Self.shader, options: options)
    guard let color = library.makeFunction(name: "rmDagColorV1"), let coverage = library.makeFunction(name: "rmDagCoverageV1"),
          let queue = device.makeCommandQueue() else { throw DevelopmentSceneColorV1.Failure.metalUnavailable }
    self.queue = queue; self.device = device
    self.color = try device.makeComputePipelineState(function: color)
    self.coverage = try device.makeComputePipelineState(function: coverage)
    self.surfaceBudget = surfaceBudget
  }

  func prepareFinal(_ image: Image, geometry: Geometry, graph: Graph) throws -> Master {
    let surface = try execute(image, geometry: geometry, graph: graph, view: .init())
    guard surface.domain == .image else { throw Failure.invalidImage }
    return .init(surface: surface, output: graph.output)
  }

  // Preview selections deliberately use a separate type that cannot become a delivery Master.
  struct PreviewScene {
    fileprivate let surface: Surface
    var image: Image { Image(texture: surface.texture, port: .working, origin: surface.origin) }
  }

  func renderDelivery(_ master: Master, target: Target) throws -> DevelopmentSceneOutputV1.DisplayImage {
    try render(master.image, output: master.output, target: target)
  }

  func preparePreview(_ image: Image, geometry: Geometry, graph: Graph, view: Graph.View) throws -> PreviewScene {
    let selected = try execute(image, geometry: geometry, graph: graph, view: view)
    guard selected.domain == .image else { throw Failure.invalidImage }
    return PreviewScene(surface: selected)
  }

  func renderPreview(_ image: Image, geometry: Geometry, graph: Graph, view: Graph.View,
                     viewing: DevelopmentSceneOutputStateV1.ViewingConditions) throws -> DevelopmentSceneOutputV1.DisplayImage {
    try renderPreview(preparePreview(image, geometry: geometry, graph: graph, view: view), output: graph.output, target: viewing.displayedTarget)
  }

  func renderPreview(_ scene: PreviewScene, output: DevelopmentSceneOutputStateV1.Version,
                     target: Target) throws -> DevelopmentSceneOutputV1.DisplayImage {
    try render(scene.image, output: output, target: target)
  }

  private var outputStages: [Target: DevelopmentSceneOutputV1] = [:]
  private var exposureStage: DevelopmentSceneMetalV1?
  private func render(_ image: Image, output: DevelopmentSceneOutputStateV1.Version,
                      target: Target) throws -> DevelopmentSceneOutputV1.DisplayImage {
    let branch: Image
    let trim = output.sdrTrim
    if target == .sdr709 {
      guard trim.mapping == .balanced, trim.highlightCompression == 0, trim.film == nil else { throw Failure.unsupportedSDRTrim }
      if trim.exposureEV == 0 { branch = image }
      else {
        let exposure = try exposureStage ?? DevelopmentSceneMetalV1(device: device)
        exposureStage = exposure
        branch = try exposure.render(image, exposureEV: Float(trim.exposureEV))
      }
    } else { branch = image }
    let stage = try outputStages[target] ?? DevelopmentSceneOutputV1(device: device, target: target)
    outputStages[target] = stage
    return try stage.render(branch)
  }

  private func execute(_ image: Image, geometry: Geometry, graph: Graph, view: Graph.View) throws -> Surface {
    try Task.checkCancellation()
    let t = image.texture
    guard image.port == .working, t.device === device, t.textureType == .type2D, t.pixelFormat == .rgba32Float,
          !t.isFramebufferOnly, t.storageMode != .memoryless, t.usage.isEmpty || t.usage.contains(.shaderRead),
          (1...16_384).contains(geometry.width), (1...16_384).contains(geometry.height),
          image.origin.x >= 0, image.origin.y >= 0,
          image.origin.x <= geometry.width - t.width, image.origin.y <= geometry.height - t.height else { throw Failure.invalidImage }
    guard t.allocatedSize <= surfaceBudget else { throw Failure.surfaceBudget }
    let budget = Budget(maximum: surfaceBudget, input: t.allocatedSize)
    return try evaluate(graph.graph, input: Surface(texture: t, origin: image.origin, domain: .image), geometry: geometry, budget: budget,
      groupPath: view.groupPath[...], target: view.target)
  }

  private func evaluate(_ scope: Graph.Scope, input: Surface, geometry: Geometry, budget: Budget,
                        groupPath: ArraySlice<UUID> = [], target: Graph.View.Target = .final) throws -> Surface {
    let operations = Dictionary(uniqueKeysWithValues: scope.nodes.map { ($0.id, $0.operation) })
    if let first = groupPath.first {
      guard case let .group(image, child, _, _)? = operations[first] else { throw Graph.Failure.unknownGroup(first) }
      // Entering a group examines its own pipeline even if the group is bypassed in the parent.
      let base = try evaluate(scope, input: input, geometry: geometry, budget: budget, target: Self.target(for: image))
      return try evaluate(child, input: base, geometry: geometry, budget: budget, groupPath: groupPath.dropFirst(), target: target)
    }
    let output: Graph.Endpoint
    switch target {
    case .final: output = scope.output
    case .node(let id):
      guard let operation = operations[id], !operation.isCoverage else { throw Graph.Failure.unknownNode(id) }
      output = .node(id)
    case .bypass: output = .input
    }
    guard case let .node(last) = output else { return input }
    var uses: [UUID: Int] = [last: 1], dependencies: [UUID: [Graph.Endpoint]] = [:], steps: [UUID] = []
    func visit(_ id: UUID) {
      guard dependencies[id] == nil, let operation = operations[id] else { return }
      let inputs = Self.usedInputs(operation)
      dependencies[id] = inputs
      for endpoint in inputs {
        if case let .node(parent) = endpoint { uses[parent, default: 0] += 1; visit(parent) }
      }
      steps.append(id)
    }
    visit(last)
    var memo: [UUID: Surface] = [:]
    func value(_ endpoint: Graph.Endpoint) throws -> Surface {
      switch endpoint {
      case .input: return input
      case .node(let id):
        guard let value = memo[id] else { throw Graph.Failure.missingNode(id) }
        return value
      }
    }
    for id in steps {
      try Task.checkCancellation()
      guard let op = operations[id] else { throw Graph.Failure.missingNode(id) }
      let surface: Surface
      switch op {
      case let .corrector(image, mask, ev, curve, strength, enabled):
        let base = try value(image)
        if !enabled || strength == 0 || Self.neutral(ev, curve) { surface = base }
        else {
          surface = try dispatch(color, kind: 0, input: base, secondary: mask.map { try value(.node($0)) },
            geometry: geometry, budget: budget, scalars: .init(exp2(ev), strength, Float(curve.count), mask == nil ? 0 : 1), curve: curve)
        }
      case let .parallel(image, layers, enabled), let .layer(image, layers, enabled):
        let base = try value(image)
        let parallel: Bool
        if case .parallel = op { parallel = true } else { parallel = false }
        var current = base
        if enabled {
          for layer in layers where layer.weight > 0 {
            let branch = try value(layer.image)
            if (parallel && branch === base) || (!parallel && layer.mode == .normal && branch === current) { continue }
            if !parallel && layer.mode == .normal && layer.weight == 1 { current = branch; continue }
            current = try dispatch(color, kind: parallel ? 2 : 1, input: current, secondary: branch, original: base,
              geometry: geometry, budget: budget, scalars: .init(layer.weight, Float(Self.mode(layer.mode)), 0, 0))
          }
        }
        surface = current
      case let .group(image, child, strength, enabled):
        let base = try value(image)
        if !enabled || strength == 0 { surface = base }
        else {
          let rendered = try evaluate(child, input: base, geometry: geometry, budget: budget)
          if strength == 1 || rendered === base { surface = rendered }
          else { surface = try dispatch(color, kind: 1, input: base, secondary: rendered, geometry: geometry,
            budget: budget, scalars: .init(strength, 0, 0, 0)) }
        }
      case let .linearCoverage(start, end):
        surface = try dispatch(coverage, kind: 0, input: input, geometry: geometry, budget: budget, scalars: .init(start.x, start.y, end.x, end.y))
      case let .radialCoverage(center, radii, feather):
        surface = try dispatch(coverage, kind: 1, input: input, geometry: geometry, budget: budget,
          scalars: .init(center.x, center.y, radii.x, radii.y), parameter: UInt32(feather.bitPattern))
      case let .combineCoverage(base, other, mode):
        let modeIndex: Float = mode == .add ? 0 : mode == .subtract ? 1 : 2
        surface = try dispatch(coverage, kind: 2, input: value(.node(base)), secondary: value(.node(other)),
          geometry: geometry, budget: budget, scalars: .init(modeIndex, 0, 0, 0))
      case let .adjustCoverage(mask, strength, inverted):
        surface = try dispatch(coverage, kind: 3, input: value(.node(mask)), geometry: geometry, budget: budget,
          scalars: .init(strength, inverted ? 1 : 0, 0, 0))
      }
      memo[id] = surface
      for endpoint in dependencies[id, default: []] {
        if case let .node(parent) = endpoint {
          uses[parent, default: 0] -= 1
          if uses[parent] == 0 { memo.removeValue(forKey: parent) }
        }
      }
    }
    return try value(output)
  }

  private static func target(for endpoint: Graph.Endpoint) -> Graph.View.Target {
    switch endpoint { case .input: return .bypass; case .node(let id): return .node(id) }
  }

  private static func neutral(_ ev: Float, _ points: [SIMD2<Float>]) -> Bool { ev == 0 && points.allSatisfy { $0.x == $0.y } }

  private static func usedInputs(_ op: Graph.Operation) -> [Graph.Endpoint] {
    switch op {
    case let .corrector(image, mask, ev, curve, strength, enabled):
      return [image] + (enabled && strength > 0 && !neutral(ev, curve) ? mask.map { [.node($0)] } ?? [] : [])
    case let .parallel(base, layers, enabled), let .layer(base, layers, enabled):
      return [base] + (enabled ? layers.filter { $0.weight > 0 }.map(\.image) : [])
    case let .group(image, _, _, _): return [image]
    case let .combineCoverage(base, other, _): return [.node(base), .node(other)]
    case let .adjustCoverage(mask, _, _): return [.node(mask)]
    case .linearCoverage, .radialCoverage: return []
    }
  }

  private static func mode(_ blend: Graph.Blend) -> UInt32 {
    switch blend {
    case .normal: return 0
    case .add: return 1
    case .subtract: return 2
    case .multiply: return 3
    case .screen: return 4
    case .overlay: return 5
    case .softLight: return 6
    case .hardLight: return 7
    case .lighten: return 8
    case .darken: return 9
    case .difference: return 10
    case .color: return 11
    case .luminosity: return 12
    }
  }

  private struct Parameters {
    var scalars: SIMD4<Float>
    var geometry: SIMD4<UInt32>
    var kind, parameter: UInt32
  }

  private func dispatch(_ pipeline: MTLComputePipelineState, kind: UInt32, input: Surface, secondary: Surface? = nil,
                        original: Surface? = nil, geometry: Geometry, budget: Budget, scalars: SIMD4<Float>,
                        parameter: UInt32 = 0, curve: [SIMD2<Float>] = []) throws -> Surface {
    let source = input.texture, origin = input.origin
    let isColor = pipeline === color
    guard original.map({ $0.domain == .image }) ?? true else { throw Failure.invalidImage }
    if isColor {
      guard input.domain == .image, secondary.map({ $0.domain == (kind == 0 ? .coverage : .image) }) ?? true else { throw Failure.invalidImage }
    } else if kind >= 2 {
      guard input.domain == .coverage, secondary.map({ $0.domain == .coverage }) ?? true else { throw Failure.invalidImage }
    }
    let format: MTLPixelFormat = isColor ? .rgba32Float : .r32Float
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: source.width, height: source.height, mipmapped: false)
    descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
    let estimate = device.heapTextureSizeAndAlign(descriptor: descriptor).size
    guard estimate <= budget.maximum - budget.used else { throw Failure.surfaceBudget }
    guard let texture = device.makeTexture(descriptor: descriptor), let flag = device.makeBuffer(length: 4, options: .storageModeShared),
          let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeComputeCommandEncoder() else {
      throw DevelopmentSceneColorV1.Failure.metalUnavailable
    }
    try budget.reserve(texture.allocatedSize)
    let result = Surface(texture: texture, origin: origin, domain: isColor ? .image : .coverage, budget: budget)
    let invalid = flag.contents().bindMemory(to: UInt32.self, capacity: 1); invalid.pointee = 0
    var p = Parameters(scalars: scalars, geometry: .init(UInt32(origin.x), UInt32(origin.y), UInt32(geometry.width), UInt32(geometry.height)),
      kind: kind, parameter: parameter)
    encoder.setComputePipelineState(pipeline)
    encoder.setBytes(&p, length: MemoryLayout<Parameters>.stride, index: 0)
    encoder.setBuffer(flag, offset: 0, index: 1)
    encoder.setTexture(source, index: 0); encoder.setTexture(secondary?.texture ?? source, index: 1)
    if format == .rgba32Float {
      encoder.setTexture(original?.texture ?? source, index: 2); encoder.setTexture(texture, index: 3)
      let values = curve.isEmpty ? [SIMD2<Float>.zero] : curve
      values.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
    } else { encoder.setTexture(texture, index: 2) }
    let lanes = pipeline.threadExecutionWidth
    encoder.dispatchThreads(.init(width: texture.width, height: texture.height, depth: 1),
      threadsPerThreadgroup: .init(width: lanes, height: min(8, pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
    encoder.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
    guard cmd.status == .completed else { throw cmd.error ?? DevelopmentSceneColorV1.Failure.gpuExecutionFailed }
    try Task.checkCancellation()
    guard invalid.pointee == 0 else { throw Failure.invalidPixel }
    return result
  }

  private static let shader = #"""
#include <metal_stdlib>
using namespace metal;
struct Parameters { float4 scalars; uint4 geometry; uint kind; uint parameter; };
constant float3 ap1Y = float3(0.2722287168f, 0.6740817658f, 0.0536895174f);
float exposureDelta(float ev, constant float2* points, uint count) {
  if (ev <= points[0].x) return points[0].y - points[0].x;
  for (uint i = 1; i < count; ++i) {
    float2 a = points[i-1], b = points[i];
    if (ev <= b.x) return mix(a.y-a.x, b.y-b.x, (ev-a.x)/(b.x-a.x));
  }
  return points[count-1].y - points[count-1].x;
}
float3 soft(float3 b, float3 s) {
  float3 d = select(sqrt(b), ((16.0f*b-12.0f)*b+4.0f)*b, b <= 0.25f);
  return select(b + (2.0f*s-1.0f)*(d-b), b - (1.0f-2.0f*s)*b*(1.0f-b), s <= 0.5f);
}
float3 blend(float3 b, float3 s, uint mode) {
  switch (mode) {
    case 0: return s;
    case 1: return b + s;
    case 2: return b - s;
    case 3: return b * s;
    case 8: return max(b,s);
    case 9: return min(b,s);
    case 10: return abs(b-s);
    case 11: return s + (dot(b,ap1Y)-dot(s,ap1Y));
    case 12: return b + (dot(s,ap1Y)-dot(b,ap1Y));
  }
  // Defined bounded blend around scene anchor 1, with the signed/highlight residual retained.
  float3 x = clamp(b,0.0f,1.0f), y = clamp(s,0.0f,1.0f);
  float3 screen = 1.0f-2.0f*(1.0f-x)*(1.0f-y), multiply = 2.0f*x*y;
  float3 z = mode == 4 ? x+y-x*y : mode == 5 ? select(screen,multiply,x <= 0.5f)
    : mode == 6 ? soft(x,y) : select(screen,multiply,y <= 0.5f);
  return z+(b-x)+(s-y);
}
kernel void rmDagColorV1(texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::read> other [[texture(1)]], texture2d<float,access::read> base [[texture(2)]],
    texture2d<float,access::write> output [[texture(3)]], constant Parameters& p [[buffer(0)]],
    device atomic_uint& invalid [[buffer(1)]], constant float2* curve [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
  float4 a = input.read(xy);
  if (!all(isfinite(a)) || a.a < 0 || a.a > 1) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  if (a.a == 0) { output.write(float4(0),xy); return; }
  float3 rgb;
  if (p.kind == 0) {
    float w = p.scalars.y * (p.scalars.w == 0 ? 1.0f : other.read(xy).r);
    float gain = p.scalars.x;
    float luma = dot(a.rgb,ap1Y);
    if (p.scalars.z > 0 && luma > 0) gain *= exp2(exposureDelta(log2(luma)-log2(a.a)+log2(gain),curve,uint(p.scalars.z)));
    rgb = w == 0 ? a.rgb : a.rgb * mix(1.0f,gain,w);
  } else {
    float4 b = other.read(xy);
    if (!all(isfinite(b)) || a.a != b.a) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
    if (p.kind == 2) rgb = a.rgb + p.scalars.x*(b.rgb-base.read(xy).rgb);
    else if (p.scalars.y == 0) rgb = mix(a.rgb,b.rgb,p.scalars.x);
    else rgb = mix(a.rgb,blend(a.rgb/a.a,b.rgb/a.a,uint(p.scalars.y))*a.a,p.scalars.x);
  }
  if (!all(isfinite(rgb))) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  output.write(float4(rgb,a.a),xy);
}
kernel void rmDagCoverageV1(texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::read> other [[texture(1)]], texture2d<float,access::write> output [[texture(2)]],
    constant Parameters& p [[buffer(0)]], device atomic_uint& invalid [[buffer(1)]], uint2 xy [[thread_position_in_grid]]) {
  float c;
  float2 q = (float2(p.geometry.xy+xy)+0.5f)/float2(p.geometry.zw);
  if (p.kind == 0) {
    float2 axis=p.scalars.zw-p.scalars.xy;
    c = clamp(dot(q-p.scalars.xy,axis)/dot(axis,axis),0.0f,1.0f);
  } else if (p.kind == 1) {
    float f = as_type<float>(p.parameter), r = length((q-p.scalars.xy)/p.scalars.zw);
    c = f == 0 ? (r<=1.0f ? 1.0f : 0.0f) : 1.0f-smoothstep(1.0f-f,1.0f,r);
  } else if (p.kind == 2) {
    float a=input.read(xy).r, b=other.read(xy).r;
    c = p.scalars.x == 0 ? a+b*(1.0f-a) : p.scalars.x == 1 ? a*(1.0f-b) : a*b;
  } else {
    float a = input.read(xy).r;
    c = (p.scalars.y == 0 ? a : 1.0f-a)*p.scalars.x;
  }
  if (!isfinite(c)) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  output.write(float4(clamp(c,0.0f,1.0f),0,0,1),xy);
}
"""#
}
