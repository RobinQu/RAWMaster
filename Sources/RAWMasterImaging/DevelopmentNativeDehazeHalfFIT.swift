import CoreImage
import Darwin
import Foundation
import Metal
import RAWMasterCore

/// The two certified restore inputs stay pinned through every command and the original
/// FIT readback. A 256-row F32 band preserves the hardware sampler's exact rounding.
enum DevelopmentNativeDehazeHalfFIT {
  static let enabled: Bool = {
    let environment = ProcessInfo.processInfo.environment
    if let requested = environment["RAWMASTER_QA_NATIVE_DEHAZE_RESTORE_HALF_FIT"] { return requested == "1" }
    // The qualified display plan uses the original uncached context and CGImage readback.
    return environment["RAWMASTER_QA_CANONICAL_INTERMEDIATE_CACHE"] != "1" && !V3PreviewMaterializer.writesOwnedBitmap
  }()
  private static let bandRows = 256
  private static let lanes = 128
  private static let workingLimit = 512 * 1024 * 1024

  static func prepare(_ input: DevelopmentResidentDehazeGuide.RestoreHalfInputs, using context: CIContext,
                      check: () throws -> Void) throws -> CIImage? {
    try check()
    guard #available(macOS 27.0,*), enabled, DevelopmentDehazeRestoreProof.enabled else { return nil }
    let source = input.source, device = source.device
    guard device.supports32BitFloatFiltering, source.pixelFormat == .rgba16Float, source.storageMode == .private,
          source.textureType == .type2D, source.mipmapLevelCount == 1, source.sampleCount == 1, source.usage.contains(.shaderRead),
          source.hazardTrackingMode != .untracked, input.transmission.device.registryID == device.registryID,
          input.transmission.storageMode == .shared, input.rowFloats == source.width,
          input.output.extent == CGRect(x:0,y:0,width:source.width,height:source.height),
          context.workingFormat == .RGBAf, let space = context.workingColorSpace, CFEqual(space,DevelopmentColorEngineV3.linearSRGB),
          acceptsPlan(for:input.output,using:context), input.transmission.length >= source.width*source.height*4,
          let kernels = runtime, kernels.queue.device.registryID == device.registryID,
          let layout = Layout(device:device,width:source.width,height:source.height),
          let charge = PreviewCanonicalHalfFIT.Reservation.acquire(layout.bytes,device:device) else {
      try check(); return nil
    }
    try check()
    return try produce(input,kernels:kernels,layout:layout,charge:charge,check:check)
  }

  /// The estimate is for the actual final graph, default sRGB8 display and original
  /// context. Its dimensions and topology supplement the owner's restore-object check.
  @available(macOS 27.0,*) private static func acceptsPlan(for image: CIImage, using context: CIContext) -> Bool {
    let w=Int(image.extent.width), h=Int(image.extent.height)
    guard expectedPasses(width:w,height:h) != nil else { return false }
    let width=2400, height=1600, scale=CGFloat(width)/CGFloat(w)
    let fitted=image.transformed(by:.init(scaleX:scale,y:scale))
    guard fitted.extent == CGRect(x:0,y:0,width:width,height:height) else { return false }
    var storage: UnsafeMutableRawPointer?
    guard posix_memalign(&storage,64,width*height*4)==0,let storage else {return false}
    defer{free(storage)}
    let target=CIRenderDestination(bitmapData:storage,width:width,height:height,bytesPerRow:width*4,format:.RGBA8)
    target.colorSpace=PhotoRenderer.sRGB; target.alphaMode = .premultiplied; target.isFlipped=true
    guard let estimate=try? context.estimateRender(fitted,from:fitted.extent,to:target,at:.zero) else {return false}
    return acceptsTopology(width:w,height:h,passes:estimate.plannedPassCount,
      pixels:estimate.plannedPixelsProcessed,overdraw:estimate.plannedPixelsOverdrawn)
  }

  private static func expectedPasses(width: Int, height: Int) -> Int? {
    switch (width,height) {
    case (9504,6336): return 29
    case (8640,5760): return 27
    default: return nil
    }
  }

  static func acceptsTopology(width: Int, height: Int, passes: Int, pixels: Int, overdraw: Int) -> Bool {
    guard overdraw==0, let expected=expectedPasses(width:width,height:height), passes==expected else { return false }
    let native=width*height
    return pixels==2*native+native/4+2*2400*1600
  }

  private struct Layout {
    let band, half: MTLTextureDescriptor
    let bandBytes, halfBytes, flagsBytes, flagsLength: Int
    var bytes: Int { bandBytes+halfBytes+flagsBytes }

    init?(device: MTLDevice, width: Int, height: Int) {
      func descriptor(w:Int,h:Int)->MTLTextureDescriptor {
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:w,height:h,mipmapped:false)
        desc.storageMode = .private; desc.usage = [.shaderRead,.shaderWrite,.renderTarget]
        return desc
      }
      band=descriptor(w:width,h:bandRows); half=descriptor(w:width/2,h:height/2)
      let bandEstimate=device.heapTextureSizeAndAlign(descriptor:band), halfEstimate=device.heapTextureSizeAndAlign(descriptor:half)
      flagsLength=(groups(width*bandRows)+groups(width*bandRows/4))*MemoryLayout<UInt32>.stride
      let flagEstimate=device.heapBufferSizeAndAlign(length:flagsLength,options:.storageModeShared),page=Int(getpagesize())
      guard bandEstimate.align>0,halfEstimate.align>0,flagEstimate.align>0,page>0,
            bandEstimate.size>=width*bandRows*16,halfEstimate.size>=width*height*4,
            bandEstimate.size<=workingLimit,halfEstimate.size<=workingLimit-bandEstimate.size,
            flagsLength<=device.maxBufferLength,flagEstimate.size>=flagsLength,flagEstimate.size<=workingLimit else{return nil}
      bandBytes=bandEstimate.size;halfBytes=halfEstimate.size;flagsBytes=((flagEstimate.size+page-1)/page)*page
      guard flagsBytes <= workingLimit-bandBytes-halfBytes else{return nil}
    }
  }

  private struct Kernels {
    let queue:MTLCommandQueue, restore, sample:MTLComputePipelineState
  }

  private static let runtime: Kernels? = {
    guard #available(macOS 27.0,*), DevelopmentDehazeRestoreProof.programIsKnown,
          let device=MTLCreateSystemDefaultDevice(), let queue=device.makeCommandQueue(),
          let original=try? DevelopmentDehazeRfTransportV1.restoreSource(),
          let entry=original.range(of:"float4 rmDehazeSplitRestoreV2("),
          let begin=original.range(of:"if (!all(isfinite(p))",range:entry.upperBound..<original.endIndex),
          let end=original.range(of:"return float4(restored*p.a,p.a);",range:begin.lowerBound..<original.endIndex) else{return nil}
    // Bind the two native samplers through physical reads. Keep every arithmetic
    // expression from the digest-checked Core Image program, including its alpha guard.
    let body=String(original[begin.lowerBound..<end.upperBound])
    let scalarRead="float scalar=guide.sample(guide.transform(d)).r;"
    guard body.components(separatedBy:scalarRead).count==2 else{return nil}
    let program=metal.replacingOccurrences(of:"/*ORIGINAL_RESTORE*/",with:body.replacingOccurrences(of:scalarRead,with:""))
    let options=MTLCompileOptions()
    options.mathMode = .fast
    options.mathFloatingPointFunctions = .fast
    guard let lib=try? device.makeLibrary(source:program,options:options),
          let a=lib.makeFunction(name:"restoreBand"),let b=lib.makeFunction(name:"sampleHalf"),
          let restore=try? device.makeComputePipelineState(function:a),let sample=try? device.makeComputePipelineState(function:b),
          [restore,sample].allSatisfy({$0.threadExecutionWidth==32 && $0.maxTotalThreadsPerThreadgroup>=lanes}) else{return nil}
    return Kernels(queue:queue,restore:restore,sample:sample)
  }()

  private static func groups(_ pixels:Int)->Int { 1+(pixels-1)/lanes }

  static func allGroupsWrote(_ marks:UnsafeBufferPointer<UInt32>, offset:Int, pixels:Int)->Bool {
    guard offset>=0,pixels>0,offset<=marks.count else{return false}
    let count=groups(pixels)
    guard count<=marks.count-offset else{return false}
    for i in 0..<count {
      let required=0xa000_0000 | UInt32(min(lanes,pixels-i*lanes))
      if marks[offset+i] != required {return false}
    }
    return true
  }

  private static func produce(_ input:DevelopmentResidentDehazeGuide.RestoreHalfInputs,kernels:Kernels,layout:Layout,
                              charge:PreviewCanonicalHalfFIT.Reservation,check:() throws -> Void)throws->CIImage? {
    let queue=kernels.queue, device=queue.device, source=input.source
    guard let band=device.makeTexture(descriptor:layout.band), band.allocatedSize>0, band.allocatedSize<=layout.bandBytes,
          let half=device.makeTexture(descriptor:layout.half), half.allocatedSize>0, half.allocatedSize<=layout.halfBytes,
          let flags=device.makeBuffer(length:layout.flagsLength,options:.storageModeShared),
          flags.allocatedSize>0, flags.allocatedSize<=layout.flagsBytes,
          PreviewCanonicalHalfFIT.Reservation.hasHeadroom(device,additional:0) else {try check();return nil}
    let width=source.width,height=source.height,telemetry=ImagePerformanceTelemetry.shared
    let stage=telemetry.begin(operation:"NativeDehazeHalfFIT",stage:"原生还原与硬件半幅采样",queue:"Metal GPU",boundary:.gpuCompletion)
    var succeeded=0,outcome=ImagePerformanceOutcome.failed
    defer{telemetry.end(stage,outcome:outcome,pixelCount:width*succeeded,byteCount:layout.bytes)}
    var air=SIMD4<Float>(Float(input.light.red),Float(input.light.green),Float(input.light.blue),Float(input.amount/100))
    do {
      for y in stride(from:0,to:height,by:bandRows) {
        try check()
        let rows=min(bandRows,height-y),nativePixels=width*rows,halfPixels=nativePixels/4
        let nativeGroups=groups(nativePixels),halfGroups=groups(halfPixels)
        memset(flags.contents(),0,(nativeGroups+halfGroups)*4)
        let grid=SIMD4<UInt32>(UInt32(width),UInt32(height),UInt32(y),UInt32(rows))
        let committed=try autoreleasepool { () throws -> Bool in
          guard let command=queue.makeCommandBuffer() else {return false}
          func encode(_ pipeline:MTLComputePipelineState,source:MTLTexture,target:MTLTexture,count:Int,offset:Int)->Bool {
            guard let enc=command.makeComputeCommandEncoder() else{return false}
            var shape=grid
            enc.setComputePipelineState(pipeline);enc.setTexture(source,index:0);enc.setTexture(target,index:1)
            enc.setBuffer(input.transmission,offset:0,index:0);enc.setBytes(&shape,length:MemoryLayout.size(ofValue:shape),index:1)
            enc.setBytes(&air,length:MemoryLayout.size(ofValue:air),index:2);enc.setBuffer(flags,offset:offset*4,index:3)
            enc.dispatchThreadgroups(.init(width:count,height:1,depth:1),threadsPerThreadgroup:.init(width:lanes,height:1,depth:1))
            enc.endEncoding();return true
          }
          guard encode(kernels.restore,source:source,target:band,count:nativeGroups,offset:0),
                encode(kernels.sample,source:band,target:half,count:halfGroups,offset:nativeGroups) else{return false}
          try check()
          command.commit()
          do {
            try check()
            command.waitUntilCompleted()
            guard command.status == .completed else{throw command.error ?? PreviewPresentationError.allocationProtocol}
            try check()
          } catch {
            command.waitUntilCompleted()
            throw error
          }
          return true
        }
        guard committed else {
          if succeeded==0 {try check();return nil}
          throw PreviewPresentationError.allocationProtocol
        }
        let marks=UnsafeBufferPointer(start:flags.contents().assumingMemoryBound(to:UInt32.self),count:nativeGroups+halfGroups)
        guard allGroupsWrote(marks,offset:0,pixels:nativePixels),allGroupsWrote(marks,offset:nativeGroups,pixels:halfPixels) else {
          throw DevelopmentError.invalidEncoding
        }
        succeeded+=rows
        try check()
      }
      guard succeeded==height, let image=CIImage(mtlTexture:half,options:[.colorSpace:DevelopmentColorEngineV3.linearSRGB]),
            image.extent==CGRect(x:0,y:0,width:width/2,height:height/2) else{throw PreviewPresentationError.allocationProtocol}
      try check()
      charge.retainWith(half,image:image)
      outcome = .succeeded
      return image
    } catch {
      if error is CancellationError || (error as? DevelopmentPreviewError) == .superseded {outcome = .cancelled}
      throw error
    }
  }

  private static let metal = #"""
  #include <metal_stdlib>
  using namespace metal;
  inline bool finite4(float4 v){return all((as_type<uint4>(v)&0x7f800000u)!=0x7f800000u);}
  inline float4 restorePixel(float4 p,float scalar,float4 air) {
    /*ORIGINAL_RESTORE*/
  }
  inline void report(uint count,uint error,device uint* flags,uint group,uint subgroup,uint lane,
                     uint index,threadgroup uint* partial) {
    uint packed=simd_sum(count)|(simd_max(error)<<16);
    if(lane==0)partial[subgroup]=packed;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if(index==0){
      uint n=0,invalid=0;
      for(uint i=0;i<4;i++){n+=partial[i]&0xffffu;invalid|=partial[i]>>16;}
      flags[group]=0xa0000000u|(invalid<<16)|n;
    }
  }
  kernel void restoreBand(texture2d<half,access::read> source [[texture(0)]],
    texture2d<float,access::write> band [[texture(1)]],device const float* guide [[buffer(0)]],
    constant uint4& g [[buffer(1)]],constant float4& air [[buffer(2)]],device uint* flags [[buffer(3)]],
    uint group [[threadgroup_position_in_grid]],uint lane [[thread_index_in_simdgroup]],
    uint subgroup [[simdgroup_index_in_threadgroup]],uint i [[thread_index_in_threadgroup]]) {
    uint index=group*128+i,n=0,invalid=0;
    if(index<g.x*g.w){
      uint2 local=uint2(index%g.x,index/g.x);
      uint2 top=uint2(local.x,g.y-1-g.z-local.y);
      half4 h=source.read(top); ushort4 bits=as_type<ushort4>(h);
      float scalar=guide[top.y*g.x+top.x];
      bool eligible=bits.a==0x3c00u && all((bits.rgb&ushort3(0x7fffu))<=ushort3(0x6400u))
                 && (as_type<uint>(scalar)&0x7fffffffu)<=0x40000000u;
      if(eligible){
        float4 v=restorePixel(float4(h),scalar,air);
        if(finite4(v)&&v.a==1.0f){band.write(v,local);n=1;}else{invalid=1;}
      }else{invalid=1;}
    }
    threadgroup uint partial[4];report(n,invalid,flags,group,subgroup,lane,i,partial);
  }
  kernel void sampleHalf(texture2d<float,access::sample> band [[texture(0)]],
    texture2d<float,access::write> target [[texture(1)]],constant uint4& g [[buffer(1)]],
    device uint* flags [[buffer(3)]],uint group [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_simdgroup]],uint subgroup [[simdgroup_index_in_threadgroup]],
    uint i [[thread_index_in_threadgroup]]) {
    uint index=group*128+i,n=0,invalid=0,width=g.x/2;
    if(index<width*(g.w/2)){
      uint2 p=uint2(index%width,index/width);
      constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge);
      float2 pivot=float2(2*p+1)/float2(band.get_width(),band.get_height());
      float4 v=band.sample(s,pivot);
      if(finite4(v)&&v.a==1.0f){target.write(v,uint2(p.x,p.y+g.z/2));n=1;}else{invalid=1;}
    }
    threadgroup uint partial[4];report(n,invalid,flags,group,subgroup,lane,i,partial);
  }
  """#
}
