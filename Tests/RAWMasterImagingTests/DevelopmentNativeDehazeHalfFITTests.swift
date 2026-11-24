import XCTest
@testable import RAWMasterImaging

final class DevelopmentNativeDehazeHalfFITTests: XCTestCase {
  func testTwoVerifiedRenderPlansAndDeviceGridOrder() {
    for (width,height,count) in [(9504,6336,29),(8640,5760,27)] {
      let native=width*height,pixels=2*native+native/4+2*2400*1600
      XCTAssertTrue(DevelopmentNativeDehazeHalfFIT.acceptsTopology(width:width,height:height,passes:count,pixels:pixels,overdraw:0))
      XCTAssertFalse(DevelopmentNativeDehazeHalfFIT.acceptsTopology(width:height,height:width,passes:count,pixels:pixels,overdraw:0))
      XCTAssertFalse(DevelopmentNativeDehazeHalfFIT.acceptsTopology(width:width,height:height,passes:count+1,pixels:pixels,overdraw:0))
      XCTAssertFalse(DevelopmentNativeDehazeHalfFIT.acceptsTopology(width:width,height:height,passes:count,pixels:pixels+1,overdraw:0))
      XCTAssertFalse(DevelopmentNativeDehazeHalfFIT.acceptsTopology(width:width,height:height,passes:count,pixels:pixels,overdraw:1))
    }
  }

  func testRestoreAndHalfGroupsIndependentlyCountTheirNativeAndTailWrites() {
    let full:UInt32=0xa000_0080,one:UInt32=0xa000_0001,half:UInt32=0xa000_0040
    func verifies(_ flags:[UInt32],_ offset:Int,_ pixels:Int)->Bool {
      flags.withUnsafeBufferPointer{DevelopmentNativeDehazeHalfFIT.allGroupsWrote($0,offset:offset,pixels:pixels)}
    }
    // The two encoders write disjoint arrays in a single joined command.
    XCTAssertTrue(verifies([full,one,half],0,129))
    XCTAssertTrue(verifies([full,one,half],2,64))
    XCTAssertFalse(verifies([full,0,half],0,129))
    XCTAssertFalse(verifies([full,one,0],2,64))
    XCTAssertFalse(verifies([full,one,full],2,64))
    XCTAssertFalse(verifies([full,one,half|0x0001_0000],2,64))
    XCTAssertFalse(verifies([full,one],2,1))
    XCTAssertFalse(verifies([full],-1,128))
    XCTAssertFalse(verifies([full],0,0))
  }
}
