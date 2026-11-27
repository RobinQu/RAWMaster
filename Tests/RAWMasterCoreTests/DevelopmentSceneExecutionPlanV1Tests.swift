import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentSceneExecutionPlanV1Tests: XCTestCase {
  typealias Plan = DevelopmentSceneExecutionPlanV1

  func testNormalLayerUsesLinearGainAndDoesNotDependOnNodeArrayOrder() throws {
    let a = UUID(), b = UUID(), mix = UUID(), last = UUID()
    let before: [Plan.Node] = [
      .init(id: a, operation: .exposure(input: .source, ev: 1, enabled: true)),
      .init(id: b, operation: .exposure(input: .node(a), ev: 2, enabled: true)),
      .init(id: mix, operation: .normalLayer(base: .node(a), layer: .node(b), weight: 0.25)),
      .init(id: last, operation: .exposure(input: .node(mix), ev: -1, enabled: true)),
    ]
    for nodes in [before, Array(before.reversed())] {
      let plan = try Plan(nodes: nodes, final: .node(last))
      XCTAssertEqual(try plan.exposureEV(at: .node(a)), 1)
      XCTAssertEqual(try plan.exposureEV(at: .node(b)), 3)
      XCTAssertEqual(try plan.exposureEV(at: .node(mix)), log2(Float(3.5)), accuracy: 1e-6)
      XCTAssertEqual(exp2(plan.finalExposureEV), 1.75, accuracy: 1e-6)
      XCTAssertEqual(try plan.exposureEV(at: .source), 0)
      XCTAssertThrowsError(try plan.exposureEV(at: .node(UUID())))
    }
  }

  func testExactBypassAndStructuralRejectionIncludingZeroWeightBranches() throws {
    let a = UUID(), b = UUID()
    let neutral = Plan.Node(id: a, operation: .exposure(input: .source, ev: 9, enabled: false))
    let layer = Plan.Node(id: b, operation: .normalLayer(base: .source, layer: .node(a), weight: 0))
    XCTAssertEqual(try Plan(nodes: [neutral, layer], final: .node(b)).finalExposureEV, 0)
    XCTAssertThrowsError(try Plan(nodes: [neutral, neutral], final: .node(a))) { XCTAssertEqual($0 as? Plan.Failure, .invalidNodes) }
    XCTAssertThrowsError(try Plan(nodes: [layer], final: .node(b))) { XCTAssertEqual($0 as? Plan.Failure, .missingNode(a)) }
    let cycle = Plan.Node(id: a, operation: .exposure(input: .node(b), ev: 0, enabled: false))
    XCTAssertThrowsError(try Plan(nodes: [cycle, layer], final: .node(b))) { XCTAssertEqual($0 as? Plan.Failure, .cycle(b)) }
    XCTAssertThrowsError(try Plan(nodes: [neutral, layer], final: .node(a))) { XCTAssertEqual($0 as? Plan.Failure, .disconnectedNodes) }
    let invalidWeight = Plan.Node(id: b, operation: .normalLayer(base: .source, layer: .node(a), weight: .nan))
    XCTAssertThrowsError(try Plan(nodes: [neutral, invalidWeight], final: .node(b))) { XCTAssertEqual($0 as? Plan.Failure, .invalidWeight) }
    let tooBright = Plan.Node(id: a, operation: .exposure(input: .source, ev: 12, enabled: true))
    let oneStop = Plan.Node(id: b, operation: .exposure(input: .node(a), ev: 1, enabled: true))
    XCTAssertThrowsError(try Plan(nodes: [tooBright, oneStop], final: .node(b))) { XCTAssertEqual($0 as? Plan.Failure, .invalidExposure) }
  }
}
