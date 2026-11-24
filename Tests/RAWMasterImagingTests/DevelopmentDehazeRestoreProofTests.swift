import CoreImage
import XCTest
@testable import RAWMasterImaging

final class DevelopmentDehazeRestoreProofTests: XCTestCase {
  func testProgramHashesAreLinkedToBothActualKernelSources() throws {
    let restore = try DevelopmentDehazeRfTransportV1.restoreSource(), coverage = PreviewFITCoverageV1.metalSource
    XCTAssertTrue(DevelopmentDehazeRestoreProof.programIsKnown)
    XCTAssertFalse(DevelopmentDehazeRestoreProof.matches(restore:restore+" ",coverage:coverage))
    XCTAssertFalse(DevelopmentDehazeRestoreProof.matches(restore:restore,coverage:coverage+" "))
  }

  func testNativeGroupMustAcknowledgeSourceRangeAndWriteEveryLastPixel() {
    func decision(_ flags:[UInt16], _ requiresRange:Bool = true) -> Bool? {
      flags.withUnsafeBufferPointer { DevelopmentNativeDehazeErosion.groupRange($0,offset:0,width:17,height:17,expectsRange:requiresRange) }
    }
    let valid:[UInt16] = [0xa500,0xa410,0xa410,0xa401]
    XCTAssertEqual(decision(valid),true)
    XCTAssertEqual(decision([valid[0],valid[1],valid[2],0xac01]),false)
    XCTAssertNil(decision([valid[0],valid[1],valid[2],0]))
    XCTAssertNil(decision([valid[0],valid[1],valid[2],0xa400]))
    XCTAssertNil(decision([valid[0],valid[1],valid[2],0xa001]))
    XCTAssertNil(decision(valid,false))
  }

  func testJoinedR32RowsKeepSignedZerosAndCheckTheShortLastBand() throws {
    let heights = [1,255,256,257,263]
    for height in heights {
      let witness = DevelopmentDehazeRestoreProof.Rows(width:2,height:height)
      var storage = [UInt32](repeating:0xffff_ffff,count:height*3)
      try storage.withUnsafeMutableBytes { destination in
        for band in stride(from:0,to:height,by:256) {
          let rows = min(256,height-band)
          for row in 0..<rows {
            let input:[Float] = [.init(bitPattern:0x8000_0000),Float(band+row)/256]
            try input.withUnsafeBufferPointer {
              try witness.copy($0,bandY:band,bandHeight:rows,row:row,to:destination,rowBytes:12)
            }
          }
        }
      }
      XCTAssertTrue(try witness.finished())
      for band in stride(from:0,to:height,by:256) {
        let rows = min(256,height-band)
        for row in 0..<rows {
          let at = (height-band-rows+row)*3
          XCTAssertEqual(storage[at],0x8000_0000)
          XCTAssertEqual(storage[at+1],(Float(band+row)/256).bitPattern)
          XCTAssertEqual(storage[at+2],0xffff_ffff)
        }
      }
    }
  }

  func testNonfiniteUnwrittenAndOmittedRowsFailButFiniteOutliersRetainStockScan() throws {
    func copy(_ values:[Float], width:Int=1, height:Int=1, band:Int=0, bandHeight:Int=1, row:Int=0) throws -> Bool {
      let witness = DevelopmentDehazeRestoreProof.Rows(width:width,height:height)
      var storage = [Float](repeating:0,count:width*height)
      try storage.withUnsafeMutableBytes { dest in
        try values.withUnsafeBufferPointer { try witness.copy($0,bandY:band,bandHeight:bandHeight,row:row,to:dest,rowBytes:width*4) }
      }
      return try witness.finished()
    }
    for value:Float in [2,-2,.leastNonzeroMagnitude,0,-0] { XCTAssertTrue(try copy([value])) }
    for value:Float in [Float(2).nextUp,Float(-2).nextDown,1e20,.greatestFiniteMagnitude] { XCTAssertFalse(try copy([value])) }
    for value:Float in [.nan,.infinity,-.infinity,Float(bitPattern:0xffff_ffff)] { XCTAssertThrowsError(try copy([value])) }
    XCTAssertThrowsError(try copy([],width:1))
    XCTAssertThrowsError(try copy([0],height:257,band:256,bandHeight:1))
    XCTAssertThrowsError(try copy([0],height:2,bandHeight:2))
    XCTAssertThrowsError(try copy([0],height:2,bandHeight:2,row:1))
  }
}
