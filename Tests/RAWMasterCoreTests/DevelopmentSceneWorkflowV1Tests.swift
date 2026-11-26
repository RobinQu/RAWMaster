import Foundation
import RAWMasterCore
import XCTest

final class DevelopmentSceneWorkflowV1Tests: XCTestCase {
  typealias Workflow = DevelopmentSceneWorkflowV1

  func testVersionedRoundTripPreservesNodeIdentityAndOrder() throws {
    let first = try Workflow.Corrector(exposureEV: 1.5)
    let disabled = try Workflow.Corrector(enabled: false, exposureEV: 12)
    let last = try Workflow.Corrector(exposureEV: -0.5)
    let workflow = try Workflow(correctors: [first, disabled, last], output: output())
    let bytes = try JSONEncoder().encode(workflow)
    let replay = try JSONDecoder().decode(Workflow.self, from: bytes)
    XCTAssertEqual(replay, workflow)
    XCTAssertEqual(try replay.exposureEV(through: first.id), 1.5)
    XCTAssertEqual(try replay.exposureEV(through: disabled.id), 1.5)
    XCTAssertEqual(try replay.finalExposureEV(), 1)
    XCTAssertThrowsError(try replay.exposureEV(through: UUID())) {
      XCTAssertEqual($0 as? Workflow.Failure, .unknownNode)
    }
  }

  func testRejectsUnknownSchemaPreviewFieldsAndInvalidGraph() throws {
    let node = try Workflow.Corrector(exposureEV: 7)
    let workflow = try Workflow(correctors: [node], output: output())
    let data = try JSONEncoder().encode(workflow)
    let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for changes: [String: Any] in [
      ["schemaVersion": 2], ["previewNodeID": node.id.uuidString], ["correctors": []],
      ["correctors": Array(repeating: try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)), count: 65)],
    ] {
      let invalid = valid.merging(changes) { _, change in change }
      XCTAssertThrowsError(try JSONDecoder().decode(Workflow.self, from: JSONSerialization.data(withJSONObject: invalid)))
    }
    XCTAssertThrowsError(try Workflow(correctors: [node, node], output: output()))
    XCTAssertThrowsError(try Workflow(correctors: [node, .init(exposureEV: 7), .init(exposureEV: -7)], output: output()))
    XCTAssertThrowsError(try Workflow.Corrector(exposureEV: .nan))
  }

  private func output() throws -> DevelopmentSceneOutputStateV1.Version {
    .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
  }
}
