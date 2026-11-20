import XCTest
import Foundation
@testable import RAWMasterCore

final class DevelopmentLocalEditModelsTests: XCTestCase {
  private let sourceHash = String(repeating:"a",count:64)
  private var source: DevelopmentLocalEditSourceBinding { .init(sourceContentID:sourceHash,exifOrientation:6,orientedWidth:200,orientedHeight:100) }
  private func stroke(_ points: [DevelopmentStrokePoint]? = nil) -> DevelopmentStroke {
    .init(points:points ?? [.init(position:.init(x:0.1,y:0.2)),.init(position:.init(x:0.3,y:0.2))],radiusInShortEdge:0.1)
  }
  private func edit(id: UUID = UUID()) -> DevelopmentLocalEdit { .init(id:id,sourceContentID:sourceHash,tool:.retouch,stroke:stroke()) }
  private func object<T: Encodable>(_ value: T) throws -> [String:Any] {
    try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
  }
  private func decode(_ value: [String:Any]) throws -> DevelopmentLocalEditsV3 {
    try JSONDecoder().decode(DevelopmentLocalEditsV3.self,from:JSONSerialization.data(withJSONObject:value))
  }
  private func assertLimitError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(),file:file,line:line) { error in
      guard case EditingError.invalidRecipe = error else { return XCTFail("Expected pre-element limit rejection, got \(error)",file:file,line:line) }
    }
  }
  func testLocalEditRoundTripAndExpectedBinding() throws {
    let value = DevelopmentLocalEditsV3(sourceBinding:source,retouchEnabled:true,operations:[edit()])
    XCTAssertEqual(try decode(object(value)),value); XCTAssertNoThrow(try value.validate(expectedSource:source))
    for changed in [DevelopmentLocalEditSourceBinding(sourceContentID:String(repeating:"b",count:64),exifOrientation:6,orientedWidth:200,orientedHeight:100),
                    .init(sourceContentID:sourceHash,exifOrientation:1,orientedWidth:200,orientedHeight:100),
                    .init(sourceContentID:sourceHash,exifOrientation:6,orientedWidth:100,orientedHeight:200)] {
      XCTAssertThrowsError(try value.validate(expectedSource:changed))
    }
    var missing = value; missing.sourceBinding = nil; XCTAssertThrowsError(try missing.validate())
    var wrong = value; wrong.operations[0].sourceContentID = String(repeating:"b",count:64); XCTAssertThrowsError(try wrong.validate())
  }
  func testRejectsUnknownToolVersionSamplingVersionDuplicateIDAndSourceShape() throws {
    let operation = edit(); var value = DevelopmentLocalEditsV3(sourceBinding:source,operations:[operation,operation])
    XCTAssertThrowsError(try value.validate())
    value.operations = [operation]; value.operations[0].toolVersion = 2; XCTAssertThrowsError(try value.validate())
    value.operations[0] = operation; value.operations[0].stroke.samplingVersion = 2; XCTAssertThrowsError(try value.validate())
    var json = try object(DevelopmentLocalEditsV3(sourceBinding:source,operations:[operation]))
    var operations = json["operations"] as! [[String:Any]]; operations[0]["tool"] = "unknown"; json["operations"] = operations; XCTAssertThrowsError(try decode(json))
    for orientation in [0,9] { var bad = source; bad.exifOrientation = orientation; XCTAssertThrowsError(try bad.validate()) }
    var bad = source; bad.sourceContentID = sourceHash.uppercased(); XCTAssertThrowsError(try bad.validate())
    bad = source; bad.orientedWidth = 0; XCTAssertThrowsError(try bad.validate())
  }
  func testRedEyeIsOneBoundPointAndCannotReuseRetouchPatchOrSourceSample() throws {
    var operation = DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.redEye,stroke:stroke([.init(position:.init(x:0.4,y:0.4))]))
    XCTAssertNoThrow(try operation.validate()); operation.sourceSample = .init(x:0.5,y:0.5); XCTAssertThrowsError(try operation.validate())
    operation.sourceSample = nil; operation.stroke = stroke(); XCTAssertThrowsError(try operation.validate())
  }
  func testPatchIdentityAndByteBudgets() throws {
    var operation = edit(); operation.patch = .init(sha256:String(repeating:"b",count:64),byteCount:DevelopmentLocalEditLimits.maximumPatchBytes,sourceContentID:sourceHash)
    XCTAssertNoThrow(try operation.validate())
    var wrong = operation; wrong.patch!.sourceContentID = String(repeating:"c",count:64); XCTAssertThrowsError(try wrong.validate())
    wrong = operation; wrong.patch!.toolVersion = 2; XCTAssertThrowsError(try wrong.validate())
    wrong = operation; wrong.patch!.byteCount += 1; XCTAssertThrowsError(try wrong.validate())
    var operations = (0..<4).map { _ -> DevelopmentLocalEdit in var e = operation; e.id = UUID(); return e }
    XCTAssertNoThrow(try DevelopmentLocalEditsV3(sourceBinding:source,operations:operations).validate())
    var fifth = edit(); fifth.patch = .init(sha256:String(repeating:"d",count:64),byteCount:1,sourceContentID:sourceHash); operations.append(fifth)
    let value = DevelopmentLocalEditsV3(sourceBinding:source,operations:operations)
    XCTAssertThrowsError(try value.validate())
    // Build wire data without invoking the validatable owner's encoder.
    var json = try object(DevelopmentLocalEditsV3(sourceBinding:source)); json["operations"] = try operations.map { try object($0) }
    assertLimitError(try decode(json))
  }
  func testOperationAndPointCountRejectBeforeDecodingElements() throws {
    var json = try object(DevelopmentLocalEditsV3(sourceBinding:source)); json["operations"] = Array(repeating:NSNull(),count:DevelopmentLocalEditLimits.maximumOperations+1)
    assertLimitError(try decode(json))
    var st = try object(stroke()); st["points"] = Array(repeating:NSNull(),count:DevelopmentLocalEditLimits.maximumPointsPerStroke+1)
    assertLimitError(try JSONDecoder().decode(DevelopmentStroke.self,from:JSONSerialization.data(withJSONObject:st)))
  }
  func testTotalPointBudgetIsPassedIntoEachNextStrokeDecoder() throws {
    let point = DevelopmentStrokePoint(position:.init(x:0.2,y:0.2))
    let longStroke = DevelopmentStroke(points:Array(repeating:point,count:DevelopmentLocalEditLimits.maximumPointsPerStroke),radiusInShortEdge:0.1)
    var wire: [Any] = []
    for _ in 0..<(DevelopmentLocalEditLimits.maximumTotalPoints/DevelopmentLocalEditLimits.maximumPointsPerStroke) {
      wire.append(try object(DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.retouch,stroke:longStroke)))
    }
    // If the decoder tried the fifth element, NSNull would cause a typeMismatch instead of the budget error.
    wire.append(NSNull()); var json = try object(DevelopmentLocalEditsV3(sourceBinding:source)); json["operations"] = wire
    assertLimitError(try decode(json))
  }
  func testDabBudgetIsSeparateFromStoredPointBudget() throws {
    let smallRadius = 1.0/7500
    let st = DevelopmentStroke(points:[.init(position:.init(x:0,y:0)),.init(position:.init(x:1,y:0))],radiusInShortEdge:smallRadius)
    XCTAssertLessThanOrEqual(try st.dabCount(sourceSize:source.sourceSize),DevelopmentLocalEditLimits.maximumDabsPerStroke)
    let operations = (0..<9).map { _ in DevelopmentLocalEdit(sourceContentID:sourceHash,tool:.retouch,stroke:st) }
    XCTAssertLessThan(operations.reduce(0) { $0+$1.stroke.points.count },DevelopmentLocalEditLimits.maximumTotalPoints)
    XCTAssertThrowsError(try DevelopmentLocalEditsV3(sourceBinding:source,operations:operations).validate())
  }
  func testStreamingReplayPreservesEndpointPressureAndCircularSourceDistance() throws {
    let first = DevelopmentStrokePoint(position:.init(x:0.1,y:0.2),pressure:0.2), last = DevelopmentStrokePoint(position:.init(x:0.3,y:0.2),pressure:1)
    let st = stroke([first,last]); var samples: [DevelopmentStrokePoint] = []
    try st.forEachDab(sourceSize:source.sourceSize) { samples.append($0) }
    XCTAssertEqual(samples.count,try st.dabCount(sourceSize:source.sourceSize)); XCTAssertEqual(samples.first,first); XCTAssertEqual(samples.last,last)
    XCTAssertEqual(samples.count,17)
    for i in 1..<samples.count {
      let a = samples[i-1], b = samples[i]
      XCTAssertGreaterThanOrEqual(b.pressure,a.pressure)
      let dx = (b.position.x-a.position.x)*200, dy = (b.position.y-a.position.y)*100
      XCTAssertLessThanOrEqual(hypot(dx,dy),0.1*100*DevelopmentLocalEditLimits.dabSpacingInRadii+1e-12)
    }
    let vertical = stroke([.init(position:.init(x:0.1,y:0.2)),.init(position:.init(x:0.1,y:0.6))])
    XCTAssertEqual(try vertical.dabCount(sourceSize:source.sourceSize),samples.count)
    let repeated = stroke([first,first,last]); var tail: DevelopmentStrokePoint?
    try repeated.forEachDab(sourceSize:source.sourceSize) { tail = $0 }; XCTAssertEqual(tail,last)
  }
  func testInvalidCoordinatesPressureRadiusAndDisabledOperationsAreRejected() throws {
    for bad in [Double.nan,Double.infinity,-Double.infinity] {
      var st = stroke(); st.points[0].position.x = bad; XCTAssertThrowsError(try st.validate())
      st = stroke(); st.points[0].pressure = bad; XCTAssertThrowsError(try st.validate())
      st = stroke(); st.radiusInShortEdge = bad; XCTAssertThrowsError(try st.validate())
    }
    var e = edit(); e.stroke.points[0].position.y = 1.00001
    let value = DevelopmentLocalEditsV3(sourceBinding:source,retouchEnabled:false,operations:[e]); XCTAssertThrowsError(try value.validate())
  }
}
