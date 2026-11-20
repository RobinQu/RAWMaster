import XCTest
import CoreImage
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentAdvancedDetailEngineV3Tests: XCTestCase {
  private let context=DevelopmentColorEngineV3.context
  private func image(_ p:[SIMD4<Float>],width:Int,height:Int) -> CIImage {
    .init(bitmapData:p.withUnsafeBytes { Data($0) },bytesPerRow:width*16,size:.init(width:width,height:height),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }
  private func read(_ image:CIImage) throws -> [SIMD4<Float>] {
    var output=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(image,rect:image.extent,context:context) { output=Array($0) };return output
  }
  private func chart(width:Int=192,height:Int=128,wavelength:Double=13) -> CIImage {
    var p=[SIMD4<Float>]()
    for y in 0..<height { for x in 0..<width {
      let a:Float=x<2 ? 0:(x<4 ? 0.000001:0.4+Float(y%5)/10)
      let wave=Float(sin(2*Double.pi*Double(x)/wavelength)),step:Float=x<width/2 ? 0.12:0.36
      let r=(step+0.025*wave)*a,g=(step*0.8+0.01*wave)*a,b=(step*0.6-0.015*wave)*a
      p.append(.init(r,g,b,a))
    } };return image(p,width:width,height:height)
  }
  private func parameters(texture:Double=0,clarity:Double=0) -> DevelopmentAdvancedDetailV3 {
    .init(texture:.init(enabled:true,amount:texture),clarity:.init(enabled:true,amount:clarity))
  }
  func testOffAndZeroReturnIdenticalCIImageAndDehazeIsExplicitlyUnsupported() throws {
    let input=chart(),size=DevelopmentPixelSize(width:192,height:128)
    for p in [DevelopmentAdvancedDetailV3(),parameters(),.init(texture:.init(enabled:false,amount:100),clarity:.init(enabled:false,amount:-100))] {
      XCTAssertTrue(try DevelopmentAdvancedDetailEngineV3.apply(p,to:input,sourceSize:size,context:context) === input)
    }
    var p=parameters();p.dehaze = .init(enabled:true,amount:1)
    XCTAssertThrowsError(try DevelopmentAdvancedDetailEngineV3.apply(p,to:input,sourceSize:size,context:context))
    p=parameters(texture:101);XCTAssertThrowsError(try DevelopmentAdvancedDetailEngineV3.apply(p,to:input,sourceSize:size,context:context))
  }
  func testGuideRGBSlotsAlphaWeightAndLinearLogMatchCPUIncludingLowAlphaHDR() throws {
    let width=9,height=2,sub=Float.leastNonzeroMagnitude*16
    let row:[SIMD4<Float>]=[.init(0.18,0.18,0.18,1),.init(0.09,0.09,0.09,0.5),.init(2,1,-0.1,1),
      .init(0.001,0.002,0.003,0.000001),.init(0.4,0.1,0.2,0),.init(-0.2,-0.3,-0.1,0.5),.init(0,0,0,1),.init(1e-30,2e-30,3e-30,1e-30),.init(sub,sub*2,sub*3,sub)]
    let input=image(row+row,width:width,height:height)
    let actual=try read(DevelopmentAdvancedDetailEngineV3.makeGuide(input))
    for i in actual.indices {
      let p=row[i%row.count],expected=try DevelopmentAdvancedDetailEngineV3.referenceGuide(.init(Double(p.x),Double(p.y),Double(p.z),Double(p.w)))
      XCTAssertTrue([actual[i].x,actual[i].y,actual[i].z,actual[i].w].allSatisfy(\.isFinite))
      XCTAssertEqual(Double(actual[i].x),expected.x,accuracy:2e-5)
      XCTAssertEqual(actual[i].y,p.w);XCTAssertEqual(actual[i].z,0);XCTAssertEqual(actual[i].w,1)
    }
    // The immutable literal is the alpha authority: an unrelated RGBA destination read may
    // flush a subnormal alpha while the guide correctly preserves those bits in its green slot.
    // This distinguishes log*A/A from a guide whose alpha isA and gets premultiplied again.
    XCTAssertEqual(actual[1].x,actual[0].x/2,accuracy:2e-6)
    XCTAssertLessThan(actual[0].x,0)
  }
  func testBothBandsPositiveAndNegativeMatchCPUWithActualPublicGaussianGuides() throws {
    let input=chart(),source=try read(input),r=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:.init(width:192,height:128))
    for band in [DevelopmentAdvancedDetailEngineV3.Band.texture,.clarity] { for amount in [-75.0,75] {
      let radius=band == .texture ? r.texture:r.clarity,g=try DevelopmentAdvancedDetailEngineV3.guides(input,radius:radius)
      let fine=try read(g.fine),wide=try read(g.wide)
      let actual=try read(DevelopmentAdvancedDetailEngineV3.applyBand(band,amount:amount,to:input,radius:radius))
      var maximum=0.0,changed=0
      for i in actual.indices {
        func d(_ p:SIMD4<Float>) -> SIMD4<Double> { .init(Double(p.x),Double(p.y),Double(p.z),Double(p.w)) }
        let expected=try DevelopmentAdvancedDetailEngineV3.referencePixel(d(source[i]),fine:d(fine[i]),wide:d(wide[i]),band:band,amount:amount)
        for c in 0..<3 { maximum=max(maximum,abs(Double(actual[i][c])-expected[c])) }
        XCTAssertEqual(actual[i].w.bitPattern,source[i].w.bitPattern)
        if source[i].w<1.0/65535 { XCTAssertEqual(actual[i],source[i]) }
        if abs(actual[i].x-source[i].x)>1e-5 { changed += 1 }
      }
      XCTAssertLessThanOrEqual(maximum,2e-4);XCTAssertGreaterThan(changed,0)
    } }
  }
  private func frequencyResponse(_ wavelength:Double,band:DevelopmentAdvancedDetailEngineV3.Band) throws -> Double {
    let width=256,height=128
    var p=[SIMD4<Float>]()
    for _ in 0..<height { for x in 0..<width {
      let y=Float(exp2(log2(0.18)+0.15*sin(2*Double.pi*Double(x)/wavelength)))
      p.append(.init(y,y,y,1))
    } }
    let input=image(p,width:width,height:height),radius=band == .texture ? 0.5:2.0
    let actual=try read(DevelopmentAdvancedDetailEngineV3.applyBand(band,amount:100,to:input,radius:radius))
    var response=0.0,count=0
    for x in 32..<(width-32) {
      let i=(height/2)*width+x,ev=log2(Double(actual[i].x/p[i].x))
      response += ev*sin(2*Double.pi*Double(x)/wavelength);count += 1
    };return abs(response/Double(count))
  }
  func testFineAndBroadFrequencyBandsHaveDistinctTransferAndSignedDirection() throws {
    let tf=try frequencyResponse(4,band:.texture),cf=try frequencyResponse(4,band:.clarity)
    let tc=try frequencyResponse(32,band:.texture),cc=try frequencyResponse(32,band:.clarity)
    XCTAssertGreaterThan(tf,4*cf);XCTAssertGreaterThan(cc,2*tc)
    let p=SIMD4<Double>(0.2,0.15,0.1,0.5),fine=SIMD4<Double>(-0.5,0.5,0,1),wide=SIMD4<Double>(-0.75,0.5,0,1)
    for band in [DevelopmentAdvancedDetailEngineV3.Band.texture,.clarity] {
      let positive=try DevelopmentAdvancedDetailEngineV3.referencePixel(p,fine:fine,wide:wide,band:band,amount:50)
      let negative=try DevelopmentAdvancedDetailEngineV3.referencePixel(p,fine:fine,wide:wide,band:band,amount:-50)
      XCTAssertGreaterThan(positive.x,p.x);XCTAssertLessThan(negative.x,p.x)
    }
  }
  func testTextureThenClarityUsesItsOwnPrecedingImageAndOrderMatters() throws {
    let input=chart(),r=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:.init(width:192,height:128))
    let combined=try DevelopmentAdvancedDetailEngineV3.apply(parameters(texture:80,clarity:-70),to:input,sourceSize:.init(width:192,height:128),context:context)
    let texture=try DevelopmentAdvancedDetailEngineV3.applyBand(.texture,amount:80,to:input,radius:r.texture)
    let expected=try DevelopmentAdvancedDetailEngineV3.applyBand(.clarity,amount:-70,to:texture,radius:r.clarity)
    XCTAssertEqual(try read(combined),try read(expected))
    let clarity=try DevelopmentAdvancedDetailEngineV3.applyBand(.clarity,amount:-70,to:input,radius:r.clarity)
    let reverse=try DevelopmentAdvancedDetailEngineV3.applyBand(.texture,amount:80,to:clarity,radius:r.texture)
    let a=try read(combined),b=try read(reverse)
    let difference=zip(a,b).map { pair -> Float in
      let d=pair.0-pair.1;return abs(d.x)+abs(d.y)+abs(d.z)
    }.max() ?? 0
    XCTAssertGreaterThan(difference,1e-6)
  }
  func testNativeSizeRadiusAuthorityRejectsFITInputAndPreservesTranslatedCoordinates() throws {
    let native=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:.init(width:9504,height:6336))
    XCTAssertEqual(native.texture,1.9008,accuracy:1e-12);XCTAssertEqual(native.clarity,25.344,accuracy:1e-12)
    let fit=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:.init(width:2400,height:1600))
    XCTAssertNotEqual(native,fit)
    let input=chart(),p=parameters(texture:40,clarity:30)
    XCTAssertThrowsError(try DevelopmentAdvancedDetailEngineV3.apply(p,to:input,sourceSize:.init(width:9504,height:6336),context:context))
    let a=try DevelopmentAdvancedDetailEngineV3.apply(p,to:input,sourceSize:.init(width:192,height:128),context:context)
    let b=try DevelopmentAdvancedDetailEngineV3.apply(p,to:input.transformed(by:.init(translationX:17,y:-9)),sourceSize:.init(width:192,height:128),context:context)
    let av=try read(a),bv=try read(b)
    for i in av.indices { for c in 0..<4 { XCTAssertEqual(av[i][c],bv[i][c],accuracy:2e-6) } }
  }
  func testWholeVersusTilesAndEXIFSixEightDirectionsKeepSameNativeEffect() throws {
    let input=chart(width:128,height:96),p=parameters(texture:65,clarity:55)
    let output=try DevelopmentAdvancedDetailEngineV3.apply(p,to:input,sourceSize:.init(width:128,height:96),context:context),whole=try read(output)
    for y in stride(from:0,to:96,by:17) { for x in stride(from:0,to:128,by:19) {
      let w=min(19,128-x),h=min(17,96-y)
      try DevelopmentLocalEngineV3.read(output,rect:.init(x:x,y:96-y-h,width:w,height:h),context:context) { pixels in
        for row in 0..<h { for col in 0..<w { for c in 0..<4 { XCTAssertEqual(pixels[row*w+col][c],whole[(y+row)*128+x+col][c],accuracy:2e-6) } } }
      }
    } }
    for orientation in [CGImagePropertyOrientation.right,.left] {
      let rotated=input.oriented(orientation),expected=output.oriented(orientation)
      let actual=try DevelopmentAdvancedDetailEngineV3.apply(p,to:rotated,sourceSize:.init(width:96,height:128),context:context)
      let av=try read(actual),ev=try read(expected)
      for i in av.indices { for c in 0..<4 { XCTAssertEqual(av[i][c],ev[i][c],accuracy:2e-4) } }
    }
  }
  func testFiniteHDRNegativeLuminanceAndTinyAlphaRemainFiniteWithoutGlobalClamp() throws {
    var p=[SIMD4<Float>]()
    for y in 0..<64 { for x in 0..<96 {
      if x<3 { p.append(.init(0.0001,0.0002,0.0003,0.00000001)) }
      else if x<6 { p.append(.init(-0.2,-0.3,-0.1,1)) }
      else { p.append(.init(Float(x%9)/4+1.2,Float(y%7)/8+0.5,-0.05,1)) }
    } }
    let input=image(p,width:96,height:64),source=try read(input)
    let actual=try read(DevelopmentAdvancedDetailEngineV3.apply(parameters(texture:100,clarity:-100),to:input,sourceSize:.init(width:96,height:64),context:context))
    XCTAssertTrue(actual.contains(where:{$0.x>1}));XCTAssertTrue(actual.contains(where:{$0.z<0}))
    for i in actual.indices {
      XCTAssertTrue([actual[i].x,actual[i].y,actual[i].z,actual[i].w].allSatisfy(\.isFinite))
      XCTAssertEqual(actual[i].w.bitPattern,source[i].w.bitPattern)
      if i%96<6 { XCTAssertEqual(actual[i],source[i]) }
    }
    p[0] = .init(Float.nan,0,0,0)
    XCTAssertThrowsError(try DevelopmentAdvancedDetailEngineV3.apply(parameters(texture:50),to:image(p,width:96,height:64),sourceSize:.init(width:96,height:64),context:context))
    XCTAssertThrowsError(try DevelopmentAdvancedDetailEngineV3.referenceGuide(.init(Double.infinity,0,0,0)))
  }
}
