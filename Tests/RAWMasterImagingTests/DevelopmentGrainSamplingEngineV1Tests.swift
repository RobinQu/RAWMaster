import XCTest
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentGrainSamplingEngineV1Tests:XCTestCase {
 private func context()->CIContext{.init(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])}
 private func pixels(_ image:CIImage,_ r:CGRect,_ c:CIContext)throws->[SIMD4<Float>]{
  let w=Int(r.width),h=Int(r.height)
  var a=[SIMD4<Float>](repeating:SIMD4<Float>(repeating:.nan),count:w*h)
  try a.withUnsafeMutableBytes{b in
   let d=CIRenderDestination(bitmapData:b.baseAddress!,width:w,height:h,bytesPerRow:w*16,format:.RGBAf)
   d.colorSpace=DevelopmentColorEngineV3.linearSRGB;d.alphaMode = .premultiplied;d.isFlipped=false;d.isClamped=false;d.isDithered=false
   let task=try c.startTask(toRender:image,from:r,to:d,at:.zero)
   do{_ = try task.waitUntilCompleted()}catch{let first=error;_ = try? task.waitUntilCompleted();throw first}
  }
  XCTAssertTrue(a.allSatisfy{$0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite});return a
 }
 func testOriginalSourceIdentityAndExactlyReversibleMutation(){
  XCTAssertEqual(DevelopmentColorEngineV3.sourceSHA256,"775c7009e4a86947f23d2f4b207c261ee578a416585e85133c874d4b261386db")
  let reversed=DevelopmentGrainSamplingEngineV1.pointSource.replacingOccurrences(of:"rawmasterPointNativeGrainV1(sampler src,sampler grain,",with:"rawmasterPointV3(sampler src,").replacingOccurrences(of:"grain.sample(grain.coord()).r",with:"v3noise(src.coord())")
  XCTAssertEqual(reversed,DevelopmentColorEngineV3.metalSource)
 }
 func testGridAdmissionAndNonRAWFailClosed()throws{
  XCTAssertFalse(DevelopmentGrainSamplingEngineV1.validNativeExtent(.init(x:1,y:0,width:64,height:48)))
  XCTAssertFalse(DevelopmentGrainSamplingEngineV1.validNativeExtent(.init(x:0,y:0,width:64.5,height:48)))
  XCTAssertFalse(DevelopmentGrainSamplingEngineV1.validNativeExtent(.init(x:0,y:0,width:50001,height:48)))
  XCTAssertEqual(DevelopmentGrainSamplingEngineV1.admit(sourceIsRAW:false,extent:.init(x:0,y:0,width:64,height:48)),[])
  var r=try DevelopmentRecipe().promotingToV3();r.adjustmentsV3!.blackAndWhite = .init(enabled:true,grain:0.3,grainSamplingVersion:.sourceNativeLatticeV1)
  XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(r,sourceIsRAW:false))
  XCTAssertNoThrow(try DevelopmentRendererV3.validateSupport(r,sourceIsRAW:true))
 }
 func testActualRfNegativeGlobalHashWholeTileAndPadding()throws{
  let c=context();defer{c.clearCaches()}
  let active=CGRect(x:-11,y:7,width:63,height:47),extent=active.insetBy(dx:-1,dy:-1)
  let image=try DevelopmentGrainSamplingEngineV1.image(extent,activeBounds:active)
  let all=try pixels(image,extent,c),w=Int(extent.width),h=Int(extent.height)
  for y in 0..<h{for x in 0..<w{
   let gx=Int(extent.minX)+x,gy=Int(extent.minY)+y
   let inBounds=active.contains(CGPoint(x:CGFloat(gx)+0.5,y:CGFloat(gy)+0.5))
   let expected:Float=inBounds ? DevelopmentGrainSamplingEngineV1.cpu(gx,gy):0
   XCTAssertEqual(all[y*w+x].x.bitPattern,expected.bitPattern)
  }}
  for y in stride(from:0,to:h,by:19){for x in stride(from:0,to:w,by:17){
   let tw=min(17,w-x),th=min(19,h-y)
   let tile=try pixels(image,.init(x:Int(extent.minX)+x,y:Int(extent.minY)+y,width:tw,height:th),c)
   for yy in 0..<th{for xx in 0..<tw{XCTAssertEqual(tile[yy*tw+xx].x.bitPattern,all[(y+yy)*w+x+xx].x.bitPattern)}}
  }}
 }
 func testNewMarkerIsNotCertificateAdmissionEvenDisabled()throws{
  var r=try DevelopmentRecipe().promotingToV3();r.adjustmentsV3!.blackAndWhite = .init(enabled:false,grain:0.3,grainSamplingVersion:.sourceNativeLatticeV1)
  XCTAssertEqual(try PreviewNativePointwiseV1.routeEligibility(r,size:.init(width:64,height:48)),.grainCanonical)
  XCTAssertFalse(r.adjustmentsV3!.blackAndWhite.requiresLegacyGrainCanonicalInput)
  r.adjustmentsV3!.blackAndWhite.grainSamplingVersion=nil
  XCTAssertTrue(r.adjustmentsV3!.blackAndWhite.requiresLegacyGrainCanonicalInput)
 }
 func testFullPointHookPreservesGrain0LegacyAndAlphaHDR()throws{
  let c=context();defer{c.clearCaches()}
  let rect=CGRect(x:0,y:0,width:8,height:6)
  var source=[SIMD4<Float>]()
  for y in 0..<6{for x in 0..<8{let a:Float=[0,0.25,0.7,1][x%4];source.append(.init((Float(x)/3-0.2)*a,Float(y)/3*a,0.4*a,a))}}
  let bytes=source.withUnsafeBytes{Data($0)}
  let image=CIImage(bitmapData:bytes,bytesPerRow:8*16,size:rect.size,format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  var p=DevelopmentAdjustmentsV3();p.blackAndWhite = .init(enabled:true,grain:0.3,grainSamplingVersion:.sourceNativeLatticeV1)
  let active=try DevelopmentColorEngineV3.applyPointwise(p,to:image,context:c)
  let actual=try pixels(active,rect,c)
  for i in actual.indices{XCTAssertEqual(actual[i].w.bitPattern,source[i].w.bitPattern);if source[i].w==0{XCTAssertEqual(actual[i],.zero)}}
  XCTAssertThrowsError(try DevelopmentColorEngineV3.applyPointwise(p,to:image))
  p.blackAndWhite.grainSamplingVersion=nil;p.blackAndWhite.grain=0
  let old=try pixels(DevelopmentColorEngineV3.applyPointwise(p,to:image),rect,c)
  let same=try pixels(DevelopmentColorEngineV3.applyPointwise(p,to:image,context:c),rect,c)
  XCTAssertEqual(old,same)
 }
}
