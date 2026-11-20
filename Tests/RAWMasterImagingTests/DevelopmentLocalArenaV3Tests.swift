import XCTest
import Darwin
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentLocalArenaV3Tests: XCTestCase {
  private func budgetError(_ error:Error,file:StaticString = #filePath,line:UInt = #line) {
    if case DevelopmentPreviewError.memoryBudgetExceeded=error {} else {
      XCTFail("Expected existing allocation budget error, got \(error)",file:file,line:line)
    }
  }
  private func same(_ actual:(metadata:Int,analysis:Int),_ expected:(metadata:Int,analysis:Int),
                    file:StaticString = #filePath,line:UInt = #line) {
    XCTAssertEqual(actual.metadata,expected.metadata,file:file,line:line)
    XCTAssertEqual(actual.analysis,expected.analysis,file:file,line:line)
  }
  func testPageLayoutExactBoundariesAndOverflowNeverWrap() throws {
    let page=Int(getpagesize())
    XCTAssertGreaterThan(page,1)
    for (request,expected) in [(1,page),(page-1,page),(page,page),(page+1,2*page),(16*1024*1024,16*1024*1024)] {
      XCTAssertEqual(try DevelopmentLocalAllocationV3.mappedLength(bytes:request,pageSize:page),expected)
    }
    XCTAssertEqual(try DevelopmentLocalAllocationV3.mappedLength(bytes:4,pageSize:3),6)
    for (request,p) in [(0,page),(-1,page),(1,0),(1,-1),(Int.max,page)] {
      XCTAssertThrowsError(try DevelopmentLocalAllocationV3.mappedLength(bytes:request,pageSize:p)) { self.budgetError($0) }
    }
    let largestAligned=Int.max-Int.max%page
    XCTAssertEqual(try DevelopmentLocalAllocationV3.mappedLength(bytes:largestAligned,pageSize:page),largestAligned)
    XCTAssertThrowsError(try DevelopmentLocalAllocationV3.mappedLength(bytes:largestAligned+1,pageSize:page)) { self.budgetError($0) }
  }
  func testActualMappingsChargeAndZeroEveryMappedByteIncludingPadding() throws {
    let page=Int(getpagesize())
    for kind in [DevelopmentLocalChargeV3.Kind.metadata,.analysis] {
      for request in [1,page-1,page,page+1,16*1024*1024] {
        let baseline=DevelopmentLocalChargeV3.snapshot()
        let length=try DevelopmentLocalAllocationV3.mappedLength(bytes:request,pageSize:page)
        try autoreleasepool {
          var stages=[String]()
          let storage=try DevelopmentLocalAllocationV3(bytes:request,kind:kind,testStage:{ stage,requested,reserved,actualMalloc in
            stages.append(stage);XCTAssertEqual(requested,request);XCTAssertEqual(reserved,length);XCTAssertNil(actualMalloc)
          })
          XCTAssertEqual(storage.bytes,length);XCTAssertEqual(UInt(bitPattern:storage.pointer)%UInt(page),0)
          let snapshot=DevelopmentLocalChargeV3.snapshot()
          switch kind {
          case .metadata:same(snapshot,(baseline.metadata+length,baseline.analysis))
          case .analysis:same(snapshot,(baseline.metadata,baseline.analysis+length))
          }
          XCTAssertTrue(UnsafeRawBufferPointer(start:storage.pointer,count:length).allSatisfy { $0 == 0 })
          storage.pointer.storeBytes(of:UInt8(0xa7),toByteOffset:request-1,as:UInt8.self)
          XCTAssertEqual(storage.pointer.load(fromByteOffset:request-1,as:UInt8.self),0xa7)
          storage.pointer.storeBytes(of:UInt8(0x5c),toByteOffset:length-1,as:UInt8.self)
          XCTAssertEqual(storage.pointer.load(fromByteOffset:length-1,as:UInt8.self),0x5c)
          XCTAssertEqual(stages,["charge-before","charge-after","mmap-before","mmap-returned","initialized"])
          withExtendedLifetime(storage) {}
        }
        same(DevelopmentLocalChargeV3.snapshot(),baseline)
      }
    }
  }
  func testInvalidOrOverCapRequestRejectsBeforeMappingAndNeverDebits() {
    let baseline=DevelopmentLocalChargeV3.snapshot()
    for request in [0,-1,Int.max,DevelopmentLocalWorkEstimatorV1.analysisUnionBytes+1] {
      var stages=[String]()
      XCTAssertThrowsError(try DevelopmentLocalAllocationV3(bytes:request,kind:.analysis,testStage:{ stage,_,_,_ in stages.append(stage) })) {
        self.budgetError($0)
      }
      XCTAssertFalse(stages.contains("mmap-before"));same(DevelopmentLocalChargeV3.snapshot(),baseline)
    }
  }
  func testOneByteRequiresWholePageAndRejectsAtRealLowHeadroomBeforeMap() throws {
    let page=Int(getpagesize()),baseline=DevelopmentLocalChargeV3.snapshot()
    try autoreleasepool {
      let hold=try DevelopmentLocalChargeV3(DevelopmentLocalWorkEstimatorV1.analysisUnionBytes-baseline.analysis-(page-1),kind:.analysis)
      let held=DevelopmentLocalChargeV3.snapshot()
      XCTAssertEqual(held.analysis,DevelopmentLocalWorkEstimatorV1.analysisUnionBytes-(page-1))
      var stages=[String]()
      XCTAssertThrowsError(try DevelopmentLocalAllocationV3(bytes:1,kind:.analysis,testStage:{ stage,_,reserved,_ in
        stages.append(stage);XCTAssertEqual(reserved,page)
      })) { self.budgetError($0) }
      XCTAssertEqual(stages,["charge-before","charge-threw"])
      same(DevelopmentLocalChargeV3.snapshot(),held);withExtendedLifetime(hold) {}
    }
    same(DevelopmentLocalChargeV3.snapshot(),baseline)
  }
  func testMetadataAndAnalysisHoldsPreserveCombinedHardUnion() throws {
    let baseline=DevelopmentLocalChargeV3.snapshot()
    try autoreleasepool {
      let metadata=try DevelopmentLocalChargeV3(DevelopmentLocalWorkEstimatorV1.metadataUnionBytes-baseline.metadata,kind:.metadata)
      let analysis=try DevelopmentLocalChargeV3(DevelopmentLocalWorkEstimatorV1.analysisUnionBytes-baseline.analysis,kind:.analysis)
      let held=DevelopmentLocalChargeV3.snapshot()
      XCTAssertEqual(held.metadata+held.analysis,DevelopmentLocalWorkEstimatorV1.combinedUnionBytes)
      for kind in [DevelopmentLocalChargeV3.Kind.metadata,.analysis] {
        var mapped=false
        XCTAssertThrowsError(try DevelopmentLocalAllocationV3(bytes:1,kind:kind,testStage:{ stage,_,_,_ in
          if stage == "mmap-before" { mapped=true }
        })) { self.budgetError($0) }
        XCTAssertFalse(mapped);same(DevelopmentLocalChargeV3.snapshot(),held)
      }
      withExtendedLifetime((metadata,analysis)) {}
    }
    same(DevelopmentLocalChargeV3.snapshot(),baseline)
  }
  func testFinalAliasActuallyUnmapsBeforeReturningItsCharge() throws {
    let baseline=DevelopmentLocalChargeV3.snapshot(),page=Int(getpagesize())
    var releases=0
    var owner:DevelopmentLocalAllocationV3?=try .init(bytes:1,kind:.analysis,testRelease:{ status,length in
      releases += 1;XCTAssertEqual(status,0);XCTAssertEqual(length,page)
      self.same(DevelopmentLocalChargeV3.snapshot(),(baseline.metadata,baseline.analysis+page))
    })
    var alias=owner
    let pointer=owner!.pointer
    owner=nil
    same(DevelopmentLocalChargeV3.snapshot(),(baseline.metadata,baseline.analysis+page));XCTAssertEqual(releases,0)
    pointer.storeBytes(of:UInt8(0x63),as:UInt8.self);XCTAssertEqual(pointer.load(as:UInt8.self),0x63)
    withExtendedLifetime(alias) {};alias=nil
    XCTAssertEqual(releases,1);same(DevelopmentLocalChargeV3.snapshot(),baseline)
  }
}
