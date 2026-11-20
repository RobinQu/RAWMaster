import XCTest
import CoreImage
import Foundation
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentNaturalCubicCurvesV1Tests:XCTestCase {
  typealias E=DevelopmentNaturalCubicCurvesV1
  private func curves()->DevelopmentCurvesV3 {
    .init(enabled:true,rgb:.init(curve:.init(points:[.init(x:0,y:0),.init(x:0.49591173237104025,y:0.5963525835798932),.init(x:1,y:1)])),algorithm:.naturalCubicGamma512LumaV1)
  }
  func testCPUNaturalKnotsEndpointConditionsAndTangentExtrapolation()throws {
    let p=curves().rgb.curve,m=try E.model(p)
    XCTAssertEqual(m.second.first,0);XCTAssertEqual(m.second.last,0)
    for point in p.points {XCTAssertEqual(try E.evaluate(m,Float(point.x)),Float(point.y),accuracy:2e-6)}
    XCTAssertEqual(try E.evaluate(m,-0.25),m.y[0]+m.b[0]*(-0.25-m.x[0]),accuracy:2e-6)
    let linear=try E.model(.init());XCTAssertEqual(try E.evaluate(linear,0.25),0.25,accuracy:2e-6)
    XCTAssertEqual(try E.evaluate(linear,1.25),1.25,accuracy:2e-6)
    let constantCurve=DevelopmentCurve(points:[.init(x:0,y:0.25),.init(x:1,y:0.25)])
    let constant=try E.model(constantCurve),row=try E.row(.init(curve:constantCurve))
    let fixedCoordinates:[Float]=[-0.25,0,0.25,1,1.25]
    for x in fixedCoordinates{XCTAssertEqual(try E.evaluate(constant,x),0.25,accuracy:2e-6);XCTAssertEqual(try E.sample(row,x),row[0],accuracy:2e-7)}
    XCTAssertThrowsError(try E.evaluate(m,.infinity));XCTAssertThrowsError(try E.evaluate(m,.nan))
  }
  func testCPUHalfTableLayoutAndPreClampOverflowAreStrict()throws {
    let p=curves(),t=try E.tables(p)
    XCTAssertEqual(t.rows.count,4);XCTAssertEqual(t.data.count,16384)
    let words=t.data.withUnsafeBytes{Array($0.bindMemory(to:UInt16.self))}
    for row in 0..<4 {for column in [0,1,255,510,511] {
      let at=(row*512+column)*4
      XCTAssertEqual(words[at],Float16(t.rows[row][column]).bitPattern)
      XCTAssertEqual(words[at+1],words[at]);XCTAssertEqual(words[at+2],words[at])
      XCTAssertEqual(words[at+3],Float16(1).bitPattern)
    }}
    var tiny=p;tiny.rgb.inputBlack=0;tiny.rgb.inputWhite=Double(Float.leastNonzeroMagnitude)
    XCTAssertNoThrow(try tiny.validate());XCTAssertLessThan(Float(tiny.rgb.inputBlack),Float(tiny.rgb.inputWhite))
    XCTAssertThrowsError(try E.tables(tiny)) // normalize overflow cannot be rescued by ordinate clamp.
    var unrepresentable=p;unrepresentable.rgb.inputBlack=0.8;unrepresentable.rgb.inputWhite=0.8000000000000001
    XCTAssertNoThrow(try unrepresentable.validate());XCTAssertThrowsError(try E.tables(unrepresentable))
    XCTAssertThrowsError(try E.sample(t.rows[0],.infinity));XCTAssertThrowsError(try E.sample(t.rows[0],.nan))
  }
  func testCPUActiveGroupIncludesIdentityRGBTablesAndMasterLumaCoupling()throws {
    let t=try E.tables(curves()),input=SIMD4<Float>(0.2,0.4,0.7,1)
    let color=SIMD3<Float>(try E.sample(t.rows[0],input.x),try E.sample(t.rows[1],input.y),try E.sample(t.rows[2],input.z))
    let l=(color.x*0.30+color.y*0.59)+color.z*0.11,m=try E.sample(t.rows[3],l)
    let expected=try E.scalarTransfer(color,mapped:m),out=try E.referencePixel(input,tables:t)
    XCTAssertEqual(out.x,expected.x,accuracy:2e-6);XCTAssertEqual(out.y,expected.y,accuracy:2e-6);XCTAssertEqual(out.z,expected.z,accuracy:2e-6)
    let independent=try E.sample(t.rows[3],color.x)
    XCTAssertGreaterThan(abs(out.x-independent),0.001) // master is shared luma, not independent master-on-RGB.
    XCTAssertEqual(try E.scalarTransfer(.zero,mapped:0.25),SIMD3<Float>(repeating:0.25))
    XCTAssertThrowsError(try E.scalarTransfer(.init(repeating:Float.greatestFiniteMagnitude),mapped:1))
    XCTAssertThrowsError(try E.referencePixel(.init(Float.greatestFiniteMagnitude,1,1,1e-30),tables:t))
    let hidden=SIMD4<Float>(.nan,0.25,0.5,0),same=try E.referencePixel(hidden,tables:t)
    XCTAssertTrue(same.x.isNaN);XCTAssertEqual(same.w,0) // original finite check must reject; never silently zero.
  }
  private func context()->CIContext {CIContext(options:[.workingFormat:CIFormat.RGBAf.rawValue,.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.cacheIntermediates:false,.memoryTarget:512])}
  private func image(_ value:SIMD4<Float>,width:Int=16,height:Int=12,origin:CGPoint = .zero)->CIImage {
    let pixels=Array(repeating:value,count:width*height),d=pixels.withUnsafeBytes{Data($0)}
    return CIImage(bitmapData:d,bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB).transformed(by:.init(translationX:origin.x,y:origin.y))
  }
  private func read(_ image:CIImage,_ context:CIContext,rect:CGRect?=nil)throws->[SIMD4<Float>] {
    let r=rect ?? image.extent,w=Int(r.width),h=Int(r.height)
    var p=[SIMD4<Float>](repeating:.init(repeating:.nan),count:w*h)
    try p.withUnsafeMutableBytes {b in
      let d=CIRenderDestination(bitmapData:b.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
      d.colorSpace=DevelopmentColorEngineV3.linearSRGB;d.alphaMode = .premultiplied;d.isFlipped=false;d.isClamped=false;d.isDithered=false
      let task=try context.startTask(toRender:image,from:r,to:d,at:.zero)
      do{_ = try task.waitUntilCompleted()}catch{let original=error;_ = try? task.waitUntilCompleted();throw original}
      for v in b.bindMemory(to:Float.self){XCTAssertTrue(v.isFinite)}
    };return p
  }
  func testGPUConstantsHalfRowsCouplingAlphaAndHDRMatchOwnCPU()throws {
    let c=context();defer{c.clearCaches()}
    var p=curves();p.red.curve = .init(points:[.init(x:0,y:0),.init(x:0.4,y:0.2),.init(x:1,y:1)])
    p.blue.curve = .init(points:[.init(x:0,y:0.05),.init(x:1,y:0.9)])
    let t=try E.tables(p)
    let inputs:[SIMD4<Float>]=[.init(0.2,0.4,0.7,1),.init(0.1,0.2,0.35,0.5),.init(1.4,0.6,0.2,1),.init(-0.1,0.2,0.3,1),.init(0,0,0,1),.init(0,0,0,0)]
    for input in inputs {
      let result=try E.apply(p,to:image(input)),expected=try E.referencePixel(input,tables:t),actual=try read(result,c)
      for v in actual {
        XCTAssertEqual(v.x,expected.x,accuracy:2e-4);XCTAssertEqual(v.y,expected.y,accuracy:2e-4);XCTAssertEqual(v.z,expected.z,accuracy:2e-4);XCTAssertEqual(v.w,input.w,accuracy:2e-7)
      }
    }
  }
  func testGPUWholeTileAndTranslatedSourceMappingAndNeutralObjectIdentity()throws {
    let c=context();defer{c.clearCaches()};let p=curves()
    var pixels=[SIMD4<Float>]();pixels.reserveCapacity(32*24)
    for y in 0..<24{for x in 0..<32{
      let alpha:Float=(x+y)%3==0 ? 0.5:1
      let red=Float(x+1)/Float(40),green=Float(y+1)/Float(30),blue=Float((x*7+y*3)%29)/Float(35)
      pixels.append(.init(red*alpha,green*alpha,blue*alpha,alpha))
    }}
    let data=pixels.withUnsafeBytes{Data($0)}
    let source=CIImage(bitmapData:data,bytesPerRow:32*16,size:.init(width:32,height:24),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    let whole=try read(E.apply(p,to:source),c)
    let translated=try E.apply(p,to:source.transformed(by:.init(translationX:7,y:-5)))
    let moved=try read(translated,c);XCTAssertEqual(whole.count,moved.count)
    for (a,e) in zip(moved,whole){XCTAssertEqual(a.x,e.x,accuracy:2e-4);XCTAssertEqual(a.y,e.y,accuracy:2e-4);XCTAssertEqual(a.z,e.z,accuracy:2e-4);XCTAssertEqual(a.w,e.w,accuracy:2e-7)}
    for y in stride(from:0,to:24,by:8){for x in stride(from:0,to:32,by:8){
      let tile=try read(translated,c,rect:.init(x:x+7,y:y-5,width:8,height:8))
      for j in 0..<8{for i in 0..<8{let a=tile[j*8+i],e=whole[(y+j)*32+x+i];XCTAssertEqual(a.x,e.x,accuracy:2e-4);XCTAssertEqual(a.y,e.y,accuracy:2e-4);XCTAssertEqual(a.z,e.z,accuracy:2e-4);XCTAssertEqual(a.w,e.w,accuracy:2e-7)}}
    }}
    // Source sampling remains the caller/default linear policy. Only LUT lookup is nearest.
    var checker=[SIMD4<Float>]();checker.reserveCapacity(32*24)
    for y in 0..<24{for x in 0..<32{let v:Float=(x+y)%2==0 ? 0.05:0.95;checker.append(.init(v,v,v,1))}}
    let checkerBytes=checker.withUnsafeBytes{Data($0)}
    let checkerImage=CIImage(bitmapData:checkerBytes,bytesPerRow:32*16,size:.init(width:32,height:24),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    // Two affine-image fixtures failed to expose different input-sampler behavior. Their
    // raw failures remain retained; they do not prove the optimizer's internal sampling grid.
    // This separate literal witness fixes a fractional lookup IN the kernel itself. It tests
    // the public sampler ABI, not E.apply's internal sampler flags or a whole-graph order.
    let samplerCode = #"""
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;
extern "C" { namespace coreimage {
[[stitchable]] float4 rmCurveSamplerWitness(sampler src,destination dest) {
 return src.sample(src.transform(dest.coord()+float2(.25,.25)));
}
} }
"""#
    let samplerKernels=try CIKernel.kernels(withMetalString:samplerCode)
    let witness=try XCTUnwrap(samplerKernels.first(where:{$0.name=="rmCurveSamplerWitness"}))
    let sampleRect=CGRect(x:1,y:1,width:14,height:10) // all four taps strictly inside source
    func witnessed(_ input:CIImage)throws->[SIMD4<Float>] {
      // Tiny witness returns the complete declared input extent, covering the .25 offset/halo.
      let graph=try XCTUnwrap(witness.apply(extent:checkerImage.extent,roiCallback:{_,_ in checkerImage.extent},arguments:[input]))
      return try read(graph,c,rect:sampleRect)
    }
    let baseline=try read(checkerImage,c,rect:sampleRect)
    let natural=try witnessed(checkerImage)
    let linear=try witnessed(checkerImage.samplingLinear())
    let nearest=try witnessed(checkerImage.samplingNearest())
    var distinguishNearest:Float=0
    let low:Float=0.05,high:Float=0.95,weight:Float=0.25
    for i in natural.indices {
      // A checker has equal opposite diagonal texels and equal orthogonal neighbors.
      // Their known literal values make this four-tap reference independent of top/bottom
      // memory row naming; orientation is already tested by the separate translated chart.
      let v00:Float=baseline[i].x<0.5 ? low:high
      let v10:Float=baseline[i].x<0.5 ? high:low
      let v01=v10,v11=v00,oneMinus=1-weight
      XCTAssertEqual(baseline[i].x,v00,accuracy:2e-4)
      let first=v00*(oneMinus*oneMinus),second=v10*(weight*oneMinus)
      let third=v01*(oneMinus*weight),fourth=v11*(weight*weight)
      let expected=((first+second)+third)+fourth
      for actual in [natural[i],linear[i]] {
        XCTAssertEqual(actual.x,expected,accuracy:2e-4);XCTAssertEqual(actual.y,expected,accuracy:2e-4);XCTAssertEqual(actual.z,expected,accuracy:2e-4)
        XCTAssertEqual(actual.w,1,accuracy:2e-7)
      }
      XCTAssertEqual(natural[i].x,linear[i].x,accuracy:2e-4)
      XCTAssertEqual(nearest[i].x,v00,accuracy:2e-4);XCTAssertEqual(nearest[i].w,1,accuracy:2e-7)
      distinguishNearest=max(distinguishNearest,abs(natural[i].x-nearest[i].x))
    }
    XCTAssertGreaterThan(distinguishNearest,0.001) // an effective, explicit fractional source lookup
    // Separate production check: own CPU native-grid curve pixels then the identical public
    // presentation transform. Nonlinear math and minification are not assumed to commute.
    // This is a predeclared measured canonical-native presentation contract; failure is kept.
    let tables=try E.tables(p)
    let referencePixels=try pixels.map{try E.referencePixel($0,tables:tables)}
    let referenceBytes=referencePixels.withUnsafeBytes{Data($0)}
    let referenceImage=CIImage(bitmapData:referenceBytes,bytesPerRow:32*16,size:.init(width:32,height:24),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    for transform in [CGAffineTransform.identity,
                      CGAffineTransform(translationX:0.125,y:0.125),
                      CGAffineTransform(a:0.5,b:0,c:0,d:0.5,tx:0.125,ty:0.125)] {
      let actual=try read(E.apply(p,to:source).transformed(by:transform),c,rect:sampleRect)
      let expected=try read(referenceImage.transformed(by:transform),c,rect:sampleRect)
      for (a,e) in zip(actual,expected) {
        XCTAssertEqual(a.x,e.x,accuracy:2e-4);XCTAssertEqual(a.y,e.y,accuracy:2e-4);XCTAssertEqual(a.z,e.z,accuracy:2e-4);XCTAssertEqual(a.w,e.w,accuracy:2e-7)
      }
    }
    let hdr=image(.init(2,-0.2,0.5,0.5))
    for algorithm in [DevelopmentCurvesAlgorithmV3.legacyPCHIPV1,.naturalCubicGamma512LumaV1] {
      XCTAssertTrue(try E.apply(.init(enabled:false,rgb:p.rgb,algorithm:algorithm),to:hdr)===hdr)
      XCTAssertTrue(try E.apply(.init(enabled:true,algorithm:algorithm),to:hdr)===hdr)
    }
  }
  func testGPUVersionDispatchPreservesLegacyCombinedAndNewBeforeLevelsOnly()throws {
    let c=context();defer{c.clearCaches()};let source=image(.init(0.2,0.4,0.7,1))
    var p=DevelopmentAdjustmentsV3(curves:curves());p.curves.algorithm = .legacyPCHIPV1
    p.levels.enabled=true;p.levels.rgb = .manual(.init(black:0,shadows:0.2,midtones:0.4,highlights:0.8,white:1,outputBlack:0.05,outputWhite:0.95))
    XCTAssertEqual(try read(DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:source),c),try read(DevelopmentColorEngineV3.applyLegacyCurvesAndLevels(p,to:source),c))
    p.curves.algorithm = .naturalCubicGamma512LumaV1
    let curved=try E.apply(p.curves,to:source);var onlyLevels=p;onlyLevels.curves.enabled=false
    let expected=try DevelopmentColorEngineV3.applyLegacyCurvesAndLevels(onlyLevels,to:curved)
    XCTAssertEqual(try read(DevelopmentColorEngineV3.applyCurvesAndLevels(p,to:source),c),try read(expected,c))
    let bad=try E.apply(p.curves,to:image(.init(.infinity,0.25,0.5,1)))
    XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(bad,context:c))
    let straightOverflow=try E.apply(p.curves,to:image(.init(Float.greatestFiniteMagnitude,1,1,1e-30)))
    XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(straightOverflow,context:c)) // no Inf address clamp rescue
    let hidden=try E.apply(p.curves,to:image(.init(.nan,0.25,0.5,0)))
    XCTAssertThrowsError(try DevelopmentColorEngineV3.validateFinite(hidden,context:c))
  }
}
