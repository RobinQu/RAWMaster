import Foundation
import CoreImage
import Metal
import RAWMasterCore

/// Fixed source-space operators. No donor search, face detection, or geometry in replay.
enum DevelopmentLocalEngineV3 {
  static let operatorVersion = "local-v3/retouch-texture-transfer25/clone-direct/manual4nearest-f32/ordered-coverage/red-eye-local-v1/alpha-preserved/work-retouch212-clone5-redEye2"
  static let alphaMinimum: Float = 1/65535
  private static let kernels: Result<[CIKernel],Error> = Result {
    guard DevelopmentKernelCapability.supported else { throw DevelopmentError.unsupportedEngine }
    return try CIKernel.kernels(withMetalString:metalSource)
  }
  static func kernel(_ name: String) throws -> CIKernel {
    guard let value = try kernels.get().first(where:{$0.name == name}) else { throw DevelopmentV3Error.invalidGraph }; return value
  }
  static func active(_ edits: DevelopmentLocalEditsV3) -> Bool {
    edits.operations.contains { $0.tool == .retouch ? edits.retouchEnabled:edits.redEyeEnabled }
  }
  static func validate(_ edits: DevelopmentLocalEditsV3) throws {
    _ = try DevelopmentLocalWorkEstimatorV1.estimate(edits)
  }
  /// Checked synchronous task completion for NEW local-analysis reads only. This does not alter
  /// the historical finite validator; a failed/no-write backend cannot attest visible effect.
  static func read(_ image: CIImage, rect: CGRect, context: CIContext,
                   _ body: (UnsafeBufferPointer<SIMD4<Float>>) throws -> Void) throws {
    guard rect.width > 0,rect.height > 0,rect.width <= 512,rect.height <= 512,
      rect.width == floor(rect.width),rect.height == floor(rect.height) else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let width = Int(rect.width),height = Int(rect.height),row = width*16
    let storage = try DevelopmentLocalAllocationV3(bytes:row*height,kind:.analysis)
    let destination = CIRenderDestination(bitmapData:storage.pointer,width:width,height:height,bytesPerRow:row,format:.RGBAf)
    destination.colorSpace = DevelopmentColorEngineV3.linearSRGB; destination.alphaMode = .premultiplied
    destination.isClamped = false; destination.isDithered = false; destination.isFlipped = true
    let task = try context.startTask(toRender:image,from:rect,to:destination,at:.zero)
    _ = try task.waitUntilCompleted() // resource/worker ownership never ends at cancellation alone
    let values = UnsafeBufferPointer(start:storage.pointer.assumingMemoryBound(to:SIMD4<Float>.self),count:width*height)
    for p in values { guard p.x.isFinite,p.y.isFinite,p.z.isFinite,p.w.isFinite else { throw DevelopmentError.invalidEncoding } }
    try body(values)
  }
  static func reduction(_ image: CIImage, context: CIContext,
                        checkCancellation: (() throws -> Void)? = nil) throws -> SIMD4<Float> {
    try DevelopmentCheckedMaximumV3.maximum(image,domain:image.extent,context:context,wholeMapping:.originZero,checkCancellation:checkCancellation)
  }
  static func validatePixels(_ image: CIImage, context: CIContext, checkCancellation: (() throws -> Void)? = nil) throws {
    guard let mask = try kernel("rmLocalInvalid").apply(extent:image.extent,roiCallback:{ _,r in r },arguments:[image.samplingNearest()]) else { throw DevelopmentV3Error.invalidGraph }
    let p = try reduction(mask,context:context,checkCancellation:checkCancellation)
    guard p == .zero else { throw DevelopmentError.invalidEncoding }
  }
  static func apply(_ edits: DevelopmentLocalEditsV3,to input: CIImage,context: CIContext, checkCancellation: (() throws -> Void)? = nil) throws -> CIImage {
    try validate(edits)
    guard active(edits) else { return input }
    guard let binding = edits.sourceBinding, input.extent == CGRect(x:0,y:0,width:binding.orientedWidth,height:binding.orientedHeight) else { throw DevelopmentV3Error.invalidGraph }
    try validatePixels(input,context:context,checkCancellation:checkCancellation)
    var image = input
    for op in edits.operations where op.tool == .retouch ? edits.retouchEnabled:edits.redEyeEnabled {
      try Task.checkCancellation();try checkCancellation?()
      image = try apply(op,to:image,size:binding.sourceSize)
    }
    try validatePixels(image,context:context,checkCancellation:checkCancellation)
    return image
  }
  private struct Entry { var x,y,index: Int32 }
  static func apply(_ operation: DevelopmentLocalEdit,to image: CIImage,size: DevelopmentPixelSize) throws -> CIImage {
    try operation.validate()
    let edits = DevelopmentLocalEditsV3(sourceBinding:.init(sourceContentID:operation.sourceContentID,exifOrientation:1,orientedWidth:size.width,orientedHeight:size.height),
      retouchEnabled:operation.tool == .retouch,redEyeEnabled:operation.tool == .redEye,operations:[operation])
    try validate(edits)
    if operation.stroke.strength == 0 || !operation.stroke.points.contains(where:{$0.pressure>0}) { return image }
    let radius = Float(operation.stroke.radiusInShortEdge*Double(min(size.width,size.height)))
    let slack = max(0.001,Float(max(size.width,size.height))*0x1p-20), cell = max(1,radius)+2*slack
    let count = try operation.stroke.dabCount(sourceSize:size)
    let entryStorage = try DevelopmentLocalAllocationV3(bytes:count*16*MemoryLayout<Entry>.stride,kind:.metadata)
    let entries = entryStorage.pointer.bindMemory(to:Entry.self,capacity:count*16)
    var used = 0
    var affectedBounds = CGRect.null
    let dabs = try DevelopmentLocalTableV3(texels:count) { out in
      var index = 0
      try operation.stroke.forEachDab(sourceSize:size) { dab in
        let x = Float(dab.position.x*Double(size.width)),y = Float(dab.position.y*Double(size.height))
        out[index] = .init(x,y,Float(dab.pressure),1)
        if dab.pressure > 0 {
          let reach=Double(radius+slack)
          let disk=CGRect(x:Double(x)-reach,y:Double(size.height)-Double(y)-reach,width:2*reach,height:2*reach)
          affectedBounds=affectedBounds.union(disk)
        }
        // Sparse source-space cells; conservative Float slack, no W*H dense metadata.
        let x0 = Int(floor((x-radius-slack)/cell)), x1 = Int(floor((x+radius+slack)/cell))
        let y0 = Int(floor((y-radius-slack)/cell)), y1 = Int(floor((y+radius+slack)/cell))
        guard (x1-x0+1)*(y1-y0+1) <= 16, used <= count*16-(x1-x0+1)*(y1-y0+1) else { throw DevelopmentPreviewError.memoryBudgetExceeded }
        for cy in y0...y1 { for cx in x0...x1 {
          entries[used] = .init(x:Int32(cx),y:Int32(cy),index:Int32(index)); used += 1
        } }
        index += 1
      }
    }
    var sorted: UnsafeMutableBufferPointer<Entry> = .init(start:entries,count:used)
    sorted.sort { (a: Entry,b: Entry) -> Bool in
      if a.y != b.y { return a.y < b.y }
      if a.x != b.x { return a.x < b.x }
      return a.index < b.index
    }
    var groups = 0
    for i in 0..<used where i == 0 || entries[i].x != entries[i-1].x || entries[i].y != entries[i-1].y { groups += 1 }
    let headers = try DevelopmentLocalTableV3(texels:groups) { out in
      var group = 0,start = 0
      for i in 1...used {
        if i == used || entries[i].x != entries[start].x || entries[i].y != entries[start].y {
          out[group] = .init(Float(entries[start].x),Float(entries[start].y),Float(start),Float(i-start))
          start = i; group += 1
        }
      }
    }
    let indices = try DevelopmentLocalTableV3(texels:(used+3)/4) { out in
      for i in 0..<used { out[i/4][i%4] = Float(entries[i].index) }
    }
    let first = operation.stroke.points[0].position, donor = operation.sourceSample ?? first
    let dx = Float((donor.x-first.x)*Double(size.width)), dy = Float((donor.y-first.y)*Double(size.height))
    let e = image.extent, lowpass = Double(radius)/2, maskBounds = affectedBounds
    let sourceROI: (CGRect)->CGRect = { requested in
      let original=requested.intersection(e),covered=original.intersection(maskBounds)
      if covered.isNull || covered.isEmpty { return original }
      let a=covered.insetBy(dx:-lowpass-2,dy:-lowpass-2)
      let b=a.offsetBy(dx:Double(dx),dy:-Double(dy))
      return original.union(a).union(b).intersection(e)
    }
    let args: [Any] = [image.clampedToExtent().samplingNearest(),dabs.image.samplingNearest(),headers.image.samplingNearest(),indices.image.samplingNearest(),
      CIVector(x:Double(radius),y:operation.stroke.strength,z:Double(cell),w:Double(groups)),
      CIVector(x:Double(dx),y:Double(dy),z:Double(size.width),w:Double(size.height)),
      CIVector(x:Double(dabs.width),y:Double(dabs.height),z:Double(headers.width),w:Double(headers.height)),
      CIVector(x:Double(indices.width),y:Double(indices.height),z:operation.tool == .retouch ? 0:1,w:operation.retouchMode == .clone ? 1:0)]
    guard let result = try kernel("rmLocalEdit").apply(extent:e,roiCallback:{ index,r in
      switch index { case 0:return sourceROI(r); case 1:return dabs.image.extent; case 2:return headers.image.extent; default:return indices.image.extent }
    },arguments:args) else { throw DevelopmentV3Error.invalidGraph }
    return result
  }
  static let metalSource = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float4 rmLocalTable(sampler s,int index,float width,float height) {
 int w=int(width);float2 p=float2(float(index%w)+.5,float(index/w)+.5);
 return s.sample(s.transform(p));
}
float rmLocalEnc(float x){return x<=.0031308?12.92*x:1.055*pow(x,1.0/2.4)-.055;}
float rmLocalDec(float x){return x<=.04045?x/12.92:pow((x+.055)/1.055,2.4);}
float3 rmLocalEncoded(float3 c){c=clamp(c,0.0,1.0);return float3(rmLocalEnc(c.x),rmLocalEnc(c.y),rmLocalEnc(c.z));}
float4 rmLocalSample(sampler s,float2 p){return s.sample(s.transform(p));}
// Native source extent is validated as(0,0,width,height). Clamp source-center coordinates
// before interpolation, matching the frozen CPU/source-edge rule. Every fetch is nearest;
// hardware linear fraction precision is not the authority for the Float bilinear contract.
float4 rmLocalBilinear(sampler s,float2 p,float2 size){
 float2 at=clamp(p-.5,float2(0),size-1.0),base=floor(at),f=at-base;
 float2 next=min(base+1.0,size-1.0);
 float4 a=rmLocalSample(s,base+.5),b=rmLocalSample(s,float2(next.x,base.y)+.5);
 float4 c=rmLocalSample(s,float2(base.x,next.y)+.5),d=rmLocalSample(s,next+.5);
 return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}
float4 rmLocalLow(sampler s,float2 p,float radius,float2 size){
 float weights[5]={1,4,6,4,1};float4 total=float4(0);
 for(int j=0;j<5;j++)for(int i=0;i<5;i++)total+=rmLocalBilinear(s,p+float2(i-2,j-2)*(radius/4.0),size)*(weights[i]*weights[j]/256.0);
 return total;
}
[[stitchable]] float4 rmLocalInvalid(sampler src,destination dest){
 float4 p=rmLocalSample(src,dest.coord());return float4(!all(isfinite(p))||p.a<0||p.a>1?1:0);
}
[[stitchable]] float4 rmLocalDifference(sampler before,sampler after,destination dest){
 float4 a=rmLocalSample(before,dest.coord()),b=rmLocalSample(after,dest.coord());
 if(!all(isfinite(a))||!all(isfinite(b)))return float4(as_type<float>(0x7fc00000u));
 return float4(max(max(abs(a.r-b.r),abs(a.g-b.g)),abs(a.b-b.b)),abs(a.a-b.a),0,0);
}
[[stitchable]] float4 rmLocalEdit(sampler src,sampler dabs,sampler headers,sampler indices,
 float4 brush,float4 source,float4 sizes,float4 indicesSize,destination dest){
 float2 world=dest.coord(),p=float2(world.x,source.w-world.y);float4 original=rmLocalSample(src,world);
 if(original.a<1.0/65535.0)return original;
 int2 cell=int2(floor(p/brush.z));int lo=0,hi=int(brush.w);
 while(lo<hi){int mid=(lo+hi)/2;float4 h=rmLocalTable(headers,mid,sizes.z,sizes.w);int2 key=int2(h.xy);
  if(key.y<cell.y||(key.y==cell.y&&key.x<cell.x))lo=mid+1;else hi=mid;}
 if(lo>=int(brush.w))return original;
 float4 header=rmLocalTable(headers,lo,sizes.z,sizes.w);int2 key=int2(header.xy);
 if(any(key!=cell))return original;
 uint start=uint(header.z),count=uint(header.w);float remaining=1;
 for(uint n=0;n<count;n++){
  uint at=start+n;float4 packed=rmLocalTable(indices,int(at/4),indicesSize.x,indicesSize.y);
  int index=int(packed[int(at%4)]);float4 dab=rmLocalTable(dabs,index,sizes.x,sizes.y);
  float weight=(1-smoothstep(.7,1.0,distance(p,dab.xy)/brush.x))*brush.y*dab.z;
  remaining*=1-weight;
 }
 float coverage=1-remaining;if(coverage<=0)return original;
 float3 u=original.rgb/original.a;
 if(indicesSize.z>0.5){
  float3 c=rmLocalEncoded(u);float high=max(c.r,max(c.g,c.b)),low=min(c.r,min(c.g,c.b));
  if((low>.6&&high>.9)||(c.b>.8&&c.r-c.b<=.15))return original;
  float red=smoothstep(.15,.30,c.r-max(c.g,c.b))*smoothstep(.25,.45,c.r)*smoothstep(1.5,2.0,c.r/(c.g+c.b+.01));
  float weight=coverage*red;if(weight<=0)return original;
  // G/B are preserved from the original extended-linear source, not round-tripped/clamped.
  float corrected=rmLocalDec(min(c.r,(c.g+c.b)/2));
  return float4(mix(original.r,corrected*original.a,weight),original.g,original.b,original.a);
 }
 float2 donor=world+float2(source.x,-source.y);
 if(donor.x<.5||donor.y<.5||donor.x>source.z-.5||donor.y>source.w-.5)return float4(as_type<float>(0x7fc00000u));
 float4 d=rmLocalBilinear(src,donor,source.zw);
 if(d.a<1.0/65535.0)return original;
 if(indicesSize.w>.5)return float4(mix(u,d.rgb/d.a,coverage)*original.a,original.a);
 float4 lt=rmLocalLow(src,world,brush.x,source.zw),ld=rmLocalLow(src,donor,brush.x,source.zw);
 if(lt.a<1.0/65535.0||ld.a<1.0/65535.0)return original;
 float3 healed=d.rgb/d.a-ld.rgb/ld.a+lt.rgb/lt.a;
 return float4(mix(u,healed,coverage)*original.a,original.a);
}
} }
"""#
}
