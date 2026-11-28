import CoreImage
import CryptoKit
import Darwin
import Foundation
import RAWMasterCore

/// Same original guide/scalar/restore math, with the qualified fixed256 file transport.
enum DevelopmentDehazeRfTransportV1 {
  private static let mappedWritesEnabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_RF_MMAP"] == "1"
    && ProcessInfo.processInfo.environment["RAWMASTER_RF_PWRITE"] != "1"
  private static let profileWrites = ProcessInfo.processInfo.environment["RAWMASTER_RF_PROFILE"] == "1"
  static let version="dehaze-positive-v2-rf256-v1"
  static let scalarMetal = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmGuideScalarRf(sampler guide,destination dest) {
  float3 m=guide.sample(guide.transform(dest.coord())).rgb;
  if (!all(isfinite(m))) return float4(as_type<float>(0x7fc00000u));
  float3 w=float3(.2126,.7152,.0722);
  return float4(dot(m,w),0.0,0.0,1.0);
}
}}
"""#
  static func scalar(_ guide:CIImage)throws->CIImage {
    let all=try CIKernel.kernels(withMetalString:scalarMetal)
    guard let k=all.first(where:{$0.name=="rmGuideScalarRf"}),let x=k.apply(extent:guide.extent,roiCallback:{_,r in r},arguments:[guide.samplingNearest()]) else { throw DevelopmentV3Error.invalidGraph };return x
  }
  static func restoreSource()throws->String {
    let original=DevelopmentDehazeColorGuideV2.metalSource
    let substitutions=[
      ("float3 m=guide.sample(guide.transform(d)).rgb;","float scalar=guide.sample(guide.transform(d)).r;"),
      ("if (!all(isfinite(m))) return float4(as_type<float>(0x7fc00000u));","if (!isfinite(scalar)) return float4(as_type<float>(0x7fc00000u));"),
      ("clamp(dot(m,w),0.0,1.0)","clamp(scalar,0.0,1.0)")]
    var source=original
    for (before,after) in substitutions {
      guard source.components(separatedBy:before).count==2 else{throw DevelopmentV3Error.invalidGraph}
      source=source.replacingOccurrences(of:before,with:after)
    }
    return source
  }
  static func restore(_ input:CIImage,_ guide:CIImage,airlight:DevelopmentDehazeAirlightV1,amount:Double)throws->CIImage {
    try airlight.validate()
    guard amount==25,input.extent==guide.extent else{throw DevelopmentV3Error.invalidGraph}
    return try restoreNative(input,guide,airlight:airlight,amount:amount)
  }
  /// Full-strength canonical operator; no TIFF display quantization or FIT contract.
  static func restoreNative(_ input:CIImage,_ guide:CIImage,airlight:DevelopmentDehazeAirlightV1,amount:Double)throws->CIImage {
    try airlight.validate()
    guard amount.isFinite,(0...100).contains(amount),input.extent==guide.extent else{throw DevelopmentV3Error.invalidGraph}
    if amount==0{return input}
    let all=try CIKernel.kernels(withMetalString:try restoreSource())
    guard let k=all.first(where:{$0.name=="rmDehazeSplitRestoreV2"}),let x=k.apply(extent:input.extent,roiCallback:{_,r in r},arguments:[input.samplingNearest(),guide.samplingNearest(),CIVector(x:airlight.red,y:airlight.green,z:airlight.blue,w:amount/100)]) else { throw DevelopmentV3Error.invalidGraph };return x
  }

  static func render(_ graph:CIImage,rect:CGRect,components:Int,context:CIContext,
    request:DevelopmentDehazeTIFFPreviewV1.Request, seedUnwrittenScalar:Bool=false)throws->DehazeRfBufferV1{
    try request.requireCurrent()
    let buffer=try DehazeRfBufferV1(width:Int(rect.width),height:Int(rect.height),components:components,scope:request.scope)
    if seedUnwrittenScalar {
      guard components == 1 else { throw PreviewPresentationError.allocationProtocol }
      // Every unwritten IEEE-754 scalar must fail the joined, full-width row verification.
      memset(buffer.pointer, 0xff, buffer.bytes)
    }
    let destination = bitmapDestination(buffer.pointer, rect: rect, rowBytes: buffer.rowBytes, components: components)
    let task=try context.startTask(toRender:graph,from:rect,to:destination,at:.zero)
    do{
      try request.observe(.scalarSubmitted)
      _=try task.waitUntilCompleted()
    }catch{let original=error;_=try?task.waitUntilCompleted();throw original}
    try request.observe(.scalarJoined);try request.requireCurrent();return buffer
  }
  static func bitmapDestination(_ pointer: UnsafeMutableRawPointer, rect: CGRect, rowBytes: Int,
                                components: Int) -> CIRenderDestination {
    let destination = CIRenderDestination(bitmapData: pointer, width: Int(rect.width), height: Int(rect.height),
      bytesPerRow: rowBytes, format: components == 1 ? .Rf : (components == 2 ? .RGf : .RGBAf))
    destination.colorSpace = nil
    destination.alphaMode = .none
    destination.isFlipped = true
    destination.isDithered = false
    destination.isClamped = false
    return destination
  }
  static func file(_ graph:CIImage,scratch:DehazeRfScratchV1,context:CIContext,
    request:DevelopmentDehazeTIFFPreviewV1.Request,bandRows:Int=256)throws{
    guard graph.extent==CGRect(x:0,y:0,width:scratch.width,height:scratch.height) else{throw DevelopmentV3Error.invalidGraph}
    try file(scratch:scratch,context:context,request:request,bandRows:bandRows,makeGraph:{graph})
  }
  /// Factory graphs keep the same complete native extent. Only the requested render
  /// rectangle is banded; the graph and its tiled intermediate can retire after each join.
  /// Constant-graph callers do not request retirement and retain their existing lifetime.
  static func file(scratch:DehazeRfScratchV1,context:CIContext,
    request:DevelopmentDehazeTIFFPreviewV1.Request,bandRows:Int=256,tileWidth:Int?=nil,
    makeGraph:()throws->CIImage,requireBandRetired:(()throws->Void)?=nil)throws{
    try file(scratch:scratch,request:request,bandRows:bandRows,tileWidth:tileWidth,
      makeContext:{context},makeGraph:makeGraph,requireBandRetired:requireBandRetired)
  }
  /// A fresh context may be owned by the same short pool as one joined output task.
  /// The original context overload retains its exact shared-context behavior.
  static func file(scratch:DehazeRfScratchV1,
    request:DevelopmentDehazeTIFFPreviewV1.Request,bandRows:Int=256,tileWidth:Int?=nil,
    makeContext:()throws->CIContext,makeGraph:()throws->CIImage,
    requireBandRetired:(()throws->Void)?=nil)throws{
    let width=scratch.width,height=scratch.height,components=scratch.components
    let columns=tileWidth ?? width
    // Default full-width/256-row callers retain the original domain. Only the RGf
    // factory may opt into <=1024-square output tasks; its graph stays full-native.
    if let tileWidth {
      guard components==2,(1...1024).contains(tileWidth),(1...1024).contains(bandRows) else{throw DevelopmentV3Error.invalidGraph}
    } else {guard (1...256).contains(bandRows) else{throw DevelopmentV3Error.invalidGraph}}
    let fd=open(scratch.plane.path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard fd>=0 else{throw DevelopmentError.invalidEncoding};var closed=false
    defer{if !closed{_=Darwin.close(fd)}}
    // A sparse file may fault during a mapped write when the volume is full. Map only a
    // fully reserved plane; unsupported preallocation or mapping uses checked pwrite.
    var reserved = false
    if mappedWritesEnabled {
      var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
        fst_offset: 0, fst_length: off_t(scratch.planeBytes), fst_bytesalloc: 0)
      reserved = fcntl(fd, F_PREALLOCATE, &store) == 0 && store.fst_bytesalloc >= scratch.planeBytes
    }
    guard ftruncate(fd,off_t(scratch.planeBytes))==0 else{throw DevelopmentError.invalidEncoding}
    let mapping = reserved ? mmap(nil,scratch.planeBytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0) : nil
    let mapped = mapping == MAP_FAILED ? nil : mapping
    defer { if let mapped { _ = munmap(mapped,scratch.planeBytes) } }
    for y in stride(from:0,to:height,by:bandRows){
      for x in stride(from:0,to:width,by:columns){
        let outcome:Result<Void,Error> = autoreleasepool{
          Result{
            let trace = profileWrites
            let contextStart = DispatchTime.now().uptimeNanoseconds
            let context=try makeContext()
            defer{context.clearCaches()}
            let contextMs = Double(DispatchTime.now().uptimeNanoseconds - contextStart) / 1_000_000
            try request.requireCurrent()
            let graphStart = DispatchTime.now().uptimeNanoseconds
            let graph=try makeGraph()
            let graphMs = Double(DispatchTime.now().uptimeNanoseconds - graphStart) / 1_000_000
            guard graph.extent==CGRect(x:0,y:0,width:width,height:height) else{throw DevelopmentV3Error.invalidGraph}
            let w=min(columns,width-x),h=min(bandRows,height-y),rect=CGRect(x:x,y:y,width:w,height:h)
            let renderStart = DispatchTime.now().uptimeNanoseconds
            let buffer=try render(graph,rect:rect,components:components,context:context,request:request)
            let renderMs = Double(DispatchTime.now().uptimeNanoseconds - renderStart) / 1_000_000
            let writeStart = DispatchTime.now().uptimeNanoseconds
            let top=height-y-h,rowValues=w*components
            for row in 0..<h{
              try request.requireCurrent()
              let values=buffer.pointer.advanced(by:row*buffer.rowBytes).assumingMemoryBound(to:Float.self)
              guard (0..<rowValues).allSatisfy({values[$0].isFinite}) else{throw DevelopmentError.invalidEncoding}
              if let mapped {
                let offset=((top+row)*width+x)*components*4
                let destination=mapped.advanced(by:offset).assumingMemoryBound(to:Float.self)
                destination.update(from:values,count:rowValues)
              } else {
                var n:Int
                repeat{n=pwrite(fd,values,rowValues*4,off_t(((top+row)*width+x)*components*4))}while n<0 && errno==EINTR
                guard n==rowValues*4 else{throw DevelopmentError.invalidEncoding}
              }
            }
            let writeMs = Double(DispatchTime.now().uptimeNanoseconds - writeStart) / 1_000_000
            if trace {
              print("RF-TILE x=\(x) y=\(y) context=\(String(format:"%.1f",contextMs)) graph=\(String(format:"%.1f",graphMs)) render=\(String(format:"%.1f",renderMs)) write=\(String(format:"%.1f",writeMs))")
            }
          }
        }
        // A failure is joined and drained before checking retirement, too. Retain both
        // diagnostics if the render/factory failed and a graph also escaped its band.
        do{try requireBandRetired?()}catch{
          if case .failure(let primary)=outcome{throw DevelopmentDehazeNativeResources.ExitFailure(primary:primary,cleanup:error)}
          throw error
        }
        try outcome.get()
      }
    }
    if let mapped, msync(mapped,scratch.planeBytes,MS_SYNC) != 0 { throw DevelopmentError.invalidEncoding }
    guard fsync(fd)==0 else{throw DevelopmentError.invalidEncoding}
    var info=stat()
    guard fstat(fd,&info)==0,info.st_size==scratch.planeBytes,fchmod(fd,0o400)==0 else{throw DevelopmentError.invalidEncoding}
    let result=Darwin.close(fd);closed=true;guard result==0 else{throw DevelopmentError.invalidEncoding}
    try scratch.requirePlane();try request.requireCurrent()
  }
  /// Independent, bounded own-file readback. Does not compare against a fused F32 truth.
  static func verify(_ sampled:CIImage,scratch:DehazeRfScratchV1,state:DehazeRfStateV1,context:CIContext,
    request:DevelopmentDehazeTIFFPreviewV1.Request)throws->String{
    guard scratch.components==1 else{throw PreviewPresentationError.unsupported}
    try scratch.requirePlane()
    var original=stat();guard lstat(scratch.plane.path,&original)==0 else{throw DevelopmentError.invalidEncoding}
    let fd=open(scratch.plane.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
    guard fd>=0 else{throw DevelopmentError.invalidEncoding};var closed=false
    defer{if !closed{_=Darwin.close(fd)}}
    var actual=stat()
    guard fstat(fd,&actual)==0,actual.st_dev==original.st_dev,actual.st_ino==original.st_ino,actual.st_size==original.st_size else{throw DevelopmentError.invalidEncoding}
    let width=scratch.width,height=scratch.height,rowBytes=width*4
    let row=try DehazeRfBufferV1(width:width,height:1,components:1,scope:request.scope)
    func read(_ top:Int)throws{
      var n:Int
      repeat{n=pread(fd,row.pointer,rowBytes,off_t(top*rowBytes))}while n<0 && errno==EINTR
      guard n==rowBytes else{throw DevelopmentError.invalidEncoding}
    }
    let hash=try RenderFiles.hash(scratch.plane)
    var seen=0
    for y in stride(from:0,to:height,by:256){
      try autoreleasepool{
        defer{context.clearCaches()}
        let count=min(256,height-y),top=height-y-count
        let got=try render(sampled,rect:CGRect(x:0,y:y,width:width,height:count),components:1,context:context,request:request)
        for i in 0..<count{
          try request.requireCurrent();try read(top+i)
          guard memcmp(got.pointer.advanced(by:i*got.rowBytes),row.pointer,rowBytes)==0 else{throw DevelopmentError.invalidEncoding}
          seen+=width
        }
        try state.check()
      }
    }
    // The full own-file comparison establishes orientation even for constant rows.
    // This actual RGBAf canary separately proves the Rf provider's implicit alpha.
    try read(0)
    let count=min(2,width),expected=Array(UnsafeBufferPointer(start:row.pointer.assumingMemoryBound(to:UInt32.self),count:count))
    try autoreleasepool{
      defer{context.clearCaches()}
      let canary=try render(sampled,rect:CGRect(x:0,y:height-1,width:count,height:1),components:4,context:context,request:request)
      let got=canary.pointer.assumingMemoryBound(to:UInt32.self)
      for i in 0..<count{guard got[i*4]==expected[i],got[i*4+3]==Float(1).bitPattern else{throw DevelopmentError.invalidEncoding}}
    }
    guard seen==width*height,try RenderFiles.hash(scratch.plane)==hash else{throw DevelopmentError.invalidEncoding}
    try state.check();try request.requireCurrent()
    let status=Darwin.close(fd);closed=true;guard status==0 else{throw DevelopmentError.invalidEncoding}
    return hash
  }
}
