import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

/// Exercises the production Core Image/MPS/Core ML/Vision adapters on a real photographic asset.
/// These tests intentionally do not use the deterministic stand-in provider.
final class DevelopmentSceneProductionModelProviderTests: XCTestCase {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Node = Graph.Node
  typealias Renderer = DevelopmentSceneGraphRendererV1
  typealias Stage = DevelopmentSceneModelStageV1
  typealias Program = DevelopmentSceneModelProgramV1

  func testRealAssetDenoiseAndSuperResolutionProduceDeterministicAP1Surfaces() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let provider = try DevelopmentSceneProductionModelProvider(device: device)
    let image = try ap1Asset("person", device: device)
    let geometry = Renderer.Geometry(width: image.texture.width, height: image.texture.height)
    let denoised = try provider.render(.denoise(amount: 55), input: image.texture, check: {})
    XCTAssertEqual(denoised.width, image.texture.width)
    XCTAssertEqual(denoised.height, image.texture.height)
    XCTAssertEqual(denoised.pixelFormat, .rgba32Float)
    let original = try readRGBA(image.texture), changed = try readRGBA(denoised)
    XCTAssertEqual(original.count, changed.count)
    let difference = zip(original, changed).reduce(Float(0)) { value, pair in
      value + abs(pair.0.x - pair.1.x) + abs(pair.0.y - pair.1.y) + abs(pair.0.z - pair.1.z)
    }
    XCTAssertGreaterThan(difference, 1, "the real denoiser must change the photograph")
    XCTAssertTrue(changed.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    XCTAssertEqual(geometry.width, changed.count > 0 ? image.texture.width : 0)

    let scaled = try provider.render(.superResolution(), input: image.texture, check: {})
    XCTAssertEqual(scaled.width, image.texture.width * 2)
    XCTAssertEqual(scaled.height, image.texture.height * 2)
    XCTAssertEqual(scaled.pixelFormat, .rgba32Float)
    let scaledPixels = try readRGBA(scaled)
    XCTAssertEqual(scaledPixels.count, scaled.width * scaled.height)
    XCTAssertTrue(scaledPixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
  }

  func testVisionSegmentationFeedsARealSceneGraphMask() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let provider = try DevelopmentSceneProductionModelProvider(device: device)
    let image = try ap1Asset("person", device: device)
    let geometry = Renderer.Geometry(width: image.texture.width, height: image.texture.height)
    let subject = Stage.segmentation(.subject)
    let people = Stage.segmentation(.people)
    for stage in [subject, people] {
      let mask = try provider.render(stage, input: image.texture, check: {})
      XCTAssertEqual(mask.width, image.texture.width)
      XCTAssertEqual(mask.height, image.texture.height)
      XCTAssertEqual(mask.pixelFormat, .r32Float)
      let values = try readMask(mask)
      XCTAssertEqual(values.count, mask.width * mask.height)
      XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
      XCTAssertGreaterThan(values.max() ?? 0, 0.5, "Vision should find the photographed person")
    }

    let program = try Program(stages: [.denoise(amount: 40), .superResolution(), subject])
    let maskNode = Node(name: "Person", operation: .externalCoverage(id: subject.id))
    let grade = Node(name: "Masked grade", operation: .corrector(image: .input, mask: maskNode.id,
      exposureEV: 0.75, curve: [], strength: 0.8, enabled: true))
    let graph = try Graph(graph: .init(nodes: [maskNode, grade], output: .node(grade.id)),
      output: .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
    let renderer = try Renderer(device: device, surfaceBudget: 512 * 1024 * 1024)
    let master = try renderer.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider)
    XCTAssertEqual(master.modelScale, 2)
    XCTAssertEqual(master.image.texture.width, geometry.width * 2)
    XCTAssertEqual(master.image.texture.height, geometry.height * 2)
    XCTAssertNotNil(master.modelMasks[subject.id])
    let delivered = try renderer.renderDelivery(master, target: .hdr2020)
    XCTAssertEqual(delivered.texture.storageMode, .private)
    XCTAssertEqual(delivered.texture.width, geometry.width * 2)
  }

  func testLandscapeSegmentationUsesTheVerifiedMaskPack() throws {
    let root = repositoryRoot.appending(path: "experiments/MaskAI/Vendor", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: root.appending(path: "Models/efficientvit-seg-b2-ade20k/model.onnx").path) else {
      throw XCTSkip("MaskAI vendor models are not present")
    }
    let pack = DevelopmentMaskModelPack(root: root)
    guard pack.contains(.landscape) else { throw XCTSkip("landscape mask pack is not verified") }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let provider = try DevelopmentSceneProductionModelProvider(device: device, maskPack: pack)
    XCTAssertTrue(provider.supports(.segmentation(.landscape)))
    let image = try ap1Asset("person", device: device)
    let mask = try provider.render(.segmentation(.landscape), input: image.texture, check: {})
    XCTAssertEqual(mask.width, image.texture.width)
    XCTAssertEqual(mask.height, image.texture.height)
    XCTAssertEqual(mask.pixelFormat, .r32Float)
    let values = try readMask(mask)
    XCTAssertEqual(values.count, mask.width * mask.height)
    XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1).contains($0) })
  }

  func testAP1ToLinearRec709RoundTripsThroughTheModelDomain() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let pixels: [SIMD4<Float>] = [.init(0.18, 0.18, 0.18, 1), .init(1.2, 0.4, 0.1, 0.5),
                                  .init(0, 0, 0, 0), .init(4, 2, 1, 1)]
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: 4, height: 1, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    pixels.withUnsafeBytes {
      texture.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0,
        withBytes: $0.baseAddress!, bytesPerRow: 64)
    }
    let color = try DevelopmentSceneMetalV1(device: device)
    let linear = try color.render(.init(texture: texture, port: .working), to: .linearRec709)
    XCTAssertEqual(linear.port.space, .linearRec709)
    let back = try color.render(linear, to: .acescg)
    let result = try readRGBA(back.texture)
    for (found, source) in zip(result, pixels) {
      XCTAssertEqual(found.x, source.x, accuracy: 2e-6)
      XCTAssertEqual(found.y, source.y, accuracy: 2e-6)
      XCTAssertEqual(found.z, source.z, accuracy: 2e-6)
      XCTAssertEqual(found.w, source.w, accuracy: 1e-6)
    }
  }

  // MARK: - Helpers

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func ap1Asset(_ name: String, device: MTLDevice) throws -> DevelopmentSceneMetalV1.Image {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "png",
      subdirectory: "Fixtures/Spektrafilm"))
    let source = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
    let width = Int(source.extent.width.rounded()), height = Int(source.extent.height.rounded())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    let linear = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let context = CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
    context.render(source, to: linear, commandBuffer: nil,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      colorSpace: DevelopmentColorEngineV3.linearSRGB)
    let color = try DevelopmentSceneMetalV1(device: device)
    let port = DevelopmentSceneColorV1.Port(space: .linearRec709,
      reference: .sceneLinear(scaleToSceneReference: 1), alpha: .premultiplied)
    return try color.render(.init(texture: linear, port: port), to: .acescg)
  }

  private func readRGBA(_ texture: MTLTexture) throws -> [SIMD4<Float>] {
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

  private func readMask(_ texture: MTLTexture) throws -> [Float] {
    let size = texture.width * texture.height * 4
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: size, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
    encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer,
      destinationOffset: 0, destinationBytesPerRow: texture.width * 4, destinationBytesPerImage: size)
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw Renderer.Failure.invalidPixel }
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self),
      count: size / 4))
  }
}
