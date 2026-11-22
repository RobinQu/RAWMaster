import Darwin
import Foundation
import Metal

/// Validates an immutable, joined F32 proxy while Core Image reads the same texture for display.
/// One byte per 1,024 pixels records completion, finite/range failures, and nonzero coverage.
enum PreviewMetalFrameValidator {
  private struct Pipeline {
    let queue: MTLCommandQueue
    let state: MTLComputePipelineState
    let vignette: MTLComputePipelineState?
    let display: MTLComputePipelineState
  }
  private static let metal = #"""
  #include <metal_stdlib>
  using namespace metal;
  constant bool writesDisplay [[function_constant(0)]];
  constant bool postCropVignette [[function_constant(1)]];
  \#(PreviewMetalPostCrop.metal)
  kernel void validatePreview(texture2d<float,access::read> image [[texture(0)]],
    texture2d<float,access::write> display [[texture(1),function_constant(writesDisplay)]],
    device uchar *report [[buffer(0)]],
    constant float4 &amount [[buffer(1),function_constant(postCropVignette)]],
    constant float4 &options [[buffer(2),function_constant(postCropVignette)]], uint lane [[thread_index_in_threadgroup]],
    uint3 group [[threadgroup_position_in_grid]]) {
    threadgroup atomic_uint partial;
    if (lane==0) atomic_store_explicit(&partial,0u,memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint width=image.get_width(), count=width*image.get_height(), flags=0;
    for (uint j=0;j<8;j++) {
      uint i=group.x*1024u+lane+128u*j;
      if (i<count) {
        uint2 at=uint2(i%width,i/width);
        float4 p=image.read(at);
        if(postCropVignette) p=displayPostCrop(p,float2(at)+.5,float2(width,image.get_height()),amount,options);
        flags|=p.a>0 ? 1u:0u;
        flags|=!all(isfinite(p.rgb)) ? 2u:0u;
        flags|=(!isfinite(p.a) || p.a<0 || p.a>1) ? 4u:0u;
        if (writesDisplay && p.a<1) flags|=8u;
        if (writesDisplay) {
          float3 c=p.a>0.0 ? p.rgb/p.a : 0.0;
          float3 encoded=select(1.055*pow(max(c,0.0),float3(1.0/2.4))-.055,12.92*c,c<=.0031308);
          display.write(float4(encoded*p.a,p.a),at);
        }
      }
    }
    uint combined=simd_or(flags);
    if (simd_is_first()) atomic_fetch_or_explicit(&partial,combined,memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (lane==0) report[group.x]=uchar(0x40u|atomic_load_explicit(&partial,memory_order_relaxed));
  }
  """#
  private static let pipeline: Result<Pipeline,Error> = Result {
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory, let queue = device.makeCommandQueue() else {
      throw PreviewPresentationError.unsupported
    }
    let options = MTLCompileOptions()
    if #available(macOS 15, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
    let library = try device.makeLibrary(source: metal, options: options)
    func state(display:Bool,postCrop:Bool = false) throws -> MTLComputePipelineState {
      let constants=MTLFunctionConstantValues()
      var enabled=display
      constants.setConstantValue(&enabled,type:.bool,index:0)
      var applyPostCrop=postCrop
      constants.setConstantValue(&applyPostCrop,type:.bool,index:1)
      let function=try library.makeFunction(name:"validatePreview",constantValues:constants)
      let result=try device.makeComputePipelineState(function:function)
      guard result.maxTotalThreadsPerThreadgroup>=128 else {throw PreviewPresentationError.unsupported}
      return result
    }
    return try Pipeline(queue:queue,state:state(display:false),vignette:try? state(display:true,postCrop:true),display:state(display:true))
  }
  static func prewarm() { _ = try? pipeline.get() }
  static func supports(_ device: MTLDevice) -> Bool {
    (try? pipeline.get().queue.device.registryID) == device.registryID
  }

  static func supportsPostCrop(_ device: MTLDevice) -> Bool {
    guard let pipeline = try? pipeline.get() else { return false }
    return pipeline.queue.device.registryID == device.registryID && pipeline.vignette != nil
  }

  static func allocation(width: Int, height: Int) -> Int {
    let groups = (width * height + 1023) / 1024, page = Int(getpagesize())
    return ((groups + page - 1) / page) * page
  }

  static func checked<T>(_ texture: MTLTexture, ticket: PreviewPresentationReservation,
                         requireVisible: Bool, display: MTLTexture? = nil, postCrop: PreviewMetalPostCrop? = nil, onTranslucent:()throws->Void = {},
                         check: () throws -> Void, rendering: () throws -> T) throws -> T {
    defer { ticket.releaseAfterStorageReleased() }
    let pipeline = try pipeline.get()
    guard texture.pixelFormat == .rgba32Float, texture.device.registryID == pipeline.queue.device.registryID,
          texture.width <= 2400, texture.height <= 2400 else { throw PreviewPresentationError.invalidLayout }
    if let display {
      guard display.pixelFormat == .bgra8Unorm, display.device.registryID == texture.device.registryID,
        display.width == texture.width, display.height == texture.height else { throw PreviewPresentationError.invalidLayout }
    }
    let state: MTLComputePipelineState
    if postCrop != nil {
      guard display != nil, let vignette = pipeline.vignette else { throw PreviewPresentationError.unsupported }
      state = vignette
    } else { state = display == nil ? pipeline.state : pipeline.display }
    let groups = (texture.width * texture.height + 1023) / 1024
    let allocation = Self.allocation(width:texture.width,height:texture.height)
    return try autoreleasepool {
      try check()
      try ticket.requireOpenAdmission()
      guard let flags = texture.device.makeBuffer(length:allocation,options:.storageModeShared) else {
        throw PreviewPresentationError.displayCapacity
      }
      try ticket.registerActualAllocation(bytes:flags.allocatedSize)
      guard let command = pipeline.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
        throw PreviewPresentationError.displayCapacity
      }
      let bytes = flags.contents().assumingMemoryBound(to:UInt8.self)
      bytes.initialize(repeating:0,count:groups)
      encoder.setComputePipelineState(state)
      if let postCrop {
        var amount = postCrop.amount, options = postCrop.options
        encoder.setBytes(&amount,length:MemoryLayout.size(ofValue:amount),index:1)
        encoder.setBytes(&options,length:MemoryLayout.size(ofValue:options),index:2)
      }
      encoder.setTexture(texture,index:0)
      if let display { encoder.setTexture(display,index:1) }
      encoder.setBuffer(flags,offset:0,index:0)
      encoder.dispatchThreadgroups(.init(width:groups,height:1,depth:1),threadsPerThreadgroup:.init(width:128,height:1,depth:1))
      encoder.endEncoding()
      let pixels = texture.width * texture.height
      let timing = ImagePerformanceTelemetry.shared.begin(operation:"PreviewMetalFrameValidator",stage:postCrop != nil ? "裁切后暗角、整幅校验与 sRGB8 显示" : (display == nil ? "F32 全帧有限值与透明度" : "F32 全帧校验和 sRGB8 显示转换"),
        queue:"Metal GPU",boundary:.gpuCompletion)
      command.addCompletedHandler { completed in
        ImagePerformanceTelemetry.shared.end(timing,outcome:completed.status == .completed ? .succeeded : .failed,pixelCount:pixels,byteCount:pixels*16)
      }
      command.commit()
      let value: T
      do { value = try rendering() } catch {
        command.waitUntilCompleted()
        throw error
      }
      command.waitUntilCompleted()
      guard command.status == .completed else { throw command.error ?? DevelopmentError.invalidEncoding }
      var visible=false,translucent=false
      for flag in UnsafeBufferPointer(start:bytes,count:groups) {
        if flag != 0x40 && flag != 0x41 && flag != 0x48 && flag != 0x49 {
          let reason=flag & 0x40 == 0 ? "unwritten-validation-group" : (flag & 2 != 0 ? "non-finite-rgb":"invalid-alpha")
          throw rejected(reason,width:texture.width,height:texture.height)
        }
        visible = visible || flag & 1 != 0
        translucent = translucent || flag & 8 != 0
      }
      guard !requireVisible || visible else { throw rejected("fully-transparent",width:texture.width,height:texture.height) }
      if translucent { try onTranslucent() }
      try check()
      return value
    }
  }
  private static func rejected(_ reason:String,width:Int,height:Int) -> DevelopmentError {
    let message="RAWMaster: rejected \(width)x\(height) floating-point preview: \(reason)\n"
    FileHandle.standardError.write(Data(message.utf8))
    return .invalidEncoding
  }
}
