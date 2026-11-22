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
  XCTAssertEqual(DevelopmentColorEngineV3.sourceSHA256,DevelopmentGrainSamplingEngineV1.originalPointSHA)
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
 func testEffectsGrainInColourChangesAmountSizeRoughnessAndMatchesNativeGridAtFit() throws {
  let c = context(), bounds = CGRect(x: 0, y: 0, width: 16, height: 12)
  let source = CIImage(color: CIColor(red: 0.6, green: 0.35, blue: 0.15, alpha: 0.75,
    colorSpace: DevelopmentColorEngineV3.linearSRGB)!).cropped(to: bounds)
  var p = DevelopmentAdjustmentsV3()
  let original = try pixels(source,bounds,c)
  var outputs = [[SIMD4<Float>]]()
  for (size, roughness) in [(0.25,0.25),(0.70,0.25),(0.25,0.80)] {
   p.effects = .init(enabled: true, grain: 0.8, grainSize: size, grainRoughness: roughness)
   let native = try DevelopmentColorEngineV3.applyPointwise(p,to:source,context:c)
   let nativePixels = try pixels(native,bounds,c)
   XCTAssertEqual(nativePixels.map(\.w),original.map(\.w))
   XCTAssertGreaterThan(nativePixels[0].x,nativePixels[0].y)
   XCTAssertNotEqual(nativePixels,original)
   outputs.append(nativePixels)
   let fitBounds = CGRect(x: 0,y: 0,width: 8,height: 6)
   let fitSource = source.transformed(by:.init(scaleX:0.5,y:0.5))
   let proxy = try PreviewInteractiveProxyV3.suffix(p,source:fitSource,sourceIsRAW:true,nativeSize:bounds.size,
     scale:0.5,context:c,check:{})
   let fit = try pixels(proxy,fitBounds,c)
   let reference = try pixels(native.samplingLinear().transformed(by:.init(scaleX:0.5,y:0.5)),fitBounds,c)
   for (a,b) in zip(fit,reference) {
    XCTAssertEqual(a.w,b.w,accuracy:0.0001)
    XCTAssertEqual(a.x,b.x,accuracy:0.001)
    XCTAssertEqual(a.y,b.y,accuracy:0.001)
    XCTAssertEqual(a.z,b.z,accuracy:0.001)
   }
  }
  XCTAssertNotEqual(outputs[0],outputs[1])
  XCTAssertNotEqual(outputs[0],outputs[2])
 }
 func testSizedRoughnessGPUGrainMatchesCPUReferenceAndLegacyPath()throws{
  let c=context();defer{c.clearCaches()}
  let extent=CGRect(x:0,y:0,width:31,height:17)
  let effects=DevelopmentEffectsV3(enabled:true,grain:0.4,grainSize:0.6,grainRoughness:0.3)
  let actual=try pixels(DevelopmentGrainSamplingEngineV1.image(extent,effects:effects),extent,c)
  for y in 0..<Int(extent.height){for x in 0..<Int(extent.width){
   let expected=DevelopmentGrainSamplingEngineV1.cpuSized(x,y,size:0.6,roughness:0.3)
   XCTAssertEqual(actual[y*Int(extent.width)+x].x,expected,accuracy:1e-7)
  }}
  let legacy=try pixels(DevelopmentGrainSamplingEngineV1.image(extent),extent,c)
  for y in 0..<Int(extent.height){for x in 0..<Int(extent.width){
   XCTAssertEqual(legacy[y*Int(extent.width)+x].x.bitPattern,DevelopmentGrainSamplingEngineV1.cpu(x,y).bitPattern)
  }}
  let other=try pixels(DevelopmentGrainSamplingEngineV1.image(extent,effects:.init(enabled:true,grain:0.4,grainSize:0.1,grainRoughness:0.9)),extent,c)
  XCTAssertNotEqual(actual.map(\.x),other.map(\.x))
 }
}
