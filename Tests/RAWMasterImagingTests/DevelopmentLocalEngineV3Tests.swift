import XCTest
import CoreImage
import Metal
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentLocalEngineV3Tests: XCTestCase {
  private let content = String(repeating:"a",count:64)
  private let width = 64,height = 48
  private var binding: DevelopmentLocalEditSourceBinding { .init(sourceContentID:content,exifOrientation:1,orientedWidth:width,orientedHeight:height) }
  private func pixels() -> [SIMD4<Float>] {
    (0..<(width*height)).map { i in
      let x=i%width,y=i/width,a: Float = x<2 ? 0:(x==2 ? 0.000001:0.35+Float(y%5)/10)
      return .init((0.2+Float(x%7)/12)*a,(0.1+Float(y%9)/15)*a,Float((x+y)%11)/15*a,a)
    }
  }
  private func image(_ p: [SIMD4<Float>]) -> CIImage {
    .init(bitmapData:p.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image: CIImage) throws -> [SIMD4<Float>] {
    var output = [SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(image,rect:image.extent,context:DevelopmentColorEngineV3.context) { output=Array($0) };return output
  }
  private func edits(_ ops: [DevelopmentLocalEdit], enabled: Bool = true) -> DevelopmentLocalEditsV3 {
    .init(sourceBinding:binding,retouchEnabled:enabled,redEyeEnabled:enabled,operations:ops)
  }
  private func op(_ tool: DevelopmentLocalTool = .retouch, point: DevelopmentSourcePoint = .init(x:0.4,y:0.5),donor: DevelopmentSourcePoint? = .init(x:0.7,y:0.5)) -> DevelopmentLocalEdit {
    .init(sourceContentID:content,tool:tool,stroke:.init(points:[.init(position:point)],radiusInShortEdge:0.09,strength:0.8),sourceSample:tool == .retouch ? donor:nil)
  }
  private func reference(_ input: [SIMD4<Float>],operation: DevelopmentLocalEdit) throws -> [SIMD4<Float>] {
    var output=input,dabs=[DevelopmentStrokePoint]()
    try operation.stroke.forEachDab(sourceSize:binding.sourceSize) { dabs.append($0) }
    let radius=operation.stroke.radiusInShortEdge*Double(min(width,height)),first=operation.stroke.points[0].position
    let donor=operation.sourceSample ?? first,dx=(donor.x-first.x)*Double(width),dy=(donor.y-first.y)*Double(height)
    func sample(_ x: Double,_ y: Double) -> SIMD4<Double> {
      let px=min(Double(width-1),max(0,x-0.5)),py=min(Double(height-1),max(0,y-0.5))
      let x0=Int(floor(px)),y0=Int(floor(py)),x1=min(width-1,x0+1),y1=min(height-1,y0+1),fx=px-Double(x0),fy=py-Double(y0)
      func value(_ x: Int,_ y: Int) -> SIMD4<Double> { let p=input[y*width+x];return .init(Double(p.x),Double(p.y),Double(p.z),Double(p.w)) }
      return (value(x0,y0)*(1-fx)+value(x1,y0)*fx)*(1-fy)+(value(x0,y1)*(1-fx)+value(x1,y1)*fx)*fy
    }
    func low(_ x: Double,_ y: Double) -> SIMD4<Double> {
      let weights=[1.0,4,6,4,1];var value=SIMD4<Double>.zero
      for j in 0..<5 { for i in 0..<5 { value += sample(x+Double(i-2)*radius/4,y+Double(j-2)*radius/4)*(weights[i]*weights[j]/256) } };return value
    }
    func smooth(_ a: Double,_ b: Double,_ x: Double) -> Double { let t=min(1,max(0,(x-a)/(b-a)));return t*t*(3-2*t) }
    for y in 0..<height { for x in 0..<width {
      let original=input[y*width+x];if original.w < DevelopmentLocalEngineV3.alphaMinimum { continue }
      let px=Double(x)+0.5,py=Double(y)+0.5;var remaining=1.0
      for dab in dabs { let distance=hypot(px-dab.position.x*Double(width),py-dab.position.y*Double(height));remaining *= 1-(1-smooth(0.7,1,distance/radius))*operation.stroke.strength*dab.pressure }
      let coverage=1-remaining;if coverage==0 { continue }
      let a=Double(original.w),u=SIMD3(Double(original.x),Double(original.y),Double(original.z))/a
      if operation.tool == .retouch {
        let d=sample(px+dx,py+dy),lt=low(px,py),ld=low(px+dx,py+dy)
        if d.w<Double(DevelopmentLocalEngineV3.alphaMinimum) || lt.w<Double(DevelopmentLocalEngineV3.alphaMinimum) || ld.w<Double(DevelopmentLocalEngineV3.alphaMinimum) { continue }
        let heal=SIMD3(d.x,d.y,d.z)/d.w-SIMD3(ld.x,ld.y,ld.z)/ld.w+SIMD3(lt.x,lt.y,lt.z)/lt.w
        let c=(u*(1-coverage)+heal*coverage)*a
        output[y*width+x] = .init(Float(c.x),Float(c.y),Float(c.z),original.w)
      } else {
        let c=SIMD3(DevelopmentColorEngineV2.encode(min(1,max(0,u.x))),DevelopmentColorEngineV2.encode(min(1,max(0,u.y))),DevelopmentColorEngineV2.encode(min(1,max(0,u.z))))
        if (min(c.x,c.y,c.z)>0.6 && max(c.x,c.y,c.z)>0.9) || (c.z>0.8 && c.x-c.z<=0.15) { continue }
        let weight=coverage*smooth(0.15,0.3,c.x-max(c.y,c.z))*smooth(0.25,0.45,c.x)*smooth(1.5,2,c.x/(c.y+c.z+0.01))
        let red=DevelopmentColorEngineV2.decode(min(c.x,(c.y+c.z)/2))*a
        output[y*width+x].x=Float(Double(original.x)*(1-weight)+red*weight)
      }
    } };return output
  }
  func testProductionFourNearestFloatBilinearAtFrozenFractionsAndClampedEdges() throws {
    let source=pixels()
    let shader=DevelopmentLocalEngineV3.metalSource + #"""
    extern "C" { namespace coreimage {
    [[stitchable]] float4 rmLocalBilinearProbe(sampler src,float4 at,destination dest) {
      return rmLocalBilinear(src,at.xy,at.zw);
    }
    } }
    """#
    let probe=try XCTUnwrap(CIKernel.kernels(withMetalString:shader).first(where:{$0.name=="rmLocalBilinearProbe"}))
    let context=DevelopmentColorEngineV3.context
    // The first four are the predeclared actual diagnostic points. Two additional points pin
    // the existing source-edge extension used by lowpass taps, not invalid donor admission.
    let points:[SIMD2<Float>]=[.init(25.5,24.5),.init(26.58,26.66),.init(44.7,24.5),.init(45.78,23.42),.init(-0.2,50.9),.init(64.7,-1.3)]
    for point in points {
      let at=CIVector(x:CGFloat(point.x),y:CGFloat(point.y),z:CGFloat(width),w:CGFloat(height))
      let extent=CGRect(x:0,y:0,width:1,height:1)
      let graph=try XCTUnwrap(probe.apply(extent:extent,roiCallback:{ _,_ in .init(x:0,y:0,width:self.width,height:self.height) },
        arguments:[image(source).clampedToExtent().samplingNearest(),at]))
      var actual=SIMD4<Float>.zero
      try DevelopmentLocalEngineV3.read(graph,rect:extent,context:context) { actual=$0[0] }
      let x=min(Double(width-1),max(0,Double(point.x)-0.5))
      let y=min(Double(height-1),max(0,Double(height)-Double(point.y)-0.5))
      let x0=Int(floor(x)),y0=Int(floor(y)),x1=min(width-1,x0+1),y1=min(height-1,y0+1)
      let fx=x-Double(x0),fy=y-Double(y0)
      func value(_ x:Int,_ y:Int)->SIMD4<Double> {
        let p=source[y*width+x];return .init(Double(p.x),Double(p.y),Double(p.z),Double(p.w))
      }
      let lower=value(x0,y0)*(1-fx)+value(x1,y0)*fx
      let upper=value(x0,y1)*(1-fx)+value(x1,y1)*fx
      let expected=lower*(1-fy)+upper*fy
      for c in 0..<4 { XCTAssertEqual(Double(actual[c]),expected[c],accuracy:2e-7,"world \(point), channel \(c)") }
    }
    XCTAssertTrue(DevelopmentLocalEngineV3.operatorVersion.contains("manual4nearest-f32"))
    XCTAssertTrue(DevelopmentLocalEngineV3.operatorVersion.contains("work-retouch212-redEye2"))
  }
  func testRetouchActualMetalMatchesDoubleReferenceAndPreservesAlphaOutsideMask() throws {
    let source=pixels(),operation=op(),expected=try reference(source,operation:operation)
    let actual=try read(DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context))
    var changed=0
    for i in actual.indices {
      XCTAssertEqual(actual[i].w.bitPattern,source[i].w.bitPattern)
      for c in 0..<3 { XCTAssertEqual(actual[i][c],expected[i][c],accuracy:2e-4) }
      if expected[i] == source[i] { XCTAssertEqual(actual[i],source[i]) }
      if actual[i] != source[i] { changed += 1 }
    };XCTAssertGreaterThan(changed,0)
  }
  func testMultiDabTailPressureAndFrozenOverlappingDonor() throws {
    let source=pixels();var operation=op(donor:.init(x:0.47,y:0.5))
    operation.stroke.points += [.init(position:.init(x:0.5,y:0.52),pressure:0.25),.init(position:.init(x:0.56,y:0.51),pressure:1)]
    let expected=try reference(source,operation:operation),actual=try read(DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context))
    for i in actual.indices { for c in 0..<4 { XCTAssertEqual(actual[i][c],expected[i][c],accuracy:2e-4) } }
  }
  func testOrderedOperationsReadPriorPrefixAndDoNotCommute() throws {
    let source=pixels(),a=op(),b=op(point:.init(x:0.7,y:0.5),donor:.init(x:0.4,y:0.5))
    let ab=try read(DevelopmentLocalEngineV3.apply(edits([a,b]),to:image(source),context:DevelopmentColorEngineV3.context))
    let ba=try read(DevelopmentLocalEngineV3.apply(edits([b,a]),to:image(source),context:DevelopmentColorEngineV3.context))
    XCTAssertNotEqual(ab,ba)
  }
  func testDisabledUnresolvedZeroStrengthAndZeroPressureAreExactBypasses() throws {
    let source=pixels();var operation=op();operation.sourceSample=nil
    XCTAssertEqual(try read(DevelopmentLocalEngineV3.apply(edits([operation],enabled:false),to:image(source),context:DevelopmentColorEngineV3.context)),source)
    XCTAssertThrowsError(try DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context))
    operation=op();operation.stroke.strength=0
    XCTAssertEqual(try read(DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context)),source)
    operation.stroke.strength=1;operation.stroke.points[0].pressure=0
    XCTAssertEqual(try read(DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context)),source)
  }
  func testRedEyeCorrectsRedAndProtectsCatchlightBlueSkinAndAlpha() throws {
    var source=[SIMD4<Float>](repeating:.init(0.7,0.02,0.015,1),count:width*height)
    let positions=[(31,23),(32,23),(31,24),(32,24)],protected:[SIMD4<Float>]=[.init(1,1,1,1),.init(0.8,0.9,1,1),.init(0.45,0.28,0.2,1),.init(0,0,0,0)]
    for (i,p) in positions.enumerated() { source[p.1*width+p.0]=protected[i] }
    let operation=op(.redEye,point:.init(x:0.5,y:0.5)),expected=try reference(source,operation:operation)
    let actual=try read(DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context))
    for i in actual.indices { for c in 0..<4 { XCTAssertEqual(actual[i][c],expected[i][c],accuracy:2e-4) };XCTAssertEqual(actual[i].w,source[i].w) }
    for (i,p) in positions.enumerated() { XCTAssertEqual(actual[p.1*width+p.0],protected[i]) }
    XCTAssertLessThan(actual[24*width+29].x,source[24*width+29].x)
  }
  func testLowAlphaLowpassDenominatorBypassesAndInvalidAlphaNaNReject() throws {
    let a:Float=0.000001,source=[SIMD4<Float>](repeating:.init(a,a,a,a),count:width*height)
    XCTAssertEqual(try read(DevelopmentLocalEngineV3.apply(edits([op()]),to:image(source),context:DevelopmentColorEngineV3.context)),source)
    for bad in [SIMD4<Float>(0,0,0,-0.1),.init(0,0,0,1.1),.init(Float.nan,0,0,0)] {
      var values=pixels();values[0]=bad
      XCTAssertThrowsError(try DevelopmentLocalEngineV3.apply(edits([op()]),to:image(values),context:DevelopmentColorEngineV3.context))
    }
  }
  func testVisibleDonorWithSubthresholdLowpassDenominatorRemainsBitwiseOriginal() throws {
    var source=[SIMD4<Float>](repeating:.zero,count:width*height)
    for y in 16..<32 { for x in 16..<32 { source[y*width+x] = .init(0.3,0.2,0.1,1) } }
    let a=DevelopmentLocalEngineV3.alphaMinimum
    source[24*width+48] = .init(0.8*a,0.1*a,0.2*a,a)
    let operation=op(point:.init(x:24.5/64,y:24.5/48),donor:.init(x:48.5/64,y:24.5/48))
    // Donor center passes >=alphaMinimum; its25-tap alpha denominator is only36/256 of that.
    let actual=try read(DevelopmentLocalEngineV3.apply(edits([operation]),to:image(source),context:DevelopmentColorEngineV3.context))
    XCTAssertEqual(actual,source)
  }
  func testResourceUnionCannotReuseRetainedChargesAndAdmissionFailureDoesNotDebit() throws {
    let baseline=DevelopmentLocalChargeV3.snapshot()
    var owner:DevelopmentLocalChargeV3?=try .init(1024,kind:.metadata),view=owner
    owner=nil;XCTAssertEqual(DevelopmentLocalChargeV3.snapshot().metadata,baseline.metadata+1024)
    XCTAssertThrowsError(try DevelopmentLocalChargeV3(DevelopmentLocalWorkEstimatorV1.metadataUnionBytes,kind:.metadata))
    XCTAssertEqual(DevelopmentLocalChargeV3.snapshot().metadata,baseline.metadata+1024)
    withExtendedLifetime(view) {};view=nil
    XCTAssertEqual(DevelopmentLocalChargeV3.snapshot().metadata,baseline.metadata)
  }
  func testRetouchWholeVersusTiledRGBAWithNonintegerRadiusAndGlobalCoordinates() throws {
    var operation=op();operation.stroke.radiusInShortEdge=0.087
    let output=try DevelopmentLocalEngineV3.apply(edits([operation]),to:image(pixels()),context:DevelopmentColorEngineV3.context),whole=try read(output)
    for y in stride(from:0,to:height,by:7) { for x in stride(from:0,to:width,by:9) {
      let w=min(9,width-x),h=min(7,height-y)
      try DevelopmentLocalEngineV3.read(output,rect:.init(x:x,y:height-y-h,width:w,height:h),context:DevelopmentColorEngineV3.context) { p in
        for row in 0..<h { for col in 0..<w { for c in 0..<4 { XCTAssertEqual(p[row*w+col][c],whole[(y+row)*width+x+col][c],accuracy:2e-7) } } }
      }
    } }
  }
  func testCompleteStrokeOverlapRejectsLongTailAndAllowsSeparatedDonor() throws {
    let stroke=DevelopmentStroke(points:[.init(position:.init(x:0.1,y:0.2)),.init(position:.init(x:0.8,y:0.7)),.init(position:.init(x:0.2,y:0.7))],radiusInShortEdge:0.02)
    XCTAssertTrue(try DevelopmentLocalAnalysisV3.supportOverlaps(stroke:stroke,size:binding.sourceSize,offset:.init(0,1),radius:1))
    XCTAssertFalse(try DevelopmentLocalAnalysisV3.supportOverlaps(stroke:stroke,size:binding.sourceSize,offset:.init(200,0),radius:1))
  }
  func testMetadataTextureMultirowLayoutAndLastNativeViewKeepsCharge() throws {
    let baseline=DevelopmentLocalChargeV3.snapshot().metadata
    var alias:MTLBuffer?
    try autoreleasepool {
      let table=try DevelopmentLocalTableV3(texels:5000) { p in
        for i in 0..<5000 { p[i] = .init(Float(i),Float(i)/2,-Float(i),1) }
      }
      for index in [0,3,4095,4096,4999] {
        var value=SIMD4<Float>.zero
        let x=index%table.width,y=index/table.width
        try DevelopmentLocalEngineV3.read(table.image,rect:.init(x:x,y:y,width:1,height:1),context:DevelopmentColorEngineV3.context) { value=$0[0] }
        XCTAssertEqual(value,.init(Float(index),Float(index)/2,-Float(index),1))
      }
      // Pin the actual production metadata lookup as well as the native MTL row convention.
      let probeSource=DevelopmentLocalEngineV3.metalSource + #"""
      extern "C" { namespace coreimage {
      [[stitchable]] float4 rmLocalPackedTableProbe(sampler table,float4 info,destination dest) {
        return rmLocalTable(table,int(info.x),info.y,info.z);
      }
      } }
      """#
      let probe=try XCTUnwrap(CIKernel.kernels(withMetalString:probeSource).first(where:{$0.name == "rmLocalPackedTableProbe"}))
      for index in [0,3,4095,4096,4999] {
        let output=try XCTUnwrap(probe.apply(extent:.init(x:0,y:0,width:1,height:1),roiCallback:{ _,_ in table.image.extent },
          arguments:[table.image.samplingNearest(),CIVector(x:Double(index),y:Double(table.width),z:Double(table.height),w:0)]))
        let value=try read(output)[0]
        XCTAssertEqual(value,.init(Float(index),Float(index)/2,-Float(index),1))
      }
      alias=table.buffer
    }
    XCTAssertGreaterThan(DevelopmentLocalChargeV3.snapshot().metadata,baseline)
    withExtendedLifetime(alias) {};alias=nil
    DevelopmentColorEngineV3.context.clearCaches()
    // No command or texture read remains in flight: all checked read tasks joined above.
    XCTAssertEqual(DevelopmentLocalChargeV3.snapshot().metadata,baseline)
  }

}
