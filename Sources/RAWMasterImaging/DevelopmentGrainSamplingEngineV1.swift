import Foundation
import CoreImage
import Metal
import RAWMasterCore
import RAWMasterImage

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
 kernel void rmSizedRoughnessGrain(texture2d<float,access::write> out [[texture(0)]],
   constant int4 &region [[buffer(0)]],constant int4 &bounds [[buffer(1)]],
   constant float2 &params [[buffer(2)]],uint2 gid [[thread_position_in_grid]]) {
   if(gid.x>=uint(region.z) || gid.y>=uint(region.w)) return;
   int2 g=int2(region.x+int(gid.x),region.y+region.w-1-int(gid.y)); float value=0.0;
   if(g.x>=bounds.x && g.y>=bounds.y && g.x<bounds.z && g.y<bounds.w) {
    float scale=1.0+params.x*15.0;
    int2 cell=int2(floor(float2(g)/scale));
    auto hash=[](uint2 p)->float {
     uint n=p.x*0x9e3779b9u ^ p.y*0x85ebca6bu ^ 0x021a31b7u;
     n^=n>>16;n*=0x7feb352du;n^=n>>15;n*=0x846ca68bu;n^=n>>16;
     return float(n>>8)*(1.0/16777216.0)-.5;
    };
    float a=hash(uint2(cell)),b=hash(uint2(cell+int2(17,29)));
    value=mix(a,(a+b)*.5,1.0-params.y);
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
 private static var cachedSized:(UInt64,MTLComputePipelineState)?
 private static func sizedPipeline(_ device:MTLDevice)throws->MTLComputePipelineState {
  lock.lock();defer{lock.unlock()}
  if let c=cachedSized {try grainRequire(c.0==device.registryID,"same actual sized device");return c.1}
  let library=try device.makeLibrary(source:metalSource,options:nil)
  guard let fn=library.makeFunction(name:"rmSizedRoughnessGrain")else{throw GrainError.unsupported("sized lattice function")}
  let p=try device.makeComputePipelineState(function:fn);cachedSized=(device.registryID,p);return p
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
 static func image(_ extent:CGRect,effects:DevelopmentEffectsV3?,activeBounds:CGRect?=nil)throws->CIImage {
  guard let effects, effects.usesSizeRoughnessSampling else { return try image(extent,activeBounds:activeBounds) }
  try effects.validate()
  let i=try integers(extent),active=activeBounds ?? extent,b=try integers(active)
  try grainRequire(extent.contains(active),"sized active bounds contained by apply extent")
  let bounds=[Int(b.x),Int(b.y),Int(b.x+b.z),Int(b.y+b.w)],applyExtent=[Int(i.x),Int(i.y),Int(i.z),Int(i.w)]
  return try apply(withExtent:extent,inputs:nil,arguments:["bounds":bounds,"applyExtent":applyExtent,
    "grainSize":effects.grainSize ?? 0.25,"grainRoughness":effects.grainRoughness ?? 0.5])
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
  let size=arguments?["grainSize"] as? Double
  let p=try size == nil ? pipeline(cb.device):sizedPipeline(cb.device)
  guard let encoder=cb.makeComputeCommandEncoder()else{throw GrainError.unsupported("existing system encoder")}
  encoder.setComputePipelineState(p);encoder.setTexture(t,index:0)
  encoder.setBytes(&r,length:MemoryLayout<SIMD4<Int32>>.stride,index:0)
  encoder.setBytes(&bounds,length:MemoryLayout<SIMD4<Int32>>.stride,index:1)
  if let size {
   let roughness=arguments?["grainRoughness"] as? Double ?? 0.5
   try grainRequire((0...1).contains(size) && (0...1).contains(roughness),"sized grain parameters outside 0...1")
   var params=SIMD2<Float>(Float(size),Float(roughness))
   encoder.setBytes(&params,length:MemoryLayout<SIMD2<Float>>.stride,index:2)
  }
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
 static func cpuSized(_ x:Int,_ y:Int,size:Double,roughness:Double)->Float {
  let scale=1+size*15,cx=Int(floor(Double(x)/scale)),cy=Int(floor(Double(y)/scale))
  let a=cpu(cx,cy),b=cpu(cx+17,cy+29)
  return a+(b-a)*Float(0.5*(1-roughness))
 }
}

private enum GrainError:Error { case unsupported(String) }
private func grainRequire(_ condition:Bool,_ reason:String)throws {
 guard condition else {throw GrainError.unsupported(reason)}
}

extension DevelopmentGrainSamplingEngineV1 {
 static let originalPointSHA="9aa99ca63a6b87e084a8eb430435f3996e01510e5ef7a73c276169fa2b4d3f7c"
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
  let grain=try image(input.extent,effects:payload.effects).samplingNearest()
  let l=payload.light,c=payload.color,b=payload.blackAndWhite
  let effectGrain=payload.effects?.enabled == true ? payload.effects?.grain ?? 0:0
  let combinedGrain=min(1,b.grain+effectGrain)
  let args:[Any]=[input,grain,CIVector(x:l.brightness,y:l.contrast,z:l.blackPoint,w:l.whites),CIVector(x:c.saturation,y:c.vibrance,z:c.cast,w:0),CIVector(x:b.intensity,y:b.neutrals,z:b.tone,w:combinedGrain),CIVector(x:l.enabled ? 1:0,y:c.enabled ? 1:0,z:b.enabled ? 1:0,w:0)]
  guard let result=try point.get().apply(extent:input.extent,roiCallback:{_,r in r},arguments:args)else{throw GrainError.unsupported("native grain graph")}
  try checkCancellation?();return result
 }
 private static let colorGrain: Result<CIKernel, Error> = Result {
  let lattice = try RAWMasterImageKernel.source(.colorGrainLattice)
  let source = #"""
  #include <metal_stdlib>
  #include <CoreImage/CoreImage.h>
  using namespace metal;
  extern "C" { namespace coreimage {
  \#(lattice)
  float3 rmColorGrainEncode(float3 c) {
    float3 a=abs(c);
    return sign(c)*select(1.055*pow(a,float3(1.0/2.4))-.055,12.92*a,a<=.0031308);
  }
  float3 rmColorGrainDecode(float3 c) {
    float3 a=abs(c);
    return sign(c)*select(pow((a+.055)/1.055,float3(2.4)),a/12.92,a<=.04045);
  }
  [[stitchable]] float4 rmEffectsColorGrain(sampler src,float4 settings,destination dest) {
    float2 at=dest.coord(); float4 p=src.sample(src.transform(at));
    if (!all(isfinite(p)) || p.a<=0) return p;
    // Coordinates are source-native before crop or geometry. A proxy pixel samples the
    // same four lattice values as the bilinear FIT presentation of the native grain.
    float noise=rmSourceGrainSample(at,settings);
    float3 encoded=rmColorGrainEncode(p.rgb/p.a);
    float level=clamp(dot(encoded,float3(.2126,.7152,.0722)),0.0,1.0);
    encoded+=noise*.06*settings.x*(.35+sqrt(level));
    return float4(rmColorGrainDecode(encoded)*p.a,p.a);
  }
  } }
  """#
  guard let kernel = try CIKernel.kernels(withMetalString: source).first(where: { $0.name == "rmEffectsColorGrain" }) else {
   throw GrainError.unsupported("colour grain kernel")
  }
  return kernel
 }
 static func colorGrainSettings(_ effects: DevelopmentEffectsV3, scale: Double) -> CIVector {
  let size = effects.usesSizeRoughnessSampling ? effects.grainSize ?? 0.25 : -1
  return CIVector(x: effects.grain, y: size, z: effects.grainRoughness ?? 0.5, w: scale)
 }
 static func applyColorGrain(_ effects: DevelopmentEffectsV3, to input: CIImage, proxyScale: Double) throws -> CIImage {
  guard proxyScale > 0, proxyScale <= 1 else { throw GrainError.unsupported("colour grain source scale") }
  let settings = colorGrainSettings(effects,scale:proxyScale)
  guard let output = try colorGrain.get().apply(extent: input.extent, roiCallback: { _, rect in rect }, arguments: [input,settings]) else {
   throw GrainError.unsupported("colour grain graph")
  }
  return output
 }
 static func stageIdentity(_ payload:DevelopmentAdjustmentsV3)->String {
  let legacy=payload.blackAndWhite.grainSamplingVersion==nil ? "":"/grain:"+sourceVersion
  let effects=payload.effects?.enabled == true && (payload.effects?.grain ?? 0) != 0 ? "/effects-grain:"+sourceVersion:""
  let sized=payload.effects?.usesSizeRoughnessSampling == true ? "/sized-roughness-grain-v1":""
  let color = !effects.isEmpty && !payload.blackAndWhite.enabled ? "/effects-color-grain-v1" : ""
  return legacy+effects+sized+color
 }
}
