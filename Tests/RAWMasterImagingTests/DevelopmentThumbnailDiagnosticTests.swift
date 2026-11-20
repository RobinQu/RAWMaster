import XCTest
@testable import RAWMasterImaging

final class DevelopmentThumbnailDiagnosticTests:XCTestCase {
  func testOptionalTracePreservesOperationResultAndClosedErrorNamespace() throws {
    var events=[DevelopmentThumbnailDiagnosticRecord](),calls=0
    let result=try DevelopmentThumbnailDiagnostic.trace("sample",callback:{events.append($0)}) { calls+=1;return 17 }
    XCTAssertEqual(result,17);XCTAssertEqual(calls,1)
    XCTAssertEqual(events.map(\.stage),["sample.before","sample.returned"])
    events.removeAll()
    XCTAssertThrowsError(try DevelopmentThumbnailDiagnostic.trace("sample",callback:{events.append($0)}) { () throws -> Int in
      calls+=1;throw DevelopmentError.invalidEncoding
    }) { XCTAssertTrue($0 is DevelopmentError) }
    XCTAssertEqual(calls,2);XCTAssertEqual(events.map(\.stage),["sample.before","sample.threw"])
    XCTAssertEqual(events.last?.errorNamespace,"RAWMasterImaging.DevelopmentError")
    XCTAssertEqual(events.last?.errorCase,"invalidEncoding")
    let other=DevelopmentThumbnailDiagnosticRecord("sample",error:DevelopmentThumbnailError.invalidEncoding)
    XCTAssertNotEqual(other.errorNamespace,events.last?.errorNamespace)
    XCTAssertEqual(other.errorCase,"invalidEncoding")
  }
  func testNilTraceDoesNotRepeatOperationOrChangeThrownError() throws {
    var calls=0
    let value=DevelopmentThumbnailDiagnostic.trace("sample",callback:nil){calls+=1;return 23}
    XCTAssertEqual(value,23);XCTAssertEqual(calls,1)
    XCTAssertThrowsError(try DevelopmentThumbnailDiagnostic.trace("sample",callback:nil){() throws -> Int in
      calls+=1;throw DevelopmentThumbnailError.invalidEncoding
    }){XCTAssertTrue($0 is DevelopmentThumbnailError)}
    XCTAssertEqual(calls,2)
  }
}
