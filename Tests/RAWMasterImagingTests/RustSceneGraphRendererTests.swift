import Foundation
import Metal
import RAWMasterCore
import RAWMasterImage
import XCTest
@testable import RAWMasterImaging

/// Shadow verification for the Rust scene backend. The Swift Metal executor is the reference;
/// these tests use the same public graph and compare the rendered surfaces pixel by pixel.
final class RustSceneGraphRendererTests: XCTestCase {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Node = Graph.Node
  typealias Renderer = DevelopmentSceneGraphRendererV1
  typealias Image = DevelopmentSceneMetalV1.Image

  func testRustShadowMatchesSwiftForCoverageGroupsAndMixers() throws {
    let (device, _, raw, geometry, samples) = try fixture(width: 24, height: 12)
    let gradient = Node(name: "Gradient", operation: .linearCoverage(start: .init(0.1, 0.2), end: .init(0.9, 0.8)))
    let radial = Node(name: "Radial", operation: .radialCoverage(center: .init(0.55, 0.4), radii: .init(0.35, 0.7), feather: 0.25))
    let intersect = Node(name: "Intersect", operation: .combineCoverage(base: gradient.id, other: radial.id, mode: .intersect))
    let subtract = Node(name: "Subtract", operation: .combineCoverage(base: intersect.id, other: radial.id, mode: .subtract))
    let inverted = Node(name: "Inverted", operation: .adjustCoverage(mask: subtract.id, strength: 0.75, inverted: true))
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: nil, exposureEV: 1.25,
      curve: [.init(-4, -3), .init(0, 0), .init(2, 1.5)], strength: 0.8, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .input, mask: nil, exposureEV: -1, curve: [], strength: 1, enabled: true))
    let parallel = Node(name: "Parallel", operation: .parallel(base: .node(dark.id),
      layers: [.init(.node(light.id), weight: 0.3)], enabled: true))
    let multiply = Node(name: "Multiply", operation: .corrector(image: .node(parallel.id), mask: nil, exposureEV: 0.5, curve: [], strength: 1, enabled: true))
    let layer = Node(name: "Ordered", operation: .layer(base: .node(parallel.id), layers: [
      .init(.node(multiply.id), weight: 0.6, mode: .multiply),
      .init(.node(dark.id), weight: 0.4, mode: .softLight),
      .init(.node(light.id), weight: 0.2, mode: .color)
    ], enabled: true))
    let childLight = Node(name: "Group child light", operation: .corrector(image: .input, mask: inverted.id,
      exposureEV: 1.25, curve: [.init(-4, -3), .init(0, 0), .init(2, 1.5)], strength: 0.8, enabled: true))
    let child = Node(name: "Group child", operation: .layer(base: .input, layers: [
      .init(.node(childLight.id), weight: 0.5, mode: .overlay)
    ], enabled: true))
    let group = Node(name: "Group", operation: .group(image: .node(layer.id), graph: .init(nodes: [
      gradient, radial, intersect, subtract, inverted, childLight, child
    ], output: .node(child.id)), strength: 0.6, enabled: true))
    let nodes = [light, dark, parallel, multiply, layer, group]
    let graph = try workflow(nodes, final: group)

    let swift = try Renderer(device: device, backend: .swift)
    let rust = try rustRenderer(device)
    let expected = try read(swift.prepareFinal(raw, geometry: geometry, graph: graph).image.texture)
    let actual = try read(rust.prepareFinal(raw, geometry: geometry, graph: graph).image.texture)
    try compare(actual, expected, tolerance: 3e-5, message: "coverage group mixed graph")
    XCTAssertEqual(actual.map(\.w), samples.map(\.w))
    XCTAssertFalse(actual.isEmpty)
  }

  func testRustShadowMatchesAllThirteenBlendModes() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 12, height: 7)
    let swift = try Renderer(device: device, backend: .swift), rust = try rustRenderer(device)
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: nil, exposureEV: 1, curve: [], strength: 1, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .input, mask: nil, exposureEV: -1, curve: [], strength: 1, enabled: true))
    for mode in Graph.Blend.allCases {
      let layer = Node(name: mode.rawValue, operation: .layer(base: .node(dark.id),
        layers: [.init(.node(light.id), weight: 0.375, mode: mode)], enabled: true))
      let graph = try workflow([light, dark, layer], final: layer)
      let expected = try read(swift.prepareFinal(raw, geometry: geometry, graph: graph).image.texture)
      let actual = try read(rust.prepareFinal(raw, geometry: geometry, graph: graph).image.texture)
      try compare(actual, expected, tolerance: 2e-5, message: "blend \(mode)")
    }
  }

  func testRustShadowMatchesNodeBypassAndROI() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 20, height: 10)
    let gradient = Node(name: "Gradient", operation: .linearCoverage(start: .init(0, 0), end: .init(1, 1)))
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: gradient.id, exposureEV: 2, curve: [], strength: 1, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .node(light.id), mask: nil, exposureEV: -0.5, curve: [], strength: 1, enabled: true))
    let graph = try workflow([gradient, light, dark], final: dark)
    let swift = try Renderer(device: device, backend: .swift), rust = try rustRenderer(device)

    for view in [Graph.View(), .init(target: .node(dark.id)), .init(target: .node(light.id)), .init(target: .bypass)] {
      let expected = try read(swift.preparePreview(raw, geometry: geometry, graph: graph, view: view).image.texture)
      let actual = try read(rust.preparePreview(raw, geometry: geometry, graph: graph, view: view).image.texture)
      try compare(actual, expected, tolerance: 2e-5, message: "view \(view.target)")
    }

    // ROI: coverage must use full-frame coordinates while color work is limited to the window.
    let roiImage = try upload(Array(repeating: SIMD4<Float>(0.2, 0.4, 0.8, 1), count: 7 * 5),
      width: 7, origin: .init(4, 3), device: device)
    let expected = try read(swift.prepareFinal(roiImage, geometry: geometry, graph: graph).image.texture)
    let actual = try read(rust.prepareFinal(roiImage, geometry: geometry, graph: graph).image.texture)
    XCTAssertEqual(actual.count, expected.count)
    try compare(actual, expected, tolerance: 2e-5, message: "ROI with full-frame coverage")
  }

  func testNestedGroupMonitorsUseRequestedBackendAndKeepFrozenFinal() throws {
    let (device, _, image, geometry, _) = try fixture(width: 24, height: 12)
    func grade(_ name: String, _ image: Graph.Endpoint, ev: Float, mask: UUID? = nil) -> Node {
      Node(name: name, operation: .corrector(image: image, mask: mask, exposureEV: ev, curve: [], strength: 1, enabled: true))
    }
    let sourceGrade = grade("Source", .input, ev: 0.5)
    let outerGrade = grade("Outer prefix", .input, ev: 1)
    let mask = Node(name: "Ramp", operation: .linearCoverage(start: .zero, end: .init(1, 1)))
    let inside = grade("Inside", .input, ev: -1.5, mask: mask.id)
    let tail = grade("Inside final", .node(inside.id), ev: 0.25)
    let inner = Node(name: "Inner", operation: .group(image: .node(outerGrade.id),
      graph: .init(nodes: [inside, mask, tail], output: .node(tail.id)), strength: 0.25, enabled: true))
    let outer = Node(name: "Disabled outer", operation: .group(image: .node(sourceGrade.id),
      graph: .init(nodes: [outerGrade, inner], output: .node(inner.id)), strength: 0.5, enabled: false))
    let graph = try workflow([sourceGrade, outer], final: outer)
    let path = [outer.id, inner.id]
    let swift = try Renderer(device: device, backend: .swift), rust = try rustRenderer(device)
    let final = try read(rust.prepareFinal(image, geometry: geometry, graph: graph, sourceRevision: 11).image.texture)
    let region = try upload(Array(repeating: SIMD4<Float>(-0.2, 0.4, 1.7, 0.5), count: 7 * 5),
      width: 7, origin: .init(4, 3), device: device)
    for (revision, input) in [image, region].enumerated() {
      for target in [Graph.View.Target.bypass, .node(inside.id), .final] {
        let view = Graph.View(groupPath: path, target: target)
        let expected = try swift.preparePreview(input, geometry: geometry, graph: graph, view: view)
        let actual = try rust.preparePreview(input, geometry: geometry, graph: graph, view: view,
          sourceRevision: UInt64(11 + revision))
        XCTAssertEqual(swift.lastReceipt?.backend, .swift)
        XCTAssertEqual(rust.lastReceipt?.backend, .rust)
        let pixels = try read(actual.image.texture)
        try compare(pixels, read(expected.image.texture), tolerance: 2e-5, message: "nested \(target)")
        if revision == 0 { XCTAssertNotEqual(pixels, final) }
      }
    }
    let restored = try rust.prepareFinal(image, geometry: geometry, graph: graph, sourceRevision: 11)
    XCTAssertEqual(try read(restored.image.texture), final)
    let bypass = try rust.preparePreview(image, geometry: geometry, graph: graph, view: .init(target: .bypass))
    XCTAssertTrue(bypass.image.texture === image.texture)
    XCTAssertEqual(rust.lastReceipt?.backend, .passthrough)
    XCTAssertEqual(rust.lastReceipt?.dispatches, 0)
    for view in [Graph.View(groupPath: path, target: .node(mask.id)), .init(groupPath: [inner.id])] {
      XCTAssertThrowsError(try rust.preparePreview(image, geometry: geometry, graph: graph, view: view))
      XCTAssertNil(rust.lastReceipt)
    }
  }

  func testRustRejectsMalformedGraphsAndCoveragePreview() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 4, height: 4)
    XCTAssertThrowsError(try RAWMasterImageKernel.SceneProgram(graph: Data("{".utf8), device: device))
    let coverage = Node(name: "Coverage", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let grade = Node(name: "Grade", operation: .corrector(image: .input, mask: coverage.id, exposureEV: 1, curve: [], strength: 1, enabled: true))
    let graph = try workflow([coverage, grade], final: grade)
    let rust = try rustRenderer(device)
    XCTAssertThrowsError(try rust.preparePreview(raw, geometry: geometry, graph: graph, view: .init(target: .node(coverage.id)))) {
      guard case Graph.Failure.unknownNode(let id)? = $0 as? Graph.Failure else {
        return XCTFail("expected unknownNode, got \($0)")
      }
      XCTAssertEqual(id, coverage.id)
    }
  }

  func testRustHonorsTheSurfaceBudget() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 16, height: 8)
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: nil, exposureEV: 1, curve: [], strength: 1, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .node(light.id), mask: nil, exposureEV: -1, curve: [], strength: 1, enabled: true))
    let mix = Node(name: "Mix", operation: .layer(base: .node(dark.id), layers: [
      .init(.node(light.id), weight: 0.5, mode: .screen)
    ], enabled: true))
    let graph = try workflow([light, dark, mix], final: mix)
    let bytes = raw.texture.width * raw.texture.height * 16
    let tight = try Renderer(device: device, surfaceBudget: bytes + bytes / 2, backend: .rust)
    XCTAssertThrowsError(try tight.prepareFinal(raw, geometry: geometry, graph: graph)) {
      XCTAssertEqual($0 as? Renderer.Failure, .surfaceBudget)
    }
    let roomy = try Renderer(device: device, surfaceBudget: 32 * 1024 * 1024, backend: .rust)
    _ = try roomy.prepareFinal(raw, geometry: geometry, graph: graph)
  }

  func testRustBypassDoesNotAllocateWhenTheGraphIsTheInput() throws {
    let (device, _, raw, geometry, samples) = try fixture(width: 8, height: 4)
    let rust = try rustRenderer(device)
    let empty = try Graph(graph: .init(nodes: [], output: .input),
      output: .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
    let rendered = try rust.prepareFinal(raw, geometry: geometry, graph: empty)
    XCTAssertTrue(rendered.image.texture === raw.texture)
    XCTAssertEqual(try read(rendered.image.texture), samples)
  }

  func testRustOutputFlowsThroughACESDeliveryAndEDRViewing() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 20, height: 12)
    let gradient = Node(name: "Ramp", operation: .linearCoverage(start: .zero, end: .init(1, 1)))
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: gradient.id, exposureEV: 2, curve: [], strength: 1, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .input, mask: nil, exposureEV: -0.5, curve: [], strength: 1, enabled: true))
    let mix = Node(name: "Mix", operation: .layer(base: .node(light.id), layers: [
      .init(.node(dark.id), weight: 0.4, mode: .softLight)
    ], enabled: true))
    let graph = try workflow([gradient, light, dark, mix], final: mix)
    let swift = try Renderer(device: device, backend: .swift), rust = try rustRenderer(device)
    let swiftMaster = try swift.prepareFinal(raw, geometry: geometry, graph: graph)
    let rustMaster = try rust.prepareFinal(raw, geometry: geometry, graph: graph)
    for target in [DevelopmentSceneOutputStateV1.Target.sdr709, .hdr2020] {
      let expected = try swift.renderDelivery(swiftMaster, target: target)
      let actual = try rust.renderDelivery(rustMaster, target: target)
      XCTAssertEqual(actual.target, target)
      XCTAssertEqual(actual.texture.storageMode, .private, "delivery stays on the GPU")
      try compare(try read(actual.texture), try read(expected.texture), tolerance: 5e-5,
        message: "ACES delivery \(target.rawValue)")
    }
    let viewing = try DevelopmentSceneOutputStateV1.ViewingConditions(requested: .hdrTarget,
      currentHeadroom: 1.5, displayProfileSHA256: String(repeating: "b", count: 64))
    let expected = try swift.renderPreview(raw, geometry: geometry, graph: graph, view: .init(),
      viewing: viewing)
    let actual = try rust.renderPreview(raw, geometry: geometry, graph: graph, view: .init(),
      viewing: viewing)
    XCTAssertEqual(actual.target, .hdr2020)
    XCTAssertEqual(actual.texture.storageMode, .private)
    try compare(try read(actual.texture), try read(expected.texture), tolerance: 5e-5,
      message: "EDR preview")
  }

  func testTiledExecutionMatchesUntiledAndReportsReceipt() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 256, height: 192)
    let gradient = Node(name: "Ramp", operation: .linearCoverage(start: .zero, end: .init(1, 1)))
    let radial = Node(name: "Ellipse", operation: .radialCoverage(center: .init(0.5, 0.5), radii: .init(0.4, 0.6), feather: 0.2))
    let mask = Node(name: "Mask", operation: .combineCoverage(base: gradient.id, other: radial.id, mode: .intersect))
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: mask.id, exposureEV: 1.2,
      curve: [.init(-4, -3.5), .init(0, 0), .init(3, 2)], strength: 0.8, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .input, mask: nil, exposureEV: -0.7, curve: [], strength: 1, enabled: true))
    let mix = Node(name: "Mix", operation: .parallel(base: .input, layers: [
      .init(.node(light.id), weight: 0.65), .init(.node(dark.id), weight: 0.35)
    ], enabled: true))
    let child = Node(name: "Group child", operation: .corrector(image: .input, mask: nil,
      exposureEV: 0.35, curve: [], strength: 1, enabled: true))
    let group = Node(name: "Group", operation: .group(image: .node(mix.id),
      graph: .init(nodes: [child], output: .node(child.id)), strength: 0.8, enabled: true))
    let graph = try workflow([gradient, radial, mask, light, dark, mix, group], final: group)
    let rust = try rustRenderer(device)
    let untiled = try rust.prepareFinal(raw, geometry: geometry, graph: graph, tileEdge: 0)
    XCTAssertEqual(rust.lastReceipt?.tiles, 1)
    XCTAssertEqual(rust.lastReceipt?.backend, .rust)
    let expected = try read(untiled.image.texture)
    let tiled = try rust.prepareFinal(raw, geometry: geometry, graph: graph, tileEdge: 64)
    let receipt = try XCTUnwrap(rust.lastReceipt)
    XCTAssertEqual(receipt.tiles, 12)
    XCTAssertEqual(receipt.backend, .rust)
    XCTAssertGreaterThan(receipt.dispatches, receipt.tiles)
    try compare(try read(tiled.image.texture), expected, tolerance: 0, message: "tiled vs untiled")
  }

  func testSourceRevisionCacheReusesUnchangedPrefixAfterParameterEdit() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 96, height: 64)
    let mask = Node(name: "Ramp", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let prefix = Node(name: "Prefix", operation: .corrector(image: .input, mask: mask.id,
      exposureEV: 0.75, curve: [], strength: 1, enabled: true))
    let suffix = Node(name: "Suffix", operation: .corrector(image: .node(prefix.id), mask: nil,
      exposureEV: 0.25, curve: [], strength: 1, enabled: true))
    let first = try workflow([mask, prefix, suffix], final: suffix)
    var editedSuffix = suffix
    editedSuffix = Node(id: suffix.id, name: suffix.name, operation: .corrector(image: .node(prefix.id),
      mask: nil, exposureEV: 1.5, curve: [], strength: 0.5, enabled: true))
    let second = try workflow([mask, prefix, editedSuffix], final: editedSuffix)
    let rust = try rustRenderer(device)
    _ = try rust.prepareFinal(raw, geometry: geometry, graph: first, sourceRevision: 41)
    XCTAssertEqual(rust.lastReceipt?.nodeCacheHits, 0)
    _ = try rust.prepareFinal(raw, geometry: geometry, graph: second, sourceRevision: 41)
    XCTAssertGreaterThan(rust.lastReceipt?.nodeCacheHits ?? 0, 0, "unchanged prefix should be reused")
    _ = try rust.prepareFinal(raw, geometry: geometry, graph: second, sourceRevision: 42)
    XCTAssertEqual(rust.lastReceipt?.nodeCacheHits, 0, "a new source revision invalidates color prefixes")
    XCTAssertGreaterThan(rust.lastReceipt?.coverageCacheHits ?? 0, 0, "analytic coverage survives source revisions")
  }

  func testCoverageCacheInvalidatesWhenMaskParametersChange() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 80, height: 48)
    let mask = Node(name: "Ramp", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let grade = Node(name: "Grade", operation: .corrector(image: .input, mask: mask.id,
      exposureEV: 1, curve: [], strength: 1, enabled: true))
    let first = try workflow([mask, grade], final: grade)
    let changedMask = Node(id: mask.id, name: mask.name, operation: .linearCoverage(start: .zero, end: .init(0.2, 0)))
    let second = try workflow([changedMask, grade], final: grade)
    let rust = try rustRenderer(device)
    _ = try rust.prepareFinal(raw, geometry: geometry, graph: first)
    _ = try rust.prepareFinal(raw, geometry: geometry, graph: first)
    XCTAssertGreaterThan(rust.lastReceipt?.coverageCacheHits ?? 0, 0)
    let cached = try read(rust.prepareFinal(raw, geometry: geometry, graph: second).image.texture)
    XCTAssertEqual(rust.lastReceipt?.coverageCacheHits, 0, "changed mask parameters must not reuse the old coverage")
    let fresh = try read(try rustRenderer(device).prepareFinal(raw, geometry: geometry, graph: second).image.texture)
    try compare(cached, fresh, tolerance: 0, message: "changed mask coverage")
  }

  func testReturnedAndCallerOwnedSurfacesPreserveSourceAndExternalCoverage() throws {
    let (device, _, raw, _, source) = try fixture(width: 12, height: 8)
    let stageID = UUID(), mask = Node(name: "Mask", operation: .externalCoverage(id: stageID))
    let grade = Node(name: "Light", operation: .corrector(image: .input, mask: mask.id,
      exposureEV: 1, curve: [], strength: 1, enabled: true))
    struct Document: Encodable {
      let schemaVersion = 1
      let graph: Graph.Scope
    }
    let document = try workflow([mask, grade], final: grade)
    let program = try RAWMasterImageKernel.SceneProgram(graph: JSONEncoder().encode(Document(graph: document.graph)), device: device)
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 12, height: 8, mipmapped: false)
      descriptor.usage = [.shaderRead, .shaderWrite]
      descriptor.storageMode = .shared
      return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
    let output = try texture(.rgba32Float)
    try program.render(input: raw.texture, output: output, view: .bypass)
    XCTAssertEqual(try read(output), source)
    let alias = try program.renderSurface(input: raw.texture, view: .bypass, surfaceBudget: raw.texture.allocatedSize)
    XCTAssertTrue(alias === raw.texture)
    let coverage = try texture(.r32Float)
    let values = (0..<(12 * 8)).map { $0 % 2 == 0 ? Float(0) : Float(1) }
    values.withUnsafeBytes { bytes in
      coverage.replace(region: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: 12 * MemoryLayout<Float>.stride)
    }
    try program.render(input: raw.texture, output: output, coverages: [stageID: coverage])
    let rendered = try program.renderSurface(input: raw.texture, coverages: [stageID: coverage])
    let pixels = try read(rendered)
    XCTAssertEqual(pixels, try read(output))
    XCTAssertEqual(pixels[0], .zero, "The corrector canonicalizes fully transparent pixels")
    XCTAssertEqual(pixels[2], source[2], "A visible pixel with zero coverage keeps its channels")
    XCTAssertNotEqual(pixels[1], source[1])
    XCTAssertEqual(try read(raw.texture), source)
    XCTAssertThrowsError(try program.renderSurface(input: raw.texture, revision: 13, isCurrent: { _ in false })) { error in
      guard case RAWMasterImageKernel.Failure.staleFrame = error else { return XCTFail("Unexpected error \(error)") }
    }
  }

  func testAutoFallbackCarriesAReceiptAndReason() throws {
    let (device, _, raw, geometry, _) = try fixture(width: 128, height: 64)
    let brighter = Node(name: "Bright", operation: .corrector(image: .input, mask: nil,
      exposureEV: 1, curve: [], strength: 1, enabled: true))
    let graph = try workflow([brighter], final: brighter)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: 128, height: 64, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    // The Swift single-pass graph fits. Forcing two Rust tiles also needs their assembly destination.
    let budget = raw.texture.allocatedSize + device.heapTextureSizeAndAlign(descriptor: descriptor).size
    let renderer = try Renderer(device: device, surfaceBudget: budget, backend: .auto)
    let rendered = try renderer.prepareFinal(raw, geometry: geometry, graph: graph, tileEdge: 64)
    let receipt = try XCTUnwrap(renderer.lastReceipt)
    XCTAssertEqual(receipt.backend, .swiftFallback)
    XCTAssertEqual(receipt.fallbackReason, String(describing: Renderer.Failure.surfaceBudget))
    let expected = try Renderer(device: device, surfaceBudget: budget, backend: .swift)
      .prepareFinal(raw, geometry: geometry, graph: graph)
    XCTAssertEqual(try read(rendered.image.texture), try read(expected.image.texture))
  }

  func testOptIn60MegapixelSceneBudgetAndReceipt() throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_60MP_PERFORMANCE"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_60MP_PERFORMANCE to a new JSON report path")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let width = 9_600, height = 6_400
    let geometry = Renderer.Geometry(width: width, height: height)
    let raw = try makeGenerated(width: width, height: height, device: device)
    let gradient = Node(name: "Ramp", operation: .linearCoverage(start: .init(0.1, 0), end: .init(0.9, 1)))
    let radial = Node(name: "Ellipse", operation: .radialCoverage(center: .init(0.5, 0.5), radii: .init(0.4, 0.6), feather: 0.2))
    let mask = Node(name: "Mask", operation: .combineCoverage(base: gradient.id, other: radial.id, mode: .intersect))
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: mask.id, exposureEV: 1.2,
      curve: [.init(-4, -3.5), .init(0, 0), .init(3, 2)], strength: 0.8, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .input, mask: nil, exposureEV: -0.7, curve: [], strength: 1, enabled: true))
    let mix = Node(name: "Mix", operation: .parallel(base: .input, layers: [
      .init(.node(light.id), weight: 0.65), .init(.node(dark.id), weight: 0.35)
    ], enabled: true))
    let graph = try workflow([gradient, radial, mask, light, dark, mix], final: mix)
    let budget = 6 * 1024 * 1024 * 1024
    let renderer = try Renderer(device: device, surfaceBudget: budget, backend: .rust)
    func timed(_ body: () throws -> Void) rethrows -> Double {
      let start = DispatchTime.now().uptimeNanoseconds
      try body()
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    var master: Renderer.Master?
    let cold = try timed { master = try renderer.prepareFinal(raw, geometry: geometry, graph: graph) }
    let coldReceipt = try XCTUnwrap(renderer.lastReceipt)
    XCTAssertEqual(coldReceipt.backend, .rust)
    XCTAssertGreaterThan(coldReceipt.tiles, 1)
    XCTAssertLessThanOrEqual(Int(coldReceipt.peakBytes), budget)
    let warm = try timed { _ = try renderer.prepareFinal(raw, geometry: geometry, graph: graph) }
    let warmReceipt = try XCTUnwrap(renderer.lastReceipt)
    XCTAssertEqual(warmReceipt.backend, .rust)
    XCTAssertGreaterThan(warmReceipt.tiles, 1)
    XCTAssertLessThanOrEqual(Int(warmReceipt.peakBytes), budget)
    let final = try XCTUnwrap(master)
    XCTAssertEqual(final.image.texture.width, width)
    XCTAssertEqual(final.image.texture.height, height)
    let sdrMs = try timed {
      try autoreleasepool {
        let display = try renderer.renderDelivery(final, target: .sdr709)
        XCTAssertEqual(display.texture.storageMode, .private)
        let pixel = try sample(display.texture, x: width / 2, y: height / 2)
        XCTAssertTrue(pixel.x.isFinite && pixel.y.isFinite && pixel.z.isFinite)
      }
    }
    let hdrMs = try timed {
      try autoreleasepool {
        let display = try renderer.renderDelivery(final, target: .hdr2020)
        XCTAssertEqual(display.texture.storageMode, .private)
        let pixel = try sample(display.texture, x: width / 2, y: height / 2)
        XCTAssertTrue(pixel.x.isFinite && pixel.y.isFinite && pixel.z.isFinite)
      }
    }
    let report: [String: Any] = [
      "device": device.name, "resolution": [width, height], "budgetBytes": budget,
      "scope": "six-node AP1 graph on a generated 60MP source; includes ACES SDR/HDR delivery",
      "graphColdMs": cold, "graphWarmMs": warm, "sdrDeliveryMs": sdrMs, "hdrDeliveryMs": hdrMs,
      "tiles": coldReceipt.tiles, "dispatches": coldReceipt.dispatches,
      "peakBytes": coldReceipt.peakBytes, "warmCoverageCacheHits": warmReceipt.coverageCacheHits,
      "warmDispatches": warmReceipt.dispatches
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
    XCTAssertLessThan(cold, 15_000)
    XCTAssertLessThan(warm, 15_000)
  }

  func testOptInRustBackendPerformance() throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND_PERFORMANCE"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_BACKEND_PERFORMANCE to a new JSON report path")
    }
    let (device, _, raw, geometry, _) = try fixture(width: 3000, height: 2000)
    let gradient = Node(name: "Ramp", operation: .linearCoverage(start: .init(0.1, 0), end: .init(0.9, 1)))
    let radial = Node(name: "Ellipse", operation: .radialCoverage(center: .init(0.5, 0.5), radii: .init(0.4, 0.6), feather: 0.2))
    let mask = Node(name: "Mask", operation: .combineCoverage(base: gradient.id, other: radial.id, mode: .intersect))
    let light = Node(name: "Light", operation: .corrector(image: .input, mask: mask.id, exposureEV: 1.2,
      curve: [.init(-4, -3.5), .init(0, 0), .init(3, 2)], strength: 0.8, enabled: true))
    let dark = Node(name: "Dark", operation: .corrector(image: .input, mask: nil, exposureEV: -0.7, curve: [], strength: 1, enabled: true))
    let mix = Node(name: "Mix", operation: .parallel(base: .input, layers: [
      .init(.node(light.id), weight: 0.65), .init(.node(dark.id), weight: 0.35)
    ], enabled: true))
    let graph = try workflow([gradient, radial, mask, light, dark, mix], final: mix)
    let swift = try Renderer(device: device, backend: .swift), rust = try rustRenderer(device)
    let warmups = 5, measuredSamples = 30
    func measure(_ renderer: Renderer) throws -> [Double] {
      for _ in 0..<warmups { _ = try renderer.prepareFinal(raw, geometry: geometry, graph: graph) }
      return try (0..<measuredSamples).map { _ in
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try renderer.prepareFinal(raw, geometry: geometry, graph: graph)
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
      }
    }
    let rustColdStart = DispatchTime.now().uptimeNanoseconds
    _ = try rust.prepareFinal(raw, geometry: geometry, graph: graph)
    let rustColdMs = Double(DispatchTime.now().uptimeNanoseconds - rustColdStart) / 1e6
    let swiftSamples = try measure(swift), rustSamples = try measure(rust)
    func median(_ values: [Double]) -> Double {
      let ordered = values.sorted()
      return (ordered[(ordered.count - 1) / 2] + ordered[ordered.count / 2]) / 2
    }
    func p95(_ values: [Double]) -> Double {
      values.sorted()[Int((Double(values.count) * 0.95).rounded(.up)) - 1]
    }
    let report: [String: Any] = [
      "device": device.name, "resolution": [geometry.width, geometry.height],
      "scope": "six-node AP1 graph with two coverage nodes and a two-branch parallel mix; excluding RAW, DRT and UI",
      "warmups": warmups, "measuredSamples": measuredSamples,
      "swiftMs": swiftSamples, "rustMs": rustSamples, "rustColdMs": rustColdMs,
      "swiftP50": median(swiftSamples), "swiftP95": p95(swiftSamples),
      "rustP50": median(rustSamples), "rustP95": p95(rustSamples)
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
    XCTAssertLessThanOrEqual(p95(rustSamples), p95(swiftSamples) * 1.2,
      "Rust backend must stay within 20% of the Swift executor at 6MP")
  }

  // MARK: - Helpers

  private func rustRenderer(_ device: MTLDevice) throws -> Renderer {
    try Renderer(device: device, backend: .rust)
  }

  private func fixture(width: Int, height: Int) throws -> (MTLDevice, Renderer, Image, Renderer.Geometry, [SIMD4<Float>]) {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let samples = (0..<(width * height)).map { index -> SIMD4<Float> in
      let x = Float(index % width) / Float(width), y = Float(index / width) / Float(height)
      let alpha: Float = index % 7 == 0 ? 0 : (index % 5 == 0 ? 0.5 : 1)
      return .init(0.05 + 0.9 * x - 0.125 * y, 1.2 * y - 0.03125, -0.015625 + 0.4 * x * y, alpha)
    }
    let raw = try upload(samples, width: width, device: device)
    return (device, try Renderer(device: device), raw, .init(width: width, height: height), samples)
  }

  private func workflow(_ nodes: [Node], final: Node) throws -> Graph {
    try .init(graph: .init(nodes: nodes, output: .node(final.id)),
      output: .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
  }

  private func upload(_ samples: [SIMD4<Float>], width: Int, origin: SIMD2<Int> = .zero, device: MTLDevice) throws -> Image {
    let height = samples.count / width
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    samples.withUnsafeBytes {
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: width * 16)
    }
    return .init(texture: texture, port: .working, origin: origin)
  }

  private func makeGenerated(width: Int, height: Int, device: MTLDevice) throws -> Image {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let library = try device.makeLibrary(source: Self.fillShader, options: nil)
    let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "rmTestFill")))
    let queue = try XCTUnwrap(device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    let lanes = pipeline.threadExecutionWidth
    encoder.dispatchThreads(.init(width: width, height: height, depth: 1),
      threadsPerThreadgroup: .init(width: lanes,
        height: min(8, pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw Renderer.Failure.invalidPixel }
    return .init(texture: texture, port: .working, origin: .zero)
  }

  private func sample(_ texture: MTLTexture, x: Int, y: Int) throws -> SIMD4<Float> {
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: 16, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
    encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
      sourceOrigin: .init(x: x, y: y, z: 0), sourceSize: .init(width: 1, height: 1, depth: 1),
      to: buffer, destinationOffset: 0, destinationBytesPerRow: 16, destinationBytesPerImage: 16)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw Renderer.Failure.invalidPixel }
    return buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self).pointee
  }

  private static let fillShader = #"""
  #include <metal_stdlib>
  using namespace metal;
  kernel void rmTestFill(texture2d<float, access::write> target [[texture(0)]],
      uint2 xy [[thread_position_in_grid]]) {
    float2 p = (float2(xy) + 0.5) / float2(target.get_width(), target.get_height());
    target.write(float4(0.05 + 0.8 * p.x, 0.1 + 0.7 * p.y, 0.2 + 0.5 * p.x * p.y, 1), xy);
  }
  """#

  private func read(_ texture: MTLTexture) throws -> [SIMD4<Float>] {
    let size = texture.width * texture.height * 16
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: size, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
    encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer,
      destinationOffset: 0, destinationBytesPerRow: texture.width * 16, destinationBytesPerImage: size)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    XCTAssertEqual(command.status, .completed)
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: size / 16))
  }

  private func compare(_ actual: [SIMD4<Float>], _ expected: [SIMD4<Float>], tolerance: Float, message: String) throws {
    XCTAssertEqual(actual.count, expected.count, message)
    for (index, pair) in zip(actual, expected).enumerated() {
      for channel in 0..<4 {
        let value = pair.0[channel], reference = pair.1[channel]
        let scale = max(1, abs(reference))
        XCTAssertEqual(value, reference, accuracy: tolerance * scale, "\(message) pixel \(index) channel \(channel)")
      }
    }
  }
}
