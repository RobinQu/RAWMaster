import XCTest
import CoreImage
import Metal
import ImageIO
@testable import RAWMasterImaging

final class DevelopmentThumbnailRawRoundoffTests:XCTestCase {
  private func words(_ pixels:[SIMD4<Float>])->[UInt32]{pixels.flatMap{[$0.x.bitPattern,$0.y.bitPattern,$0.z.bitPattern,$0.w.bitPattern]}}
  func testOnlyExactNextUpChangesWhileValidHDRPartialAndZeroBitsBypass()throws {
    let a=Float(bitPattern:0x3f800001)
    let original:[SIMD4<Float>]=[.init(0.2,-16,1024,a),.init(-0.0,32,-64,0),.init(0.125,-0.25,0.5,0.5),.init(2,-4,8,1)]
    var actual=original
    try actual.withUnsafeMutableBytes{try ThumbnailSurface.normalizeRawProxyPixels($0.baseAddress!,width:4,height:1,rowBytes:64)}
    XCTAssertEqual(words(Array(actual.dropFirst())),words(Array(original.dropFirst())))
    XCTAssertEqual(actual[0].w.bitPattern,Float(1).bitPattern)
    for c in 0..<3 {XCTAssertEqual(actual[0][c],Float(Double(original[0][c])/Double(a)))}
  }
  func testInvalidAnywhereRejectsWholeBufferWithoutPartialMutation()throws {
    let next=Float(bitPattern:0x3f800001)
    let invalid:[SIMD4<Float>]=[.init(0,0,0,Float(bitPattern:0x3f800002)),.init(0,0,0,-0.1),.init(.nan,0,0,0),.init(0,.infinity,0,1),.init(0,0,0,.nan)]
    for bad in invalid {
      var pixels:[SIMD4<Float>]=[.init(0.25,0.5,1,next),bad];let before=words(pixels)
      XCTAssertThrowsError(try pixels.withUnsafeMutableBytes{try ThumbnailSurface.normalizeRawProxyPixels($0.baseAddress!,width:2,height:1,rowBytes:32)}) {
        if case DevelopmentThumbnailError.invalidEncoding=$0 {}else{XCTFail("wrong rejection")}
      }
      XCTAssertEqual(words(pixels),before)
    }
  }
  func testTailAndPaddingRemainUntouched()throws {
    let width=15,height=7,rowWords=width*4+16
    var storage=[UInt32](repeating:0x7fc01234,count:rowWords*height)
    for y in 0..<height {for x in 0..<width {let i=y*rowWords+x*4;storage[i]=Float(x).bitPattern;storage[i+1]=Float(y).bitPattern;storage[i+2]=Float(-1).bitPattern;storage[i+3]=(x==14 && y==6) ? 0x3f800001:Float(0.5).bitPattern}}
    let before=storage
    try storage.withUnsafeMutableBytes{try ThumbnailSurface.normalizeRawProxyPixels($0.baseAddress!,width:width,height:height,rowBytes:rowWords*4)}
    for y in 0..<height {for n in width*4..<rowWords {XCTAssertEqual(storage[y*rowWords+n],before[y*rowWords+n])}}
    XCTAssertEqual(storage[(height-1)*rowWords+(width-1)*4+3],Float(1).bitPattern)
  }
  func testActualSharedCVWriteIsVisibleThroughOriginalGPUAliasForOrientation6And8()throws {
    guard let device=MTLCreateSystemDefaultDevice()else{throw XCTSkip("Metal unavailable")}
    for orientation in [CGImagePropertyOrientation.right,.left] {
      let ledger=ThumbnailLedger(),context=DevelopmentThumbnailEngine.context(device:device)
      try autoreleasepool {
        let next=Float(bitPattern:0x3f800001)
        let pixels=(0..<105).map{i -> SIMD4<Float> in
          let a:Float=i%5==0 ? next:(i%5==1 ? 0:(i%5==2 ? 0.5:1))
          return .init(Float(i%15)/32*a,-0.125*a,Float(i/15)/16*a,a)
        }
        let data=pixels.withUnsafeBytes{Data($0)}
        let input=CIImage(bitmapData:data,bytesPerRow:15*16,size:.init(width:15,height:7),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB).oriented(orientation)
        let graph=input.transformed(by:.init(translationX:-input.extent.minX,y:-input.extent.minY))
        XCTAssertEqual(graph.extent,CGRect(x:0,y:0,width:7,height:15))
        let owner=try ThumbnailSurface(width:7,height:15,float:true,kind:.proxy,ledger:ledger,device:device)
        defer{owner.finishProducer();owner.retire();context.clearCaches()}
        try owner.fill(graph,context:context)
        let before=try owner.withFloatPixels{p,row -> [SIMD4<Float>] in
          (0..<15).flatMap{y in Array(UnsafeBufferPointer(start:p.advanced(by:y*row).assumingMemoryBound(to:SIMD4<Float>.self),count:7))}
        }
        XCTAssertTrue(before.contains{$0.w.bitPattern==0x3f800001},"fixture must actually reach oneULP producer representation")
        try owner.normalizeRawProxyAlphaRoundoff()
        var expected=before
        try expected.withUnsafeMutableBytes{try ThumbnailSurface.normalizeRawProxyPixels($0.baseAddress!,width:7,height:15,rowBytes:7*16)}
        let destination=try ThumbnailSurface(width:7,height:15,float:true,kind:.summary,ledger:ledger,device:device)
        defer{destination.finishProducer();destination.retire()}
        try owner.withImage {image in try DevelopmentLocalEngineV3.validatePixels(image,context:context);try destination.fill(image,context:context)}
        let observed=try destination.withFloatPixels{p,row -> [SIMD4<Float>] in
          (0..<15).flatMap{y in Array(UnsafeBufferPointer(start:p.advanced(by:y*row).assumingMemoryBound(to:SIMD4<Float>.self),count:7))}
        }
        XCTAssertEqual(words(observed),words(expected),"actual GPU alias must see joined CPU writes, no rowflip or second image copy")
        owner.finishProducer()
        XCTAssertThrowsError(try owner.normalizeRawProxyAlphaRoundoff(),"published storage may not be mutated")
      }
      XCTAssertEqual(ledger.snapshot().unionBytes,0)
    }
  }
  func testUnnormalizedImageAlphaStillFailsOriginalLocalGate()throws {
    let pixel=SIMD4<Float>(0.25,0.25,0.25,Float(bitPattern:0x3f800001))
    let data=withUnsafeBytes(of:pixel){Data($0)}
    let image=CIImage(bitmapData:data,bytesPerRow:16,size:.init(width:1,height:1),format:.RGBAf,colorSpace:DevelopmentColorEngineV3.linearSRGB)
    XCTAssertThrowsError(try DevelopmentLocalEngineV3.validatePixels(image,context:DevelopmentColorEngineV3.context)) {
      if case DevelopmentError.invalidEncoding=$0 {}else{XCTFail("original Local gate must remain strict")}
    }
  }
}
