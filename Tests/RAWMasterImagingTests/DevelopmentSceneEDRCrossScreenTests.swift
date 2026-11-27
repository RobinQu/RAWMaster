import AppKit
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

/// Numeric EDR acceptance across real display headroom values and a simulated multi-screen matrix.
/// Physical multi-monitor verification still needs two attached EDR displays; this test records
/// the actual local screens and exercises every distinct headroom path available to the compositor.
final class DevelopmentSceneEDRCrossScreenTests: XCTestCase {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Renderer = DevelopmentSceneGraphRendererV1

  func testHDRDeliveryAcrossActualAndSimulatedDisplayHeadroom() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Renderer(device: device)
    let node = Graph.Node(name: "Neutral", operation: .corrector(image: .input, mask: nil,
      exposureEV: 0, curve: [], strength: 1, enabled: true))
    let graph = try Graph(graph: .init(nodes: [node], output: .node(node.id)),
      output: .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
    let pixels: [SIMD4<Float>] = [
      .init(8, 8, 8, 1), .init(1, 1, 1, 1), .init(0.18, 0.18, 0.18, 1),
      .init(0, 0, 0, 1),
    ]
    let image = try upload(pixels, width: 4, device: device)
    let geometry = Renderer.Geometry(width: 4, height: 1)

    let screens = NSScreen.screens
    let actualHeadroom = screens.map {
      Float(max(1, $0.maximumExtendedDynamicRangeColorComponentValue))
    }
    let potentialHeadroom = screens.map {
      Float(max(1, $0.maximumPotentialExtendedDynamicRangeColorComponentValue))
    }
    var measured: [[String: Any]] = []
    var samples: [(headroom: Float, highlight: Float, middle: Float, target: String)] = []
    for headroom in Set(actualHeadroom + potentialHeadroom + [1, 1.2, 1.5, 2, 4]).sorted() {
      let viewing = try DevelopmentSceneOutputStateV1.ViewingConditions(
        requested: .hdrTarget, currentHeadroom: headroom,
        displayProfileSHA256: String(repeating: "a", count: 64))
      let display = try renderer.renderPreview(image, geometry: geometry, graph: graph,
        view: .init(), viewing: viewing)
      let values = try read(display.texture)
      XCTAssertEqual(display.texture.storageMode, .private)
      XCTAssertTrue(values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
      let highlight = values[0].x, middle = values[2].x
      XCTAssertGreaterThan(highlight, middle, "headroom \(headroom) must preserve the highlight")
      samples.append((headroom, highlight, middle, viewing.displayedTarget.rawValue))
      measured.append([
        "headroom": headroom, "target": viewing.displayedTarget.rawValue,
        "highlight": highlight, "middle": middle,
      ])
    }
    XCTAssertGreaterThanOrEqual(samples.filter { $0.target == "hdr2020" }.count, 1)
    XCTAssertGreaterThanOrEqual(samples.filter { $0.target == "sdr709" }.count, 1)

    let hdr = try renderer.renderDelivery(renderer.prepareFinal(image, geometry: geometry, graph: graph),
      target: .hdr2020)
    let sdr = try renderer.renderDelivery(renderer.prepareFinal(image, geometry: geometry, graph: graph),
      target: .sdr709)
    let hdrHighlight = try read(hdr.texture)[0].x, sdrHighlight = try read(sdr.texture)[0].x
    XCTAssertGreaterThan(hdrHighlight, sdrHighlight)

    let report: [String: Any] = [
      "device": device.name,
      "screens": screens.map { screen -> [String: Any] in
        [
          "name": screen.localizedName,
          "colorSpace": screen.colorSpace?.localizedName ?? "none",
          "currentHeadroom": screen.maximumExtendedDynamicRangeColorComponentValue,
          "potentialHeadroom": screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
          "referenceHeadroom": screen.maximumReferenceExtendedDynamicRangeColorComponentValue,
        ]
      },
      "physicalScreenCount": screens.count,
      "simulatedAndActualHeadrooms": measured,
      "hdrHighlight": hdrHighlight, "sdrHighlight": sdrHighlight,
    ]
    if let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_EDR_REPORT"] {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path), options: [.withoutOverwriting])
    } else {
      print("SCENE EDR REPORT", report)
    }
  }

  private func upload(_ samples: [SIMD4<Float>], width: Int, device: MTLDevice) throws -> DevelopmentSceneMetalV1.Image {
    let height = samples.count / width
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    samples.withUnsafeBytes {
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: width * 16)
    }
    return .init(texture: texture, port: .working, origin: .zero)
  }

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
    guard command.status == .completed else { throw Renderer.Failure.invalidPixel }
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self),
      count: size / 16))
  }
}
