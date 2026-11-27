import Foundation
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneModelPipelineV1Tests: XCTestCase {
  typealias Graph = DevelopmentSceneGraphV1
  typealias Node = Graph.Node
  typealias Renderer = DevelopmentSceneGraphRendererV1
  typealias Stage = DevelopmentSceneModelStageV1
  typealias Program = DevelopmentSceneModelProgramV1

  func testDenoiseAndSuperResolutionRunBeforeTheSceneGraph() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let samples: [SIMD4<Float>] = (0..<32).map { index in
      .init(0.1 + Float(index) * 0.01, 0.3, 0.7 - Float(index) * 0.005, index % 3 == 0 ? 0.5 : 1)
    }
    let image = try upload(samples, width: 8, device: device)
    let geometry = Renderer.Geometry(width: 8, height: 4)
    let provider = try TestSceneModelProvider(device: device)
    let program = try Program(stages: [.denoise(amount: 50), .superResolution()])
    let node = Node(name: "No-op", operation: .corrector(image: .input, mask: nil, exposureEV: 0,
      curve: [], strength: 1, enabled: true))
    let graph = try workflow([node], final: node)
    let renderer = try Renderer(device: device, surfaceBudget: 64 * 1024 * 1024)
    let master = try renderer.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider)
    XCTAssertEqual(master.modelScale, 2)
    XCTAssertEqual(master.image.texture.width, 16)
    XCTAssertEqual(master.image.texture.height, 8)
    let rendered = try read(master.image.texture)
    for (index, source) in samples.enumerated() {
      let found = rendered[(index / 8 * 2) * 16 + (index % 8) * 2]
      XCTAssertEqual(found.x, source.x * 1.05, accuracy: 2e-6)
      XCTAssertEqual(found.y, source.y * 1.05, accuracy: 2e-6)
      XCTAssertEqual(found.w, source.w, accuracy: 1e-6)
    }
    XCTAssertEqual(provider.calls, [.denoise, .superResolution])
  }

  func testRustGraphExecutesAfterTheModelPrefix() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let image = try upload(Array(repeating: .init(0.2, 0.4, 0.6, 1), count: 16), width: 4, device: device)
    let geometry = Renderer.Geometry(width: 4, height: 4)
    let provider = try TestSceneModelProvider(device: device)
    let program = try Program(stages: [.denoise(amount: 100)])
    let gradient = Node(name: "Ramp", operation: .linearCoverage(start: .zero, end: .init(1, 0)))
    let grade = Node(name: "Grade", operation: .corrector(image: .input, mask: gradient.id,
      exposureEV: 1, curve: [], strength: 1, enabled: true))
    let graph = try workflow([gradient, grade], final: grade)
    let swift = try Renderer(device: device)
    let previous = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]
    setenv("RAWMASTER_SCENE_BACKEND", "rust", 1)
    defer {
      if let previous { setenv("RAWMASTER_SCENE_BACKEND", previous, 1) } else { unsetenv("RAWMASTER_SCENE_BACKEND") }
    }
    let rust = try Renderer(device: device)
    let expected = try read(swift.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider).image.texture)
    let actual = try read(rust.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider).image.texture)
    XCTAssertEqual(actual.count, expected.count)
    for (found, reference) in zip(actual, expected) {
      XCTAssertEqual(found.x, reference.x, accuracy: 2e-5)
      XCTAssertEqual(found.y, reference.y, accuracy: 2e-5)
      XCTAssertEqual(found.z, reference.z, accuracy: 2e-5)
    }
  }

  func testSegmentationCoverageTracksThePostResolutionSize() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let samples: [SIMD4<Float>] = [.init(0.2, 0.4, 0.6, 1), .init(0.8, 0.1, 0.1, 1),
                                   .init(0, 0, 0, 1), .init(1, 1, 1, 1)]
    let image = try upload(samples, width: 2, device: device)
    let geometry = Renderer.Geometry(width: 2, height: 2)
    let provider = try TestSceneModelProvider(device: device)
    let segmentation = Stage.segmentation()
    let program = try Program(stages: [.superResolution(), segmentation])
    let node = Node(name: "No-op", operation: .corrector(image: .input, mask: nil, exposureEV: 0,
      curve: [], strength: 1, enabled: true))
    let graph = try workflow([node], final: node)
    let master = try Renderer(device: device).prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider)
    let mask = try XCTUnwrap(master.modelMasks[segmentation.id])
    XCTAssertEqual(mask.pixelFormat, .r32Float)
    XCTAssertEqual(mask.width, 4)
    XCTAssertEqual(mask.height, 4)
    let coverage = try read(mask).map(\.x)
    XCTAssertEqual(coverage.count, 16)
    for value in coverage { XCTAssertGreaterThanOrEqual(value, 0); XCTAssertLessThanOrEqual(value, 1) }
  }

  func testSegmentationMaskFeedsTheSceneGraphThroughExternalCoverage() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let samples: [SIMD4<Float>] = (0..<32).map { index in
      .init(Float(index % 8) / 8, Float(index / 8) / 4, 0.5, 1)
    }
    let image = try upload(samples, width: 8, device: device)
    let geometry = Renderer.Geometry(width: 8, height: 4)
    let provider = try TestSceneModelProvider(device: device)
    let program = try Program(stages: [.superResolution(), .segmentation()])
    let stage = try XCTUnwrap(program.coverageStages.first)
    let mask = Node(name: "Provider mask", operation: .externalCoverage(id: stage.id))
    let grade = Node(name: "Masked exposure", operation: .corrector(image: .input, mask: mask.id,
      exposureEV: 1, curve: [], strength: 1, enabled: true))
    let graph = try workflow([mask, grade], final: grade)
    let swift = try Renderer(device: device)
    let previous = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]
    setenv("RAWMASTER_SCENE_BACKEND", "rust", 1)
    defer {
      if let previous { setenv("RAWMASTER_SCENE_BACKEND", previous, 1) } else { unsetenv("RAWMASTER_SCENE_BACKEND") }
    }
    let rust = try Renderer(device: device)
    let swiftMaster = try swift.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider)
    let rustMaster = try rust.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider)
    XCTAssertEqual(swiftMaster.image.texture.width, 16)
    XCTAssertNotNil(swiftMaster.modelMasks[stage.id])
    let expected = try read(swiftMaster.image.texture)
    let actual = try read(rustMaster.image.texture)
    let tiled = try rust.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: provider, tileEdge: 64)
    try zip(try read(tiled.image.texture), expected).forEach { found, reference in
      XCTAssertEqual(found.x, reference.x, accuracy: 2e-5)
      XCTAssertEqual(found.y, reference.y, accuracy: 2e-5)
      XCTAssertEqual(found.z, reference.z, accuracy: 2e-5)
    }
    for (found, reference) in zip(actual, expected) {
      XCTAssertEqual(found.x, reference.x, accuracy: 2e-5)
      XCTAssertEqual(found.y, reference.y, accuracy: 2e-5)
      XCTAssertEqual(found.z, reference.z, accuracy: 2e-5)
    }
    XCTAssertGreaterThan(actual.map(\.x).max()!, samples.map(\.x).max()!)
  }

  func testProgramValidationKeepsGenerativeWorkOutOfTheDeterministicPipeline() throws {
    XCTAssertThrowsError(try Program(stages: [.segmentation(), .denoise()])) {
      XCTAssertEqual($0 as? Stage.Failure, .invalidOrder)
    }
    XCTAssertThrowsError(try Program(stages: [.superResolution(), .superResolution()])) {
      XCTAssertEqual($0 as? Stage.Failure, .duplicateModel)
    }
    let unique = UUID()
    XCTAssertThrowsError(try Program(stages: [
      .denoise(id: unique), .denoise(id: unique)
    ])) {
      XCTAssertEqual($0 as? Stage.Failure, .duplicateModel)
    }
    XCTAssertThrowsError(try Program(stages: [.denoise(.appleRAW9)])) {
      XCTAssertEqual($0 as? Stage.Failure, .invalidModel)
    }
    XCTAssertThrowsError(try Program(stages: [.denoise(.photoVGG7ChromaOutputDNG)])) {
      XCTAssertEqual($0 as? Stage.Failure, .invalidModel)
    }
    XCTAssertThrowsError(try Program(stages: Array(repeating: Stage.denoise(), count: 5))) {
      XCTAssertEqual($0 as? Stage.Failure, .unsupportedStage)
    }
    let generative = Data(#"{"stages":[{"id":"7E5C33C2-8B4E-4F84-9C76-2A6B5D8A1F10","kind":"flux","model":"flux.3","prompt":"sunset"}]}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(Program.self, from: generative))
    let unordered = Data(#"{"stages":[{"id":"7E5C33C2-8B4E-4F84-9C76-2A6B5D8A1F11","kind":"segmentation","model":"isnet-general@mask-ai-native-v1"},{"id":"7E5C33C2-8B4E-4F84-9C76-2A6B5D8A1F12","kind":"denoise","model":"waifu2x-vgg7-photo-noise2-cc385f97-full-chroma-v2","amount":50}]}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(Program.self, from: unordered))
    let roundTrip = try JSONDecoder().decode(Program.self, from: JSONEncoder().encode(Program(stages: [
      .denoise(amount: 40), .superResolution(), .segmentation()
    ])))
    XCTAssertEqual(roundTrip.stages.map(\.kind), [.denoise, .superResolution, .segmentation])
  }

  func testModelPrefixRequiresFullFrameAndAProvider() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let image = try upload(Array(repeating: .init(0.2, 0.4, 0.6, 1), count: 16), width: 4, device: device)
    let geometry = Renderer.Geometry(width: 8, height: 8)
    let node = Node(name: "No-op", operation: .corrector(image: .input, mask: nil, exposureEV: 0,
      curve: [], strength: 1, enabled: true))
    let graph = try workflow([node], final: node)
    let program = try Program(stages: [.denoise()])
    let renderer = try Renderer(device: device)
    XCTAssertThrowsError(try renderer.prepareFinal(image, geometry: geometry, graph: graph,
      models: program, provider: try TestSceneModelProvider(device: device))) {
      XCTAssertEqual($0 as? Renderer.Failure, .invalidImage)
    }
    let full = try upload(Array(repeating: .init(0.2, 0.4, 0.6, 1), count: 64), width: 8, device: device)
    XCTAssertThrowsError(try renderer.prepareFinal(full, geometry: geometry, graph: graph,
      models: program, provider: nil)) {
      XCTAssertEqual($0 as? DevelopmentSceneModelPipelineV1.Failure, .unsupportedProvider)
    }
    let tight = try Renderer(device: device, surfaceBudget: full.texture.allocatedSize)
    XCTAssertThrowsError(try tight.prepareFinal(full, geometry: geometry, graph: graph,
      models: program, provider: try TestSceneModelProvider(device: device))) {
      XCTAssertEqual($0 as? Renderer.Failure, .surfaceBudget)
    }
  }

  // MARK: - Helpers

  private func workflow(_ nodes: [Node], final: Node) throws -> Graph {
    try .init(graph: .init(nodes: nodes, output: .node(final.id)),
      output: .init(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
  }

  private func upload(_ samples: [SIMD4<Float>], width: Int, device: MTLDevice) throws -> Renderer.Image {
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
    XCTAssertEqual(command.status, .completed)
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self),
      count: size / 16))
  }
}

/// Deterministic Metal stand-in for Core ML/ONNX providers used by the pipeline contract tests.
private final class TestSceneModelProvider: DevelopmentSceneModelProvider {
  enum Failure: Error { case unavailable }
  let identity = "test-scene-model-provider-v1"
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let denoise, superResolution, segmentation: MTLComputePipelineState
  private(set) var calls: [DevelopmentSceneModelStageV1.Kind] = []

  init(device: MTLDevice) throws {
    self.device = device
    guard let queue = device.makeCommandQueue(), let denoiseFunction = try device.makeLibrary(source: Self.shader, options: nil).makeFunction(name: "rmTestDenoise"),
          let superFunction = try device.makeLibrary(source: Self.shader, options: nil).makeFunction(name: "rmTestSR"),
          let segmentationFunction = try device.makeLibrary(source: Self.shader, options: nil).makeFunction(name: "rmTestSeg") else {
      throw Failure.unavailable
    }
    self.queue = queue
    denoise = try device.makeComputePipelineState(function: denoiseFunction)
    superResolution = try device.makeComputePipelineState(function: superFunction)
    segmentation = try device.makeComputePipelineState(function: segmentationFunction)
  }

  func supports(_ stage: DevelopmentSceneModelStageV1) -> Bool { true }

  func render(_ stage: DevelopmentSceneModelStageV1, input: MTLTexture,
              check: () throws -> Void) throws -> MTLTexture {
    try check()
    calls.append(stage.kind)
    let multiplier = stage.scale
    let coverage = stage.kind == .segmentation
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: coverage ? .r32Float : .rgba32Float,
      width: input.width * multiplier, height: input.height * multiplier, mipmapped: false)
    descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
    guard let output = device.makeTexture(descriptor: descriptor),
          let command = queue.makeCommandBuffer(),
          let encoder = command.makeComputeCommandEncoder() else { throw Failure.unavailable }
    let pipeline = coverage ? segmentation : stage.kind == .superResolution ? superResolution : denoise
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
    var gain: Float = 1
    if case .denoise(_, let amount) = stage.configuration {
      gain = 1 + Float(amount) / 1000
      encoder.setBytes(&gain, length: MemoryLayout<Float>.size, index: 0)
    }
    let lanes = pipeline.threadExecutionWidth
    encoder.dispatchThreads(.init(width: output.width, height: output.height, depth: 1),
      threadsPerThreadgroup: .init(width: lanes,
        height: min(8, pipeline.maxTotalThreadsPerThreadgroup / lanes), depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw DevelopmentSceneGraphRendererV1.Failure.invalidPixel }
    try check()
    return output
  }

  private static let shader = #"""
  #include <metal_stdlib>
  using namespace metal;
  kernel void rmTestDenoise(texture2d<float, access::read> source [[texture(0)]],
      texture2d<float, access::write> target [[texture(1)]], constant float& gain [[buffer(0)]],
      uint2 xy [[thread_position_in_grid]]) {
    float4 p = source.read(xy); target.write(float4(p.rgb * gain, p.a), xy);
  }
  kernel void rmTestSR(texture2d<float, access::read> source [[texture(0)]],
      texture2d<float, access::write> target [[texture(1)]], uint2 xy [[thread_position_in_grid]]) {
    target.write(source.read(xy / 2), xy);
  }
  kernel void rmTestSeg(texture2d<float, access::read> source [[texture(0)]],
      texture2d<float, access::write> target [[texture(1)]], uint2 xy [[thread_position_in_grid]]) {
    float4 p = source.read(xy);
    float luma = p.a > 0 ? dot(p.rgb / p.a, float3(0.2722287168, 0.6740817658, 0.0536895174)) : 0;
    target.write(float4(clamp(luma, 0.0, 1.0), 0, 0, 1), xy);
  }
  """#
}
