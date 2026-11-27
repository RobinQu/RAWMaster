import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentSceneGraphV1Tests: XCTestCase {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Node = Graph.Node

  func testOnlyUsedModelCoverageRejectsChangesToItsCoordinatesAndOldArchivesRemainReadable() throws {
    let stage = DevelopmentSceneModelStageV1.segmentation(.subject)
    let models = try DevelopmentSceneModelProgramV1(stages: [stage])
    let mask = Node(name: "subject", operation: .externalCoverage(id: stage.id))
    let grade = Node(name: "exposure", operation: .corrector(image: .input, mask: mask.id,
      exposureEV: 1, curve: [], strength: 1, enabled: true))
    let scope = Graph.Scope(nodes: [mask, grade], output: .node(grade.id))
    let original = try Graph(graph: scope, output: output(), models: models)
    var crop = DevelopmentAdjustmentsV3()
    crop.geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    let incompatible = try original.replacingPhotographic(crop)
    let reopened = try JSONDecoder().decode(Graph.self, from: JSONEncoder().encode(incompatible))
    XCTAssertEqual(reopened, incompatible)
    XCTAssertThrowsError(try reopened.validatePhotographicCoverage()) { XCTAssertTrue($0 is Graph.PhotographicCoverageMisalignment) }
    XCTAssertNoThrow(try reopened.validatePhotographicCoverage(view: .init(target: .bypass)))
    var optical = DevelopmentAdjustmentsV3()
    optical.optics = .init(removeChromaticAberration: true, lensVignettingAmount: 0.5)
    XCTAssertNoThrow(try original.replacingPhotographic(optical).validatePhotographicCoverage())
    optical.optics?.distortion = 0.25
    XCTAssertThrowsError(try original.replacingPhotographic(optical).validatePhotographicCoverage())
    let layer = Node(name: "bypass", operation: .layer(base: .input, layers: [.init(.node(grade.id), weight: 0)], enabled: true))
    let bypassed = try Graph(graph: .init(nodes: [mask, grade, layer], output: .node(layer.id)), output: output(), models: models, photographic: crop)
    XCTAssertNoThrow(try bypassed.validatePhotographicCoverage())
    XCTAssertThrowsError(try bypassed.validatePhotographicCoverage(view: .init(target: .node(grade.id))))
    XCTAssertNoThrow(try Graph(graph: .init(nodes: [], output: .input), output: output(), models: models, photographic: crop).validatePhotographicCoverage())
  }

  func testFrozenModelStagesSurviveGraphEditsTemplatesAndRecipeReopen() throws {
    let stage = DevelopmentSceneModelStageV1.denoise(amount: 41)
    let models = try DevelopmentSceneModelProgramV1(stages: [stage, .segmentation(.subject)])
    let node = grade()
    let graph = try Graph(graph: .init(nodes: [node], output: .node(node.id)), output: output(), models: models)
    let edited = try graph.replacingGraph(graph.graph).remapped()
    XCTAssertEqual(edited.models, models)
    let bytes = try JSONEncoder().encode(DevelopmentRecipe(sceneGraph: edited))
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(bytes).sceneGraph?.models, models)
    let sameNodes = try Graph(graph: edited.graph, output: edited.output)
    XCTAssertNotEqual(try EditingFingerprint.of(DevelopmentRecipe(sceneGraph: sameNodes)),
                      try EditingFingerprint.of(DevelopmentRecipe(sceneGraph: edited)))
    var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
    XCTAssertEqual(fields["schemaVersion"] as? Int, 2)
    fields["schemaVersion"] = 1
    XCTAssertThrowsError(try JSONDecoder().decode(Graph.self, from: JSONSerialization.data(withJSONObject: fields)))
  }

  func testNestedScopeMaskDependenciesAndRecipeRoundTripRemapAsOneValue() throws {
    let mask = Node(name: "Gradient", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let corrector = grade(mask: mask.id)
    let group = Node(name: "Group", operation: .group(image: .input,
      graph: .init(nodes: [corrector, mask], output: .node(corrector.id)), strength: 1, enabled: true))
    let graph = try value([group], end: .node(group.id))
    let recipe = DevelopmentRecipe(sceneGraph: graph), pin = try EditingFingerprint.of(recipe)
    let replay = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(recipe))
    XCTAssertEqual(replay, recipe)
    XCTAssertEqual(replay.schemaVersion, 4)
    XCTAssertEqual(try EditingFingerprint.of(replay), pin)
    XCTAssertThrowsError(try replay.promotingToV2())
    XCTAssertThrowsError(try replay.promotingToV3())
    var invalidRecipe = replay
    invalidRecipe.exposureEV = 0.5
    XCTAssertThrowsError(try JSONEncoder().encode(invalidRecipe), "legacy ops must not silently coexist with the graph")
    let clone = try graph.remapped(), copiedGroup = try XCTUnwrap(clone.graph.nodes.first)
    XCTAssertNotEqual(copiedGroup.id, group.id)
    guard case let .group(_, child, _, _) = copiedGroup.operation,
          case let .corrector(_, ref, _, _, _, _) = child.nodes[0].operation else { return XCTFail("scoped clone lost its operators") }
    XCTAssertNotEqual(child.nodes[0].id, corrector.id)
    XCTAssertNotEqual(child.nodes[1].id, mask.id)
    XCTAssertEqual(ref, child.nodes[1].id)
    XCTAssertEqual(child.output, .node(child.nodes[0].id))
    XCTAssertThrowsError(try graph.remapped(generate: { group.id }))
  }

  func testRejectsCyclesPortMismatchAndUnknownFieldsEvenOnUnrenderedBranches() throws {
    let a = UUID(), b = UUID(), c = UUID()
    let maskCycle = Node(id: a, name: "Self", operation: .adjustCoverage(mask: a, strength: 1, inverted: true))
    let disabled = grade(id: b, mask: a, enabled: false)
    XCTAssertThrowsError(try value([maskCycle, disabled], end: .node(b))) { XCTAssertEqual($0 as? Graph.Failure, .cycle(a)) }
    let badImage = grade(id: b, input: .node(a))
    XCTAssertThrowsError(try value([maskCycle, badImage], end: .node(b))) { XCTAssertEqual($0 as? Graph.Failure, .incompatiblePort(a)) }
    let end = Node(id: c, name: "Parallel", operation: .parallel(base: .input, layers: [.init(.node(b), weight: 0)], enabled: false))
    XCTAssertThrowsError(try value([disabled, end], end: .node(c))) { XCTAssertEqual($0 as? Graph.Failure, .missingNode(a)) }
    let inert = grade()
    let graph = try value([inert], end: .node(inert.id))
    XCTAssertThrowsError(try value([inert, grade()], end: .node(inert.id))) { XCTAssertEqual($0 as? Graph.Failure, .disconnectedNodes) }
    XCTAssertThrowsError(try value([inert, inert], end: .node(inert.id))) { XCTAssertEqual($0 as? Graph.Failure, .duplicateID(inert.id)) }
    let encoded = try JSONEncoder().encode(graph)
    var outer = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var scope = try XCTUnwrap(outer["graph"] as? [String: Any]), nodes = try XCTUnwrap(scope["nodes"] as? [[String: Any]])
    var operation = try XCTUnwrap(nodes[0]["operation"] as? [String: Any])
    operation["previewTarget"] = inert.id.uuidString
    nodes[0]["operation"] = operation; scope["nodes"] = nodes; outer["graph"] = scope
    XCTAssertThrowsError(try JSONDecoder().decode(Graph.self, from: JSONSerialization.data(withJSONObject: outer)))
  }

  func testOutsideRequiresCoverageAndAnExplicitSingleImageEdge() throws {
    let mask = Node(name: "Linear", operation: .linearCoverage(start: .zero, end: .init(1, 1)))
    let corrector = grade(mask: mask.id), end = grade(input: .node(corrector.id))
    let original = try value([mask, corrector, end], end: .node(end.id))
    XCTAssertThrowsError(try original.addingOutside(of: corrector.id))
    XCTAssertThrowsError(try original.addingOutside(of: end.id))
    let added = UUID(), maskID = UUID()
    let next = try original.addingOutside(of: corrector.id, before: end.id, correctorID: added, maskID: maskID)
    XCTAssertEqual(next.graph.output, original.graph.output)
    guard case let .corrector(parent, owner, ev, curve, _, _)? = next.graph.nodes.first(where: { $0.id == added })?.operation,
          case let .adjustCoverage(reference, strength, inverted)? = next.graph.nodes.first(where: { $0.id == maskID })?.operation else {
      return XCTFail("Outside did not create a neutral corrector and inverse coverage")
    }
    XCTAssertEqual(parent, .node(corrector.id)); XCTAssertEqual(owner, maskID)
    XCTAssertEqual(ev, 0); XCTAssertTrue(curve.isEmpty)
    XCTAssertTrue(inverted); XCTAssertEqual(strength, 1)
    XCTAssertNotEqual(reference, mask.id)
    XCTAssertEqual(next.graph.nodes.first(where: { $0.id == reference })?.operation, mask.operation)
  }

  func testBudgetsApplyAcrossNestedScopesAndInvalidViewNotPersisted() throws {
    var scope = Graph.Scope(nodes: [], output: .input)
    for _ in 0..<Graph.maximumDepth {
      let group = Node(name: "Nested", operation: .group(image: .input, graph: scope, strength: 1, enabled: true))
      scope = .init(nodes: [group], output: .node(group.id))
    }
    XCTAssertThrowsError(try Graph(graph: scope, output: output())) { XCTAssertEqual($0 as? Graph.Failure, .budget) }
    let corrector = grade()
    let other = Node(name: "Parallel", operation: .parallel(base: .node(corrector.id), layers: [.init(.input, weight: 0.5, mode: .screen)], enabled: true))
    XCTAssertThrowsError(try value([corrector, other], end: .node(other.id))) { XCTAssertEqual($0 as? Graph.Failure, .invalidParameter) }
  }

  func testExplicitEdgesGroupRoundTripAndTemplateInsertionIntoNestedScope() throws {
    let mask = Node(name: "Mask", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let a = grade(mask: mask.id), b = grade(input: .node(a.id))
    let original = try value([a, mask, b], end: .node(b.id)), id = UUID()
    XCTAssertThrowsError(try original.grouping([a.id], id: id)) { XCTAssertEqual($0 as? Graph.Failure, .ambiguousBoundary) }
    let grouped = try original.grouping([a.id, mask.id], id: id)
    XCTAssertEqual(grouped.graph.output, .node(b.id))
    XCTAssertEqual(try grouped.ungrouping(id).graph.output, original.graph.output)
    XCTAssertEqual(try grouped.ungrouping(id).graph.nodes.sorted { $0.id.uuidString < $1.id.uuidString },
      original.graph.nodes.sorted { $0.id.uuidString < $1.id.uuidString })
    XCTAssertThrowsError(try grouped.rewiring(.init(.image(b.id), upstream: .node(a.id)), to: .input)) {
      XCTAssertEqual($0 as? Graph.Failure, .staleEdge)
    }
    XCTAssertThrowsError(try grouped.rewiring(.init(.image(b.id), upstream: .node(id)), to: .node(b.id))) {
      XCTAssertEqual($0 as? Graph.Failure, .cycle(b.id))
    }
    let id2 = UUID(), result = try grouped.insertingTemplate(original, on: .init(.final, upstream: .node(a.id)), at: [id], name: "Template", id: id2)
    guard case let .group(_, scope, _, _)? = result.graph.nodes.first(where: { $0.id == id })?.operation,
          case let .group(input, child, _, _)? = scope.nodes.first(where: { $0.id == id2 })?.operation else { return XCTFail("nested template missing") }
    XCTAssertEqual(scope.output, .node(id2)); XCTAssertEqual(input, .node(a.id)); XCTAssertEqual(result.graph.output, .node(b.id))
    XCTAssertTrue(Set(child.nodes.map(\.id)).isDisjoint(with: Set(original.graph.nodes.map(\.id))))
    XCTAssertEqual(result.output, original.output)
  }

  func testAllInsertionKindsKeepExplicitAnchorAndNeutralWeight() throws {
    let anchor = grade(), source = try value([anchor], end: .node(anchor.id))
    let end = Graph.Edge(.final, upstream: .node(anchor.id))
    let serialID = UUID(), serial = try source.inserting(.serial, on: end, id: serialID)
    XCTAssertEqual(serial.graph.output, .node(serialID))
    for mode in [Graph.Insert.parallel(mixerID: UUID()), .layer(mixerID: UUID())] {
      let newNode = UUID(), output = try source.inserting(mode, on: end, id: newNode)
      let mixer = try XCTUnwrap(output.graph.nodes.last?.operation)
      switch mixer {
      case let .parallel(base, layers, enabled), let .layer(base, layers, enabled):
        XCTAssertTrue(enabled); XCTAssertEqual(base, .node(anchor.id)); XCTAssertEqual(layers, [.init(.node(newNode), weight: 0)])
      default: XCTFail("expected a mixer at the requested edge")
      }
    }
  }

  func testExternalCoverageRoundTripsAsAProviderPort() throws {
    let stage = UUID()
    let mask = Node(name: "Segmentation", operation: .externalCoverage(id: stage))
    let node = grade(mask: mask.id)
    let graph = try value([mask, node], end: .node(node.id))
    XCTAssertTrue(mask.operation.isCoverage)
    XCTAssertEqual(mask.operation.images, [])
    XCTAssertEqual(mask.operation.coverages, [])
    XCTAssertEqual(try JSONDecoder().decode(Graph.self, from: JSONEncoder().encode(graph)), graph)
    let clone = try graph.remapped()
    guard case let .externalCoverage(id) = clone.graph.nodes.first(where: { $0.name == "Segmentation" })?.operation else {
      return XCTFail("external coverage disappeared during remap")
    }
    XCTAssertEqual(id, stage, "provider ids are stage identities, not graph node ids")
    XCTAssertThrowsError(try value([mask, grade(mask: UUID())], end: .node(node.id)))
  }

  private func grade(id: UUID = UUID(), input: Graph.Endpoint = .input, mask: UUID? = nil, enabled: Bool = true) -> Node {
    .init(id: id, name: "Grade", operation: .corrector(image: input, mask: mask, exposureEV: 1,
      curve: [.init(-2, -1.5), .init(2, 2)], strength: 0.75, enabled: enabled))
  }

  private func value(_ nodes: [Node], end: Graph.Endpoint) throws -> Graph { try .init(graph: .init(nodes: nodes, output: end), output: output()) }
  private func output() throws -> DevelopmentSceneOutputStateV1.Version {
    .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
  }
}
