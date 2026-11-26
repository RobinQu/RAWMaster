import Foundation
import Metal

final class DevelopmentSceneToneV1 {
  enum Failure: Error, Equatable { case invalidCurve, invalidInput, invalidPixel }
  typealias MetalFailure = DevelopmentSceneColorV1.Failure

  struct Curve {
    let points: [SIMD2<Float>]
    static let identity = Curve(points: [.init(-12,-12),.init(8,8)])

    private init(points: [SIMD2<Float>]) { self.points=points }
    init(exposureStops: [SIMD2<Float>]) throws {
      guard (2...16).contains(exposureStops.count),
            exposureStops.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 24 && abs($0.y) <= 24 }),
            zip(exposureStops,exposureStops.dropFirst()).allSatisfy({ b,a in a.x-b.x >= 0.001 && a.y >= b.y }) else {
        throw Failure.invalidCurve
      }
      points=exposureStops
    }
  }

  struct Coverage {
    let texture: MTLTexture
    let origin: SIMD2<Int>
  }

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let emptyCoverage: MTLTexture

  init(device: MTLDevice) throws {
    let options=MTLCompileOptions(); options.mathMode = .safe
    let library=try device.makeLibrary(source:Self.kernel,options:options)
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:1,height:1,mipmapped:false)
    d.storageMode = .shared; d.usage = .shaderRead
    guard let function=library.makeFunction(name:"rmSceneToneV1"), let queue=device.makeCommandQueue(),
          let unused=device.makeTexture(descriptor:d) else { throw MetalFailure.metalUnavailable }
    self.device=device; self.queue=queue; self.pipeline=try device.makeComputePipelineState(function:function)
    emptyCoverage=unused
  }

  func render(_ image: DevelopmentSceneMetalV1.Image, curve: Curve, local: (Coverage, Float)? = nil) throws -> DevelopmentSceneMetalV1.Image {
    try Task.checkCancellation()
    let source=image.texture
    func admitted(_ t: MTLTexture,_ format: MTLPixelFormat) -> Bool {
      t.device === device && t.textureType == .type2D && t.pixelFormat == format &&
        !t.isFramebufferOnly && t.storageMode != .memoryless && (t.usage.isEmpty || t.usage.contains(.shaderRead))
    }
    guard image.port == .working, admitted(source,.rgba32Float) else { throw Failure.invalidInput }
    var coverage=emptyCoverage
    var localScale: Float=1
    if let (user,ev)=local {
      guard admitted(user.texture,.r32Float), user.origin == image.origin,
            user.texture.width == source.width,user.texture.height == source.height,ev.isFinite,(-12...12).contains(ev) else {
        throw Failure.invalidInput
      }
      coverage=user.texture; localScale=exp2(ev)
    }
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:source.width,height:source.height,mipmapped:false)
    d.storageMode = .private; d.usage = [.shaderRead,.shaderWrite]
    guard let output=device.makeTexture(descriptor:d),let flag=device.makeBuffer(length:4,options:.storageModeShared),
          let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw MetalFailure.metalUnavailable }
    let invalid=flag.contents().bindMemory(to:UInt32.self,capacity:1); invalid.pointee=0
    let identity=curve.points.allSatisfy{ $0.x == $0.y }
    var params=SIMD4<Float>(Float(curve.points.count),identity ? 0 : 1,local == nil ? 0 : 1,localScale)
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source,index:0); encoder.setTexture(coverage,index:1); encoder.setTexture(output,index:2)
    encoder.setBuffer(flag,offset:0,index:0); encoder.setBytes(&params,length:MemoryLayout<SIMD4<Float>>.stride,index:1)
    curve.points.withUnsafeBytes { encoder.setBytes($0.baseAddress!,length:$0.count,index:2) }
    let lanes=pipeline.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width:source.width,height:source.height,depth:1),
      threadsPerThreadgroup:MTLSize(width:lanes,height:min(8,pipeline.maxTotalThreadsPerThreadgroup/lanes),depth:1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw command.error ?? MetalFailure.gpuExecutionFailed }
    try Task.checkCancellation()
    guard invalid.pointee == 0 else { throw Failure.invalidPixel }
    return .init(texture:output,port:.working,origin:image.origin)
  }

  private static let kernel = #"""
#include <metal_stdlib>
using namespace metal;
float curveDelta(float ev, constant float2* points, uint count) {
  if (ev <= points[0].x) return points[0].y - points[0].x;
  for (uint i=1; i<count; ++i) {
    float2 b=points[i];
    if (ev <= b.x) {
      float2 a=points[i-1];
      return mix(a.y-a.x,b.y-b.x,(ev-a.x)/(b.x-a.x));
    }
  }
  return points[count-1].y - points[count-1].x;
}
kernel void rmSceneToneV1(texture2d<float,access::read> scene [[texture(0)]],
                          texture2d<float,access::read> mask [[texture(1)]],
                          texture2d<float,access::write> output [[texture(2)]],
                          device atomic_uint& invalid [[buffer(0)]], constant float4& p [[buffer(1)]],
                          constant float2* points [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
  float4 src=scene.read(xy);
  float c=p.z == 0 ? 0 : mask.read(xy).r;
  if (!all(isfinite(src)) || !isfinite(c) || src.a < 0 || src.a > 1 || c < 0 || c > 1) {
    atomic_store_explicit(&invalid,1,memory_order_relaxed); return;
  }
  if (src.a == 0) { output.write(float4(0),xy); return; }
  float gain=1;
  if (p.y != 0) {
    float y=dot(src.rgb,float3(0.2722287168f,0.6740817658f,0.0536895174f));
    if (y > 0) gain=exp2(curveDelta(log2(y)-log2(src.a),points,uint(p.x)));
  }
  float3 result=src.rgb*(gain*mix(1.0f,p.w,c));
  if (!all(isfinite(result))) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  output.write(float4(result,src.a),xy);
}
"""#
}
