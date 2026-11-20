import Foundation
import CoreImage
import Metal
import RAWMasterCore

// Versioned source-native grain. CoreImage owns all command-buffer scheduling and joins.
final class DevelopmentGrainSamplingEngineV1:CIImageProcessorKernel {
 static let version="source-native-lattice-v1/Rf/global-int32-wrap"
 static let metalSource = #"""
 #include <metal_stdlib>
 using namespace metal;
 kernel void rm022Grain(texture2d<float,access::write> out [[texture(0)]],
   constant int4 &region [[buffer(0)]],constant int4 &bounds [[buffer(1)]],
   uint2 gid [[thread_position_in_grid]]) {
   if(gid.x>=uint(region.z) || gid.y>=uint(region.w)) return;
   int2 g=int2(region.x+int(gid.x),region.y+region.w-1-int(gid.y)); float value=0.0;
   if(g.x>=bounds.x && g.y>=bounds.y && g.x<bounds.z && g.y<bounds.w) {
     uint2 p=uint2(g); uint n=p.x*0x9e3779b9u ^ p.y*0x85ebca6bu ^ 0x021a31b7u;
     n^=n>>16; n*=0x7feb352du; n^=n>>15; n*=0x846ca68bu; n^=n>>16;
     value=float(n>>8)*(1.0/16777216.0)-.5;
   }
   out.write(float4(value,0.0,0.0,1.0),gid);
 }
 """#
 private static let lock=NSLock()
 private static var cached:(UInt64,MTLComputePipelineState)?
 override class var outputFormat:CIFormat { .Rf }
 override class var synchronizeInputs:Bool { false } // generator inputs=nil, no borrowed input.
 private static func pipeline(_ device:MTLDevice)throws->MTLComputePipelineState {
  lock.lock();defer{lock.unlock()}
  if let c=cached {try grainRequire(c.0==device.registryID,"same actual device");return c.1}
  let library=try device.makeLibrary(source:metalSource,options:nil)
  guard let fn=library.makeFunction(name:"rm022Grain")else{throw GrainError.unsupported("lattice function")}
  let p=try device.makeComputePipelineState(function:fn);cached=(device.registryID,p);return p
 }
 static func integers(_ r:CGRect)throws->SIMD4<Int32>{
  let a=[r.minX,r.minY,r.width,r.height]
  try grainRequire(a.allSatisfy{$0.isFinite && $0==floor($0) && $0>=CGFloat(Int32.min) && $0<=CGFloat(Int32.max)},"exact signed32 region")
  try grainRequire(r.width>0 && r.height>0 && r.width<=50000 && r.height<=50000,"native region hard bound50000")
  let x=Int64(r.minX),y=Int64(r.minY),w=Int64(r.width),h=Int64(r.height)
  try grainRequire(x+w<=Int64(Int32.max) && y+h<=Int64(Int32.max),"checked global endpoints")
  return SIMD4<Int32>(Int32(x),Int32(y),Int32(w),Int32(h))
 }
 static func image(_ extent:CGRect,activeBounds:CGRect?=nil)throws->CIImage {
  let i=try integers(extent),active=activeBounds ?? extent
  let b=try integers(active)
  try grainRequire(extent.contains(active),"active bounds contained by apply extent")
  let bounds=[Int(b.x),Int(b.y),Int(b.x+b.z),Int(b.y+b.w)]
  let applyExtent=[Int(i.x),Int(i.y),Int(i.z),Int(i.w)]
  return try apply(withExtent:extent,inputs:nil,arguments:["bounds":bounds,"applyExtent":applyExtent])
 }
 override class func process(with inputs:[CIImageProcessorInput]?,arguments:[String:Any]?,output:CIImageProcessorOutput)throws {
  try grainRequire(inputs==nil || inputs!.isEmpty,"generator no input")
  var r=try integers(output.region)
  guard let b=arguments?["bounds"] as? [Int],b.count==4,
    let a=arguments?["applyExtent"] as? [Int],a.count==4,
    let cb=output.metalCommandBuffer,let t=output.metalTexture else{throw GrainError.unsupported("real processor command buffer/texture")}
  try grainRequire(b.allSatisfy{$0>=Int(Int32.min) && $0<=Int(Int32.max)},"declared global bounds")
  let declaredApply=CGRect(x:CGFloat(a[0]),y:CGFloat(a[1]),width:CGFloat(a[2]),height:CGFloat(a[3]))
  _ = try integers(declaredApply)
  let activeWidth=CGFloat(Int64(b[2])-Int64(b[0])),activeHeight=CGFloat(Int64(b[3])-Int64(b[1]))
  let activeRect=CGRect(x:CGFloat(b[0]),y:CGFloat(b[1]),width:activeWidth,height:activeHeight)
  _ = try integers(activeRect)
  try grainRequire(declaredApply.contains(activeRect),"processor declared active/apply bounds")
  var bounds=SIMD4<Int32>(Int32(b[0]),Int32(b[1]),Int32(b[2]),Int32(b[3]))
  try grainRequire(t.device.registryID==cb.device.registryID,"actual texture/commandBuffer same device")
  try grainRequire(t.pixelFormat == .r32Float && t.width==Int(r.z) && t.height==Int(r.w),"Rf actual r32Float/region texture origin contract")
  // No undocumented texture offset: strict 1:1 local gid ↔ output.region min + gid.
  // Every requested tile pixel is written, including zeros outside apply extent/tails.
  let p=try pipeline(cb.device)
  guard let encoder=cb.makeComputeCommandEncoder()else{throw GrainError.unsupported("existing system encoder")}
  encoder.setComputePipelineState(p);encoder.setTexture(t,index:0)
  encoder.setBytes(&r,length:MemoryLayout<SIMD4<Int32>>.stride,index:0)
  encoder.setBytes(&bounds,length:MemoryLayout<SIMD4<Int32>>.stride,index:1)
  let tw=max(1,min(p.threadExecutionWidth,32));let th=max(1,min(8,p.maxTotalThreadsPerThreadgroup/tw))
  let groups=MTLSize(width:(Int(r.z)+tw-1)/tw,height:(Int(r.w)+th-1)/th,depth:1)
  encoder.dispatchThreadgroups(groups,threadsPerThreadgroup:MTLSize(width:tw,height:th,depth:1));encoder.endEncoding()
  // CI owns commit/schedule/queue and task completion. Never commit/wait/create a queue here.

 }
 static func cpu(_ x:Int,_ y:Int)->Float {
  let px=UInt32(truncatingIfNeeded:x),py=UInt32(truncatingIfNeeded:y)
  var n=(px &* 0x9e3779b9) ^ (py &* 0x85ebca6b) ^ 0x021a31b7
  n ^= n>>16;n = n &* 0x7feb352d;n ^= n>>15;n = n &* 0x846ca68b;n ^= n>>16
  return Float(n>>8)*(Float(1)/Float(16777216))-Float(0.5)
 }
}

private enum GrainError:Error { case unsupported(String) }
private func grainRequire(_ condition:Bool,_ reason:String)throws {
 guard condition else {throw GrainError.unsupported(reason)}
}

extension DevelopmentGrainSamplingEngineV1 {
 static let originalPointSHA="775c7009e4a86947f23d2f4b207c261ee578a416585e85133c874d4b261386db"
 static let legacyInputIdentity="legacy-grain-canonical-U-v1"
 static var pointSource:String {
  DevelopmentColorEngineV3.metalSource
   .replacingOccurrences(of:"rawmasterPointV3(sampler src,",with:"rawmasterPointNativeGrainV1(sampler src,sampler grain,")
   .replacingOccurrences(of:"v3noise(src.coord())",with:"grain.sample(grain.coord()).r")
 }
 static var sourceVersion:String { version+"/"+DevelopmentColorEngineV3.sourceSHA256 }
 static func validNativeExtent(_ extent:CGRect)->Bool {
  extent.minX==0 && extent.minY==0 && (try? integers(extent)) != nil
 }
 private static let point:Result<CIKernel,Error> = Result {
  try grainRequire(DevelopmentColorEngineV3.sourceSHA256==originalPointSHA,"original point source identity")
  let reversed=pointSource.replacingOccurrences(of:"rawmasterPointNativeGrainV1(sampler src,sampler grain,",with:"rawmasterPointV3(sampler src,")
    .replacingOccurrences(of:"grain.sample(grain.coord()).r",with:"v3noise(src.coord())")
  try grainRequire(reversed==DevelopmentColorEngineV3.metalSource,"exact inverse point mutation")
  let kernels=try CIKernel.kernels(withMetalString:pointSource)
  guard let result=kernels.first(where:{$0.name=="rawmasterPointNativeGrainV1"})else{throw GrainError.unsupported("point kernel")}
  return result
 }
 /// Called once on the existing source-construction worker. It actually observes
 /// Rf/r32Float, global hash bits and a joined destination; Facts never performs GPU work.
 static func admit(sourceIsRAW:Bool,extent:CGRect)->Set<DevelopmentGrainSamplingVersion> {
  guard sourceIsRAW,validNativeExtent(extent)else{return []}
  do {
   return try autoreleasepool {
    guard let device=MTLCreateSystemDefaultDevice(),device.hasUnifiedMemory else{return []}
    _ = try point.get()
    let context=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
    defer{context.clearCaches()}
    let probe=try image(CGRect(x:0,y:0,width:1,height:1))
    var pixel=SIMD4<Float>(repeating:Float.nan)
    try withUnsafeMutableBytes(of:&pixel){bytes in
     let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:1,height:1,bytesPerRow:16,format:.RGBAf)
     destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
     destination.isClamped=false;destination.isDithered=false;destination.isFlipped=false
     let task=try context.startTask(toRender:probe,to:destination)
     do{_ = try task.waitUntilCompleted()}catch{let first=error;_ = try? task.waitUntilCompleted();throw first}
    }
    try grainRequire(pixel.x.bitPattern==cpu(0,0).bitPattern && pixel.y.isFinite && pixel.z.isFinite && pixel.w.isFinite,"observed native grain probe")
    return [.sourceNativeLatticeV1]
   }
  }catch{return []}
 }
 static func apply(_ payload:DevelopmentAdjustmentsV3,to input:CIImage,context:CIContext?,checkCancellation:(()throws->Void)?)throws->CIImage {
  try checkCancellation?()
  try grainRequire(context != nil && validNativeExtent(input.extent),"native grain context/grid required")
  let grain=try image(input.extent).samplingNearest()
  let l=payload.light,c=payload.color,b=payload.blackAndWhite
  let args:[Any]=[input,grain,CIVector(x:l.brightness,y:l.contrast,z:l.blackPoint,w:0),CIVector(x:c.saturation,y:c.vibrance,z:c.cast,w:0),CIVector(x:b.intensity,y:b.neutrals,z:b.tone,w:b.grain),CIVector(x:l.enabled ? 1:0,y:c.enabled ? 1:0,z:b.enabled ? 1:0,w:0)]
  guard let result=try point.get().apply(extent:input.extent,roiCallback:{_,r in r},arguments:args)else{throw GrainError.unsupported("native grain graph")}
  try checkCancellation?();return result
 }
 static func stageIdentity(_ payload:DevelopmentAdjustmentsV3)->String {
  payload.blackAndWhite.grainSamplingVersion==nil ? "":"/grain:"+sourceVersion
 }
}
