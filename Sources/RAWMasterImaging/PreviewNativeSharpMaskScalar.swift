import CoreImage
import Metal
import RAWMasterCore

/// Core Image owns the native tiles and their lifetime. Store one float for the
/// opaque monochrome mask, then expand to RGB after the usual affine reduction.
final class PreviewNativeSharpMaskScalar: CIImageProcessorKernel {
  static let enabled = ProcessInfo.processInfo.environment["RAWMASTER_PROXY_SCALAR_NATIVE_MASK"] != "0"
  private static let pipeline: MTLComputePipelineState? = {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let metal = """
    #include <metal_stdlib>
    using namespace metal;
    \(DevelopmentGlobalEngineV3.sharpWeightMetal)
    kernel void scalarMask(texture2d<float,access::read> source [[texture(0)]],
      texture2d<float,access::write> destination [[texture(1)]], constant float4 &params [[buffer(0)]],
      constant float4 &advanced [[buffer(1)]], constant uint2 &offset [[buffer(2)]],
      uint2 at [[thread_position_in_grid]]) {
      float d = source.read(at+offset).r;
      destination.write(float4(rmSharpWeight(d,params,advanced)),at);
    }
    """
    let options = MTLCompileOptions()
    if #available(macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
    guard let function = try? device.makeLibrary(source:metal, options:options).makeFunction(name:"scalarMask") else { return nil }
    return try? device.makeComputePipelineState(function:function)
  }()

  static func prewarm() { if enabled { _ = pipeline } }
  static func isEnabled(on device: MTLDevice) -> Bool { enabled && pipeline?.device.registryID == device.registryID }

  override class var synchronizeInputs: Bool { false }
  override class var outputIsOpaque: Bool { true }
  override class var outputFormat: CIFormat { .Rf }
  override class func formatForInput(at input: Int32) -> CIFormat { .Rf }

  static func scaled(_ controls: DevelopmentSharpenV3, response: CIImage, transform: CGAffineTransform) throws -> CIImage {
    let advanced = controls.radius != nil || controls.detail != nil || controls.masking != nil
    let arguments: [String:Any] = ["edges":controls.edges, "falloff":controls.falloff,
      "detail":controls.detail ?? 0, "masking":controls.masking ?? 0, "advanced":advanced]
    let scalar = try apply(withExtent:response.extent, inputs:[response], arguments:arguments).transformed(by:transform)
    let red = CIVector(x:1,y:0,z:0,w:0)
    return scalar.applyingFilter("CIColorMatrix", parameters:["inputRVector":red, "inputGVector":red, "inputBVector":red])
  }

  override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String:Any]?, output: CIImageProcessorOutput) throws {
    guard let input = inputs?.first, let source = input.metalTexture, let destination = output.metalTexture,
          let command = output.metalCommandBuffer, let pipeline, command.device.registryID == pipeline.device.registryID,
          let edges = arguments?["edges"] as? Double, let falloff = arguments?["falloff"] as? Double,
          let detail = arguments?["detail"] as? Double, let masking = arguments?["masking"] as? Double,
          let advanced = arguments?["advanced"] as? Bool else { throw DevelopmentError.unsupportedEngine }
    let region = output.region
    let x = Int(region.minX - input.region.minX), y = Int(input.region.maxY - region.maxY)
    let width = Int(region.width), height = Int(region.height)
    guard source.pixelFormat == .r32Float, destination.pixelFormat == .r32Float,
          x >= 0, y >= 0, x+width <= source.width, y+height <= source.height,
          width <= destination.width, height <= destination.height,
          let encoder = command.makeComputeCommandEncoder() else { throw DevelopmentV3Error.invalidGraph }
    var params = SIMD4<Float>(0,Float(edges),Float(falloff),0)
    var advancedParams = SIMD4<Float>(Float(detail),Float(masking),advanced ? 1:0,1)
    var offset = SIMD2<UInt32>(UInt32(x),UInt32(y))
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(source,index:0); encoder.setTexture(destination,index:1)
    encoder.setBytes(&params,length:MemoryLayout.size(ofValue:params),index:0)
    encoder.setBytes(&advancedParams,length:MemoryLayout.size(ofValue:advancedParams),index:1)
    encoder.setBytes(&offset,length:MemoryLayout.size(ofValue:offset),index:2)
    let groupWidth = min(32,pipeline.threadExecutionWidth)
    let groupHeight = min(8,pipeline.maxTotalThreadsPerThreadgroup/groupWidth)
    encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:groupWidth,height:groupHeight,depth:1))
    encoder.endEncoding()
  }
}
