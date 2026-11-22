import CoreImage
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentHueIsolationV3Tests:XCTestCase {
  private let context=DevelopmentColorEngineV3.makeContext()
  private let fixture:CIImage={
    let colors:[SIMD4<Float>]=[.init(0.8,0.1,0.1,1),.init(0.1,0.8,0.1,1),.init(0.1,0.1,0.8,1),.init(0.4,0.4,0.4,0.5)]
    let pixels=(0..<16).map{colors[$0/4]}
    return CIImage(bitmapData:pixels.withUnsafeBytes{Data($0)},bytesPerRow:16*16,size:.init(width:16,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
  }()
  private func read(_ image:CIImage)->[SIMD4<Float>] {
    context.clearCaches();var pixels=[SIMD4<Float>](repeating:.zero,count:16)
    context.render(image,toBitmap:&pixels,rowBytes:16*16,bounds:.init(x:0,y:0,width:16,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    return pixels
  }
  func testIsolationKeepsActiveHueAndMakesOthersAchromatic()throws {
    var p=DevelopmentAdjustmentsV3();p.selectiveColor.enabled=true;p.selectiveColor.visualiseIsolation = .red
    let direct=try DevelopmentGlobalEngineV3.apply(p,to:fixture,sourceIsRAW:false)
    let actual=read(direct),original=read(fixture)
    for c in 0..<3{XCTAssertEqual(actual[1][c],original[1][c],accuracy:3e-5)}
    for index in [5,9] {
      XCTAssertEqual(actual[index].x,actual[index].y,accuracy:3e-5)
      XCTAssertEqual(actual[index].y,actual[index].z,accuracy:3e-5)
    }
    XCTAssertEqual(actual[13].w,original[13].w)
    let proxy=try PreviewInteractiveProxyV3.suffix(p,source:fixture,sourceIsRAW:false,nativeSize:.init(width:16,height:1),scale:1,context:context,check:{})
    let scaled=read(proxy)
    for i in scaled.indices{for c in 0..<4{XCTAssertEqual(scaled[i][c],actual[i][c],accuracy:5e-5)}}
    let encoded=try JSONEncoder().encode(p.selectiveColor)
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentSelectiveColorV3.self,from:encoded),p.selectiveColor)
  }
}
