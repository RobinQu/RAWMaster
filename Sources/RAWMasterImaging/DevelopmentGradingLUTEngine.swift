import CoreImage
import Foundation
import RAWMasterCore

/// A table is uploaded once per content digest. Strength, order and masks stay in the deferred Metal graph.
enum DevelopmentGradingLUTEngine {
  static let version = "grading-lut-v1/display-srgb/trilinear-f32/linear-mix"

  private static let tables: NSCache<NSString, CIImage> = {
    let cache = NSCache<NSString, CIImage>()
    cache.totalCostLimit = 32 * 1024 * 1024
    return cache
  }()
  private static let kernel = Result<CIKernel, Error> {
    guard let kernel = try CIKernel.kernels(withMetalString: metal).first(where: { $0.name == "rmGradingLUT" }) else {
      throw DevelopmentV3Error.invalidGraph
    }
    return kernel
  }

  static func apply(_ stack: DevelopmentLUTStack?, to image: CIImage) throws -> CIImage {
    guard let stack, stack.isActive else { return image }
    return try stack.layers.reduce(image) { try apply($1, to: $0) }
  }

  static func apply(_ layer: DevelopmentLUTLayer, to image: CIImage) throws -> CIImage {
    guard layer.amount > 0 else { return image }
    let cube = layer.cube
    let telemetry = ImagePerformanceTelemetry.shared
    let ticket = telemetry.begin(operation: "DevelopmentGradingLUTEngine.apply", stage: "\(cube.dimension)³ LUT 图构建", boundary: .graphBuild)
    var outcome = ImagePerformanceOutcome.failed
    defer { telemetry.end(ticket, outcome: outcome) }
    let table = atlas(cube)
    func vector(_ v: SIMD3<Float>) -> CIVector {
      CIVector(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z))
    }
    let settings = CIVector(x: CGFloat(cube.dimension), y: CGFloat(layer.amount / 100))
    guard let output = try kernel.get().apply(extent: image.extent, roiCallback: { index, rect in
      index == 0 ? rect : table.extent
    }, arguments: [image, table.samplingNearest(), vector(cube.domainMin), vector(cube.domainMax), settings]) else {
      throw DevelopmentV3Error.invalidGraph
    }
    outcome = .succeeded
    return output
  }

  private static func atlas(_ cube: DevelopmentColorLUT) -> CIImage {
    let key = cube.id as NSString
    if let table = tables.object(forKey: key) { return table }
    let d = cube.dimension
    var rgba = Data(count: d * d * d * 16)
    cube.rgb.withUnsafeBytes { source in
      rgba.withUnsafeMutableBytes { target in
        let rgba = target.bindMemory(to: UInt32.self)
        let alpha = Float(1).bitPattern
        for node in 0..<(d * d * d) {
          for c in 0..<3 {
            rgba[4 * node + c] = UInt32(littleEndian: source.loadUnaligned(fromByteOffset: (3 * node + c) * 4, as: UInt32.self))
          }
          rgba[4 * node + 3] = alpha
        }
      }
    }
    let table = CIImage(bitmapData: rgba, bytesPerRow: d * 16, size: CGSize(width: d, height: d * d),
                        format: .RGBAf, colorSpace: nil)
    tables.setObject(table, forKey: key, cost: rgba.count)
    return table
  }

  private static let metal = #"""
  #include <metal_stdlib>
  #include <CoreImage/CoreImage.h>
  using namespace metal;
  extern "C" { namespace coreimage {
    float rmLUTencode(float x) { return x <= .0031308 ? 12.92*x : 1.055*pow(x, 1.0/2.4)-.055; }
    float rmLUTdecode(float x) { return x <= .04045 ? x/12.92 : pow((x+.055)/1.055, 2.4); }
    float3 rmLUTnode(sampler table, int3 node, int d) {
      // CIImage(bitmapData:) stores the first physical row at the top of its extent.
      float2 at = float2(node.x, d*d - 1 - (node.y + d*node.z)) + .5;
      return table.sample(table.transform(at)).rgb;
    }
    [[stitchable]] float4 rmGradingLUT(sampler input, sampler table, float3 lo, float3 hi, float2 settings, destination dest) {
      float4 p = input.sample(input.transform(dest.coord()));
      if (p.a <= 0 || !all(isfinite(p))) return p;
      float3 linear = p.rgb / p.a;
      float3 encoded = float3(rmLUTencode(linear.r), rmLUTencode(linear.g), rmLUTencode(linear.b));
      int d = int(settings.x);
      float3 pos = saturate((encoded-lo)/(hi-lo)) * float(d-1);
      int3 cell = min(int3(floor(pos)), int3(d-2));
      float3 f = pos - float3(cell);
      float3 a = mix(rmLUTnode(table, cell, d), rmLUTnode(table, cell+int3(1,0,0), d), f.x);
      float3 b = mix(rmLUTnode(table, cell+int3(0,1,0), d), rmLUTnode(table, cell+int3(1,1,0), d), f.x);
      float3 c = mix(rmLUTnode(table, cell+int3(0,0,1), d), rmLUTnode(table, cell+int3(1,0,1), d), f.x);
      float3 e = mix(rmLUTnode(table, cell+int3(0,1,1), d), rmLUTnode(table, cell+int3(1,1,1), d), f.x);
      float3 out = mix(mix(a,b,f.y), mix(c,e,f.y), f.z);
      float3 mapped = float3(rmLUTdecode(out.r), rmLUTdecode(out.g), rmLUTdecode(out.b));
      return float4(mix(linear, mapped, settings.y) * p.a, p.a);
    }
  } }
  """#
}
