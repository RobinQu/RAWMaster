import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneGraphRendererV1Tests: XCTestCase {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Node = Graph.Node
  typealias Renderer = DevelopmentSceneGraphRendererV1
  typealias Image = DevelopmentSceneMetalV1.Image

  func testAllThirteenLayerModesMatchLinearAP1CPUReferenceIncludingSignedAndSuperwhite() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), renderer = try Renderer(device: device)
    let pixels: [SIMD4<Float>] = [.init(0.36, 0.075, 0.106, 0.5), .init(1.05, -0.03, 0.33, 0.6), .zero]
    let raw = try upload(pixels, width: 3, device: device), geometry = Renderer.Geometry(width: 3, height: 1)
    let light = grade(ev: 1), dark = grade(ev: -1)
    for mode in Graph.Blend.allCases {
      let layer = Node(name: mode.rawValue, operation: .layer(base: .node(dark.id), layers: [.init(.node(light.id), weight: 0.375, mode: mode)], enabled: true))
      let graph = try workflow([layer, light, dark], final: layer)
      let actual = try read(renderer.prepareFinal(raw, geometry: geometry, graph: graph).image.texture)
      for (source, found) in zip(pixels, actual) {
        let alpha = Double(source.w)
        if alpha == 0 { XCTAssertEqual(found, .zero); continue }
        let straight = SIMD3(Double(source.x), Double(source.y), Double(source.z)) / alpha
        let base = straight / 2, branch = straight * 2
        let expected = (base * 0.625 + blend(base, branch, mode: mode) * 0.375) * alpha
        for c in 0..<3 { XCTAssertEqual(Double(found[c]), expected[c], accuracy: 8e-7, "\(mode) channel \(c)") }
        XCTAssertEqual(found.w, source.w)
      }
    }
  }

  func testParallelUsesWeightedChangesAndLayerOrderIsSignificant() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), renderer = try Renderer(device: device)
    let pixel = SIMD4<Float>(0.25, 0.5, -0.125, 1)
    let raw = try upload([pixel], width: 1, device: device), geometry = Renderer.Geometry(width: 1, height: 1)
    let brighter = grade(ev: 2), darker = grade(ev: -1)
    let layers: [Graph.Layer] = [.init(.node(brighter.id), weight: 0.5), .init(.node(darker.id), weight: 0.25)]
    for order in [layers, Array(layers.reversed())] {
      let mix = Node(name: "Parallel", operation: .parallel(base: .input, layers: order, enabled: true))
      let master = try renderer.prepareFinal(raw, geometry: geometry, graph: workflow([darker, mix, brighter], final: mix))
      let gain: Float = 1 + (4 - 1) * 0.5 + (0.5 - 1) * 0.25
      XCTAssertEqual(try read(master.image.texture), [.init(pixel.x * gain, pixel.y * gain, pixel.z * gain, 1)])
    }
    var orderResults: [Float] = []
    for order in [layers, Array(layers.reversed())] {
      let mix = Node(name: "Layer", operation: .layer(base: .input, layers: order, enabled: true))
      let master = try renderer.prepareFinal(raw, geometry: geometry, graph: workflow([darker, mix, brighter], final: mix))
      orderResults.append(try XCTUnwrap(read(master.image.texture).first).x)
    }
    XCTAssertEqual(orderResults, [0.5, 0.609375])
  }

  func testCoverageGroupROIAndMonitoringNeverReplaceDeliveryRoot() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), renderer = try Renderer(device: device)
    let photo = SIMD4<Float>(0.25, 0.12, -0.015625, 0.5)
    let geometry = Renderer.Geometry(width: 8, height: 2)
    let raw = try upload(Array(repeating: photo, count: 16), width: 8, device: device)
    let window = try upload(Array(repeating: photo, count: 3), width: 3, origin: .init(2, 1), device: device)
    let gradient = Node(name: "Half-frame ramp", operation: .linearCoverage(start: .init(0.25, 0), end: .init(0.75, 0)))
    let radial = Node(name: "Ellipse", operation: .radialCoverage(center: .init(0.5, 0.5), radii: .init(0.38, 1), feather: 0))
    let mask = Node(name: "Intersection", operation: .combineCoverage(base: gradient.id, other: radial.id, mode: .intersect))
    let corrector = grade(ev: 2, mask: mask.id, curve: [.init(-4, -3), .init(0, 0), .init(3, 2)])
    let group = Node(name: "Group", operation: .group(image: .input, graph: .init(nodes: [mask, radial, corrector, gradient],
      output: .node(corrector.id)), strength: 0.5, enabled: true))
    let graph = try workflow([group], final: group)
    let final = try renderer.prepareFinal(raw, geometry: geometry, graph: graph)
    let values = try read(final.image.texture)
    XCTAssertEqual(values[0], photo, "zero coverage stays bit-identical")
    XCTAssertGreaterThan(values[4].x, photo.x)
    XCTAssertLessThan(values[4].z, photo.z)
    XCTAssertEqual(values.map(\.w), Array(repeating: photo.w, count: 16))
    let roi = try renderer.prepareFinal(window, geometry: geometry, graph: graph).image
    XCTAssertEqual(roi.origin, .init(2, 1))
    XCTAssertEqual(try read(roi.texture), Array(values[10..<13]))
    let viewing = try DevelopmentSceneOutputStateV1.ViewingConditions(requested: .hdrTarget, currentHeadroom: 1.5,
      displayProfileSHA256: String(repeating: "a", count: 64))
    let nodePreview = try renderer.renderPreview(raw, geometry: geometry, graph: graph,
      view: .init(groupPath: [group.id], target: .node(corrector.id)), viewing: viewing)
    let hdr = try renderer.renderDelivery(final, target: .hdr2020)
    XCTAssertNotEqual(try read(nodePreview.texture), try read(hdr.texture))
    XCTAssertThrowsError(try renderer.renderPreview(raw, geometry: geometry, graph: graph,
      view: .init(target: .node(corrector.id)), viewing: viewing))
    XCTAssertEqual(try read(renderer.renderDelivery(final, target: .hdr2020).texture), try read(hdr.texture))
  }

  func testDisabledBranchesRequireNoRenderBudgetAndLongChainFreesSurfaces() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let raw = try upload(Array(repeating: .init(0.1, 0.1, 0.1, 1), count: 512), width: 32, device: device)
    let geometry = Renderer.Geometry(width: 32, height: 16)
    let budget = raw.texture.allocatedSize, brighter = grade(ev: 7)
    let mix = Node(name: "Parallel", operation: .parallel(base: .input, layers: [.init(.node(brighter.id), weight: 0)], enabled: true))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 32, height: 16, mipmapped: false)
    d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
    let chainBudget = budget + 2 * device.heapTextureSizeAndAlign(descriptor: d).size
    var chain: [Node] = [], edge = Graph.Endpoint.input
    for i in 0..<64 {
      let n = grade(input: edge, ev: i % 2 == 0 ? 1 : -1); chain.append(n); edge = .node(n.id)
    }
    let identity = try workflow([brighter, mix], final: mix)
    let single = try workflow([brighter], final: brighter)
    let sequence = try workflow(chain, final: XCTUnwrap(chain.last))
    let original = try read(raw.texture)
    for backend in [RustSceneGraphRenderer.Mode.swift, .rust] {
      let noAllocation = try Renderer(device: device, surfaceBudget: budget, backend: backend)
      XCTAssertTrue(try noAllocation.prepareFinal(raw, geometry: geometry, graph: identity).image.texture === raw.texture)
      XCTAssertEqual(noAllocation.lastReceipt?.dispatches, 0)
      XCTAssertEqual(noAllocation.lastReceipt?.peakBytes, budget)
      XCTAssertThrowsError(try noAllocation.prepareFinal(raw, geometry: geometry, graph: single)) {
        XCTAssertEqual($0 as? Renderer.Failure, .surfaceBudget)
      }
      let bounded = try Renderer(device: device, surfaceBudget: chainBudget, backend: backend)
      for revision: UInt64 in [0, 1] {
        let final = try bounded.prepareFinal(raw, geometry: geometry, graph: sequence, sourceRevision: revision)
        XCTAssertEqual(try read(final.image.texture), original)
        let receipt = try XCTUnwrap(bounded.lastReceipt)
        XCTAssertEqual(receipt.backend, backend == .rust ? .rust : .swift)
        XCTAssertEqual(receipt.dispatches, 64)
        XCTAssertLessThanOrEqual(receipt.peakBytes, chainBudget)
        if backend == .rust {
          print("scene surface budget · revision \(revision) · input \(budget) B · 64 dispatches · peak \(receipt.peakBytes) / \(chainBudget) B")
        }
      }
    }
  }

  func testOptInGraphSurfacePerformance() throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_GRAPH_PERFORMANCE"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_GRAPH_PERFORMANCE to a new JSON report path")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), renderer = try Renderer(device: device)
    let width = 960, height = 640, raw = try upload(Array(repeating: .init(0.25, 1.2, -0.015625, 1), count: width * height), width: width, device: device)
    let geometry = Renderer.Geometry(width: width, height: height)
    let gradient = Node(name: "Gradient", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let a = grade(ev: 1, mask: gradient.id), b = grade(ev: -0.5)
    let mix = Node(name: "Parallel", operation: .parallel(base: .input, layers: [.init(.node(a.id), weight: 0.7), .init(.node(b.id), weight: 0.3)], enabled: true))
    let graph = try workflow([gradient, a, b, mix], final: mix)
    func run() throws -> Double {
      let start = DispatchTime.now().uptimeNanoseconds
      _ = try renderer.prepareFinal(raw, geometry: geometry, graph: graph)
      return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    var series: [[Double]] = []
    for _ in 0..<2 {
      for _ in 0..<5 { _ = try run() }
      series.append(try (0..<30).map { _ in try run() })
    }
    let p95 = series.map { $0.sorted()[28] }
    let report: [String: Any] = ["device": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "resolution": [width, height], "scope": "joined resident Metal DAG: linear mask, two exposure branches, parallel mix; excluding RAW, DRT and UI",
      "p95GateMs": 20, "samplesMs": series, "p95Ms": p95]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
    for value in p95 { XCTAssertLessThanOrEqual(value, 20) }
  }

  private func grade(input: Graph.Endpoint = .input, ev: Float, mask: UUID? = nil, curve: [SIMD2<Float>] = []) -> Node {
    .init(name: "Exposure", operation: .corrector(image: input, mask: mask, exposureEV: ev, curve: curve, strength: 1, enabled: true))
  }

  private func workflow(_ nodes: [Node], final: Node) throws -> Graph {
    try .init(graph: .init(nodes: nodes, output: .node(final.id)), output: .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
  }

  private func upload(_ samples: [SIMD4<Float>], width: Int, origin: SIMD2<Int> = .zero, device: MTLDevice) throws -> Image {
    let height = samples.count / width
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    d.storageMode = .shared; d.usage = .shaderRead
    let t = try XCTUnwrap(device.makeTexture(descriptor: d))
    samples.withUnsafeBytes {
      t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16)
    }
    return .init(texture: t, port: .working, origin: origin)
  }

  private func read(_ t: MTLTexture) throws -> [SIMD4<Float>] {
    let size = t.width * t.height * 16
    let b = try XCTUnwrap(t.device.makeBuffer(length: size, options: .storageModeShared))
    let queue = try XCTUnwrap(t.device.makeCommandQueue()), cmd = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(cmd.makeBlitCommandEncoder())
    encoder.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: t.width, height: t.height, depth: 1),
      to: b, destinationOffset: 0, destinationBytesPerRow: t.width * 16, destinationBytesPerImage: size)
    encoder.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
    XCTAssertEqual(cmd.status, .completed)
    return Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: size / 16))
  }

  private func blend(_ base: SIMD3<Double>, _ layer: SIMD3<Double>, mode: Graph.Blend) -> SIMD3<Double> {
    let weights = SIMD3<Double>(0.2722287168, 0.6740817658, 0.0536895174)
    let delta = zip([base.x, base.y, base.z], [layer.x, layer.y, layer.z]).enumerated().reduce(0.0) { $0 + ($1.element.0 - $1.element.1) * weights[$1.offset] }
    if mode == .color { return layer + SIMD3(repeating: delta) }
    if mode == .luminosity { return base - SIMD3(repeating: delta) }
    func channel(_ b: Double, _ s: Double) -> Double {
      switch mode {
      case .normal: return s
      case .add: return b + s
      case .subtract: return b - s
      case .multiply: return b * s
      case .lighten: return max(b, s)
      case .darken: return min(b, s)
      case .difference: return abs(b - s)
      case .color, .luminosity: preconditionFailure("vector modes handled above")
      case .screen, .overlay, .softLight, .hardLight:
        let x = max(0, min(1, b)), y = max(0, min(1, s)), z: Double
        if mode == .screen { z = 1 - (1 - x) * (1 - y) }
        else if mode == .softLight {
          let d = x <= 0.25 ? ((16 * x - 12) * x + 4) * x : sqrt(x)
          z = y <= 0.5 ? x - (1 - 2*y)*x*(1-x) : x + (2*y-1)*(d-x)
        } else { z = (mode == .overlay ? x : y) <= 0.5 ? 2*x*y : 1 - 2*(1-x)*(1-y) }
        return z + (b - x) + (s - y)
      }
    }
    return .init(channel(base.x, layer.x), channel(base.y, layer.y), channel(base.z, layer.z))
  }
}
