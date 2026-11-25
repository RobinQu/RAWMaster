import CoreImage
import Foundation
import Metal
import RAWMasterCore

/// Source-normalized Lens Blur depth refinements. CPU only prepares bounded sparse metadata;
/// feather, pressure, flow accumulation and signed depth adjustment are evaluated on GPU.
enum DevelopmentLensBlurRefinementEngineV3 {
  static let operatorVersion="lens-blur-refinement-v2-auto-mask/sparse-grid/source-short-edge/dab-color-similarity/flow-capped-by-amount/f32"
  private static let kernel:Result<CIKernel,Error>=Result {
    guard DevelopmentKernelCapability.supported else{throw DevelopmentError.unsupportedEngine}
    let all=try CIKernel.kernels(withMetalString:metalSource)
    guard let value=all.first(where:{$0.name=="rmLensBlurRefine"})else{throw DevelopmentError.unsupportedEngine}
    return value
  }
  static func prewarm(){_ = try? kernel.get()}
  private struct Entry {var x,y,index:Int32}

  static func apply(_ strokes:[DevelopmentLensBlurRefinementStrokeV3],to source:CIImage)throws->CIImage? {
    try DevelopmentLensBlurRefinementStrokeV3.validateStrokes(strokes)
    let active=strokes.filter{$0.stroke.strength>0 && $0.flow>0 && $0.stroke.points.contains{$0.pressure>0}}
    guard !active.isEmpty else{return nil}
    let extent=source.extent
    guard extent.origin == .zero,extent.width>=1,extent.height>=1,
      extent.width==floor(extent.width),extent.height==floor(extent.height) else{throw DevelopmentV3Error.invalidGraph}
    let size=DevelopmentPixelSize(width:Int(extent.width),height:Int(extent.height))
    var totalDabs=0
    for item in strokes {
      let count=try item.stroke.dabCount(sourceSize:size)
      guard totalDabs<=DevelopmentLocalEditLimits.maximumTotalDabs-count else{throw EditingError.invalidRecipe}
      totalDabs+=count
    }
    var output=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:1)).cropped(to:extent)
    for item in active {
      let telemetry=ImagePerformanceTelemetry.shared.begin(operation:"DevelopmentLensBlurRefinementEngineV3.apply",stage:item.mode.rawValue+(item.autoMask == true ? "-auto-mask":""),boundary:.graphBuild)
      var outcome=ImagePerformanceOutcome.failed
      defer{ImagePerformanceTelemetry.shared.end(telemetry,outcome:outcome,pixelCount:size.width*size.height)}
      output=try apply(item,to:output,source:source,size:size)
      outcome = .succeeded
    }
    return output
  }

  private static func apply(_ item:DevelopmentLensBlurRefinementStrokeV3,to image:CIImage,source:CIImage,size:DevelopmentPixelSize)throws->CIImage {
    let operation=item.stroke
    let radius=Float(operation.radiusInShortEdge*Double(min(size.width,size.height)))
    let slack=max(0.001,Float(max(size.width,size.height))*0x1p-20),cell=max(1,radius)+2*slack
    let count=try operation.dabCount(sourceSize:size)
    let entryStorage=try DevelopmentLocalAllocationV3(bytes:count*16*MemoryLayout<Entry>.stride,kind:.metadata)
    let entries=entryStorage.pointer.bindMemory(to:Entry.self,capacity:count*16)
    var used=0
    let dabs=try DevelopmentLocalTableV3(texels:count){out in
      var index=0
      try operation.forEachDab(sourceSize:size){dab in
        let x=Float(dab.position.x*Double(size.width)),y=Float(dab.position.y*Double(size.height))
        out[index] = .init(x,y,Float(dab.pressure),1)
        let x0=Int(floor((x-radius-slack)/cell)),x1=Int(floor((x+radius+slack)/cell))
        let y0=Int(floor((y-radius-slack)/cell)),y1=Int(floor((y+radius+slack)/cell))
        guard (x1-x0+1)*(y1-y0+1)<=16,used<=count*16-(x1-x0+1)*(y1-y0+1)else{throw DevelopmentPreviewError.memoryBudgetExceeded}
        for cy in y0...y1{for cx in x0...x1{
          entries[used] = .init(x:Int32(cx),y:Int32(cy),index:Int32(index));used+=1
        }}
        index+=1
      }
    }
    var sorted:UnsafeMutableBufferPointer<Entry> = .init(start:entries,count:used)
    sorted.sort{if $0.y != $1.y{return $0.y<$1.y};if $0.x != $1.x{return $0.x<$1.x};return $0.index<$1.index}
    var groups=0
    for i in 0..<used where i==0 || entries[i].x != entries[i-1].x || entries[i].y != entries[i-1].y{groups+=1}
    let headers=try DevelopmentLocalTableV3(texels:groups){out in
      var group=0,start=0
      for i in 1...used{
        if i==used || entries[i].x != entries[start].x || entries[i].y != entries[start].y{
          out[group] = .init(Float(entries[start].x),Float(entries[start].y),Float(start),Float(i-start))
          start=i;group+=1
        }
      }
    }
    let indices=try DevelopmentLocalTableV3(texels:(used+3)/4){out in
      for i in 0..<used{out[i/4][i%4]=Float(entries[i].index)}
    }
    let args:[Any]=[image,dabs.image.samplingNearest(),headers.image.samplingNearest(),indices.image.samplingNearest(),source.samplingNearest(),
      CIVector(x:Double(radius),y:operation.strength,z:Double(cell),w:Double(groups)),
      CIVector(x:0,y:0,z:Double(size.width),w:Double(size.height)),
      CIVector(x:Double(dabs.width),y:Double(dabs.height),z:Double(headers.width),w:Double(headers.height)),
      CIVector(x:Double(indices.width),y:Double(indices.height),z:item.feather,w:item.flow),
      CIVector(x:item.mode == .focus ? -1:1,y:item.autoMask == true ? 1:0,z:0,w:0)]
    guard let result=try kernel.get().apply(extent:image.extent,roiCallback:{index,r in
      switch index{case 0:return r;case 1:return dabs.image.extent;case 2:return headers.image.extent;case 3:return indices.image.extent;
        default:return item.autoMask == true ? r.insetBy(dx:-Double(radius),dy:-Double(radius)):.zero}
    },arguments:args)else{throw DevelopmentV3Error.invalidGraph}
    return result
  }

  private static let metalSource=#"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
float4 rmLensBlurRefineTable(sampler s,int index,float width,float height){
 int w=int(width);float2 p=float2(float(index%w)+.5,float(index/w)+.5);return s.sample(s.transform(p));
}
[[stitchable]] float4 rmLensBlurRefine(sampler previous,sampler dabs,sampler headers,sampler indices,sampler src,
 float4 brush,float4 source,float4 sizes,float4 config,float4 mode,destination dest){
 float2 world=dest.coord(),p=float2(world.x,source.w-world.y);
 float4 before=previous.sample(previous.transform(world));if(!all(isfinite(before)))return float4(as_type<float>(0x7fc00000u));
 int2 cell=int2(floor(p/brush.z));int lo=0,hi=int(brush.w);
 while(lo<hi){int mid=(lo+hi)/2;float4 h=rmLensBlurRefineTable(headers,mid,sizes.z,sizes.w);int2 key=int2(h.xy);
  if(key.y<cell.y||(key.y==cell.y&&key.x<cell.x))lo=mid+1;else hi=mid;}
 if(lo>=int(brush.w))return before;
 float4 header=rmLensBlurRefineTable(headers,lo,sizes.z,sizes.w);int2 key=int2(header.xy);
 if(any(key!=cell))return before;
 float4 current=src.sample(src.transform(world));if(!all(isfinite(current)))return float4(as_type<float>(0x7fc00000u));
 float3 currentColor=current.a>0?current.rgb/current.a:float3(0);
 uint start=uint(header.z),count=uint(header.w);float remaining=1;
 for(uint n=0;n<count;n++){
  uint at=start+n;float4 packed=rmLensBlurRefineTable(indices,int(at/4),config.x,config.y);
  int index=int(packed[int(at%4)]);float4 dab=rmLensBlurRefineTable(dabs,index,sizes.x,sizes.y);
  float distanceNormalized=distance(p,dab.xy)/brush.x;
  float shape=config.z<=0?(distanceNormalized<=1?1:0):(1-smoothstep(1-config.z,1.0,distanceNormalized));
  if(shape<=0)continue;
  float edge=1;
  if(mode.y>.5){
   float4 center=src.sample(src.transform(float2(dab.x,source.w-dab.y)));
   if(!all(isfinite(center)))return float4(as_type<float>(0x7fc00000u));
   float3 centerColor=center.a>0?center.rgb/center.a:float3(0);
   float delta=length(currentColor-centerColor);
   edge=current.a>0&&center.a>0?1-smoothstep(.04,.16,delta):0;
  }
  remaining*=1-shape*config.w*dab.z*edge;
 }
 float coverage=(1-remaining)*brush.y;
 return float4(clamp(before.r+coverage*mode.x,-1.0,1.0),0,0,1);
}
} }
"""#
}
