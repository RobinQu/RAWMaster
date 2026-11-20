import XCTest
import AppKit
import CoreImage
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentAdvancedDetailBridgeTests:XCTestCase {
  private func fixture()throws->(URL,URL,DevelopmentLocalEditSourceBinding) {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("RAWMaster-B6-bridge-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let b=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:128,pixelsHigh:96,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:512,bitsPerPixel:32))
    for y in 0..<96{for x in 0..<128{let n=y*512+x*4
      b.bitmapData![n]=UInt8((x*3+y*11)%251);b.bitmapData![n+1]=UInt8((x*7+y*5)%239)
      b.bitmapData![n+2]=UInt8((x*13+y*17)%241);b.bitmapData![n+3]=255
    }}
    let data=try XCTUnwrap(b.representation(using:.png,properties:[:])),url=root.appendingPathComponent("source.png")
    try data.write(to:url)
    return(root,url,.init(sourceContentID:try RenderFiles.hash(url),exifOrientation:1,orientedWidth:128,orientedHeight:96))
  }
  private func read(_ image:CIImage)throws->[SIMD4<Float>] {
    var pixels=[SIMD4<Float>]()
    try DevelopmentLocalEngineV3.read(image,rect:image.extent,context:DevelopmentColorEngineV3.context){pixels=Array($0)}
    return pixels
  }
  func testSupportPermitsManualTextureClarityButRequiresPreparedDehaze()throws {
    for raw in [false,true]{for texture in [true,false]{
      var p=DevelopmentAdjustmentsV3()
      if texture{p.advancedDetail.texture = .init(enabled:true,amount:25)}else{p.advancedDetail.clarity = .init(enabled:true,amount:-25)}
      try DevelopmentRendererV3.validateSupport(.init(adjustmentsV3:p),sourceIsRAW:raw)
    }}
    var p=DevelopmentAdjustmentsV3();p.advancedDetail.dehaze = .init(enabled:true,amount:1)
    XCTAssertThrowsError(try DevelopmentRendererV3.validateSupport(.init(adjustmentsV3:p),sourceIsRAW:false)){
      XCTAssertEqual($0 as? DevelopmentDehazePreparationError,.preparationRequired)
    }
  }
  func testRendererGlobalThenAdvancedThenLocalMatchesExplicitGraphAndNotReversedOrder()throws {
    let(root,url,binding)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    var p=DevelopmentAdjustmentsV3();p.definition = .init(enabled:true,amount:0.3)
    p.advancedDetail = .init(texture:.init(enabled:true,amount:60),clarity:.init(enabled:true,amount:-35))
    let operation=DevelopmentLocalEdit(sourceContentID:binding.sourceContentID,tool:.retouch,
      stroke:.init(points:[.init(position:.init(x:0.28,y:0.5))],radiusInShortEdge:0.06,strength:0.8),sourceSample:.init(x:0.72,y:0.5))
    p.localEdits = .init(sourceBinding:binding,retouchEnabled:true,operations:[operation])
    var prefix=p;prefix.advancedDetail = .init();prefix.localEdits = .init()
    let base=try DevelopmentRendererV3.develop(url,recipe:.init(adjustmentsV3:prefix),applyGeometry:false)
    let context=DevelopmentColorEngineV3.context,size=DevelopmentPixelSize(width:128,height:96)
    let advanced=try DevelopmentAdvancedDetailEngineV3.apply(p.advancedDetail,to:base.image,sourceSize:size,context:context)
    let expected=try read(DevelopmentLocalEngineV3.apply(p.localEdits,to:advanced,context:context))
    let actualGraph=try DevelopmentRendererV3.develop(url,recipe:.init(adjustmentsV3:p),applyGeometry:false)
    let actual=try read(actualGraph.image)
    XCTAssertEqual(actualGraph.sourceSize,CGSize(width:128,height:96))
    XCTAssertTrue(actualGraph.graphDescriptor.contains(DevelopmentAdvancedDetailEngineV3.operatorVersion))
    XCTAssertEqual(actual.count,expected.count)
    var maximum=Float(0),alphaMismatch=0
    for i in actual.indices{for c in 0..<3{maximum=max(maximum,abs(actual[i][c]-expected[i][c]))};if actual[i].w.bitPattern != expected[i].w.bitPattern{alphaMismatch+=1}}
    XCTAssertLessThanOrEqual(maximum,2e-5);XCTAssertEqual(alphaMismatch,0)
    let localFirst=try DevelopmentLocalEngineV3.apply(p.localEdits,to:base.image,context:context)
    let reversed=try read(DevelopmentAdvancedDetailEngineV3.apply(p.advancedDetail,to:localFirst,sourceSize:size,context:context))
    var orderDifference=Float(0)
    for (a,b) in zip(expected,reversed){orderDifference=max(orderDifference,max(abs(a.x-b.x),max(abs(a.y-b.y),abs(a.z-b.z))))}
    XCTAssertGreaterThan(orderDifference,1e-6) // Fixture genuinely detects a misplaced bridge.
  }
  func testDisabledAndZeroBridgePreserveActualLegacyPixels()throws {
    let(root,url,_)=try fixture();defer{try?FileManager.default.removeItem(at:root)}
    let original=try DevelopmentRecipe().promotingToV3()
    let baseline=try read(DevelopmentRendererV3.develop(url,recipe:original).image)
    for parameters in [DevelopmentAdvancedDetailV3(texture:.init(enabled:false,amount:100),clarity:.init(enabled:false,amount:-100)),
                       .init(texture:.init(enabled:true,amount:0),clarity:.init(enabled:true,amount:0))] {
      var r=original;r.adjustmentsV3!.advancedDetail=parameters
      let actual=try read(DevelopmentRendererV3.develop(url,recipe:r).image)
      XCTAssertEqual(actual.count,baseline.count)
      var mismatched=0
      for i in actual.indices{for c in 0..<4 where actual[i][c].bitPattern != baseline[i][c].bitPattern{mismatched+=1}}
      XCTAssertEqual(mismatched,0)
    }
  }
}
