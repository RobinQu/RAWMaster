import Foundation
import Metal
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneColorV1Tests: XCTestCase {
  typealias Color = DevelopmentSceneColorV1
  typealias Metal = DevelopmentSceneMetalV1

  private struct Reference: Decodable {
    struct Vector: Decodable {
      let source, target, alpha: String
      let scale, ev: Float
      let input, output: SIMD4<Float>

      func port() throws -> Color.Port {
        .init(space: try XCTUnwrap(Color.Space(rawValue: source)), reference: .sceneLinear(scaleToSceneReference: scale),
          alpha: alpha == "straight" ? .straight : .premultiplied)
      }
    }
    let version, configSHA256: String
    let vectors: [Vector]
  }

  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "scene-color-v1-ocio", withExtension: "json", subdirectory: "Fixtures"))
    let result = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(result.version, "2.5.0")
    XCTAssertEqual(result.configSHA256, Color.referenceConfigSHA256)
    XCTAssertEqual(result.vectors.count, 128)
    return result
  }

  private func assertPixel(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, _ label: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    for component in 0..<3 {
      XCTAssertEqual(actual[component], expected[component],
        accuracy: max(2e-7, abs(expected[component]) * 2e-6), "\(label), lane \(component)", file: file, line: line)
    }
    XCTAssertEqual(actual.w, expected.w, label, file: file, line: line)
  }

  func testCPUAgainstIndependentOCIOVectors() throws {
    let vectors = try reference().vectors
    for (index, vector) in vectors.enumerated() {
      let target = try XCTUnwrap(Color.Space(rawValue: vector.target))
      let transform = try Color.makeTransform(from: vector.port(), to: target, exposureEV: vector.ev)
      XCTAssertEqual(transform.output, target == .acescg ? .working : .exchange)
      assertPixel(try transform.apply(vector.input), vector.output, "OCIO swatch \(index)")
    }
  }

  func testRejectsDisplayLinearAndInvalidScalesBeforeEvaluation() throws {
    for space in [Color.Space.linearRec709, .acescg, .aces2065] {
      XCTAssertThrowsError(try Color.makeTransform(from: .init(space: space, reference: .displayLinear, alpha: .straight))) {
        XCTAssertEqual($0 as? Color.Failure, .displayReferredInput)
      }
    }
    for scale in [Float.zero, -1, .infinity, .nan, .leastNonzeroMagnitude] {
      XCTAssertThrowsError(try Color.makeTransform(from: .init(space: .acescg, reference: .sceneLinear(scaleToSceneReference: scale), alpha: .straight))) {
        XCTAssertEqual($0 as? Color.Failure, .invalidScale)
      }
    }
    for ev in [Float.infinity, -.infinity, .nan, 256, -256] {
      XCTAssertThrowsError(try Color.makeTransform(from: .working, exposureEV: ev)) {
        XCTAssertEqual($0 as? Color.Failure, .invalidScale)
      }
    }
    let inverse = try Color.makeTransform(from: .working, to: .linearRec709)
    let neutral = try inverse.apply(.init(1, 1, 1, 1))
    for channel in 0..<3 { XCTAssertEqual(neutral[channel], 1, accuracy: 2e-6) }
  }

  func testMetalAgainstIndependentOCIOVectorsAndRoundTrip() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Metal(device: device)
    let groups = Dictionary(grouping: try reference().vectors) { vector in
      [vector.source, vector.target, vector.alpha, String(vector.scale), String(vector.ev)]
    }
    for vectors in groups.values {
      let first = try XCTUnwrap(vectors.first)
      let target = try XCTUnwrap(Color.Space(rawValue: first.target))
      let source = try uploaded(vectors.map(\.input), width: vectors.count, height: 1, device: device)
      let result = try renderer.render(.init(texture: source, port: first.port()), to: target, exposureEV: first.ev)
      XCTAssertEqual(result.texture.pixelFormat, .rgba32Float)
      XCTAssertEqual(result.port, target == .acescg ? .working : .exchange)
      let actual = try readback(result.texture)
      for (value, vector) in zip(actual, vectors) { assertPixel(value, vector.output) }
    }
    let values: [SIMD4<Float>] = [.init(-0.25, 0.125, 3.25, 1), .init(4, -1, 0.375, 0.5), .init(0, 0, 0, 0)]
    let source = try uploaded(values, width: values.count, height: 1, device: device)
    let ap0 = try renderer.render(.init(texture: source, port: .working), to: .aces2065)
    let restored = try renderer.render(ap0)
    for (actual, expected) in zip(try readback(restored.texture), values) { assertPixel(actual, expected) }
  }

  func testMetalROIUsesSourceCoordinatesAndPreservesAlpha() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Metal(device: device)
    let values = (0..<35).map { SIMD4<Float>(Float($0), -0.125, 2, 0.5) }
    let source = try uploaded(values, width: 7, height: 5, device: device)
    let image = Metal.Image(texture: source, port: .working, origin: .init(-7, 20))
    let region = MTLRegionMake2D(3, 1, 3, 3)
    let roi = try renderer.render(image, exposureEV: 2, region: region)
    let full = try readback(renderer.render(image, exposureEV: 2).texture)
    XCTAssertEqual(roi.origin, .init(-4, 21))
    XCTAssertEqual(roi.texture.width, 3)
    XCTAssertEqual(roi.texture.height, 3)
    XCTAssertEqual(try readback(roi.texture), (1...3).flatMap { Array(full[7 * $0 + 3..<7 * $0 + 6]) })
    for invalid in [MTLRegionMake2D(7, 0, 1, 1), MTLRegionMake2D(0, 0, 0, 1), MTLRegionMake3D(0, 0, 1, 1, 1, 1)] {
      XCTAssertThrowsError(try renderer.render(image, region: invalid)) {
        XCTAssertEqual($0 as? Color.Failure, .invalidRegion)
      }
    }
    let largeOrigin = Metal.Image(texture: source, port: .working, origin: .init(Int.max, 0))
    XCTAssertThrowsError(try renderer.render(largeOrigin)) { XCTAssertEqual($0 as? Color.Failure, .invalidRegion) }
  }

  func testFusedMetalPassMatchesSeparateConversionAndExposure() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Metal(device: device)
    let values: [SIMD4<Float>] = [.init(0.18, 0.18, 0.18, 1), .init(-0.125, 4, 2, 0.65), .init(3, 2, 1, 0)]
    let source = try uploaded(values, width: values.count, height: 1, device: device)
    let input = Metal.Image(texture: source,
      port: .init(space: .linearRec709, reference: .sceneLinear(scaleToSceneReference: 0.5), alpha: .straight))
    let fused = try renderer.render(input, exposureEV: 2)
    let split = try renderer.render(renderer.render(input), exposureEV: 2)
    for (actual, expected) in zip(try readback(fused.texture), try readback(split.texture)) {
      assertPixel(actual, expected)
    }
  }

  func testCPUAndMetalFailClosedForInvalidPixels() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try Metal(device: device)
    let transform = try Color.makeTransform(from: .working, exposureEV: 2)
    let invalid: [SIMD4<Float>] = [.init(.nan, 0, 0, 1), .init(.infinity, 0, 0, 1), .init(0, 0, 0, .nan),
      .init(0, 0, 0, -0.25), .init(0, 0, 0, 1.01), .init(.greatestFiniteMagnitude, 0, 0, 1)]
    for value in invalid {
      XCTAssertThrowsError(try transform.apply(value)) { XCTAssertEqual($0 as? Color.Failure, .invalidPixel) }
      let source = try uploaded([value], width: 1, height: 1, device: device)
      XCTAssertThrowsError(try renderer.render(.init(texture: source, port: .working), exposureEV: 2)) {
        XCTAssertEqual($0 as? Color.Failure, .invalidPixel)
      }
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
    let half = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    XCTAssertThrowsError(try renderer.render(.init(texture: half, port: .working))) {
      XCTAssertEqual($0 as? Color.Failure, .invalidTexture)
    }
  }

  private func uploaded(_ values: [SIMD4<Float>], width: Int, height: Int, device: MTLDevice) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    XCTAssertEqual(values.count, width * height)
    values.withUnsafeBytes { bytes in
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: width * MemoryLayout<SIMD4<Float>>.stride)
    }
    return texture
  }

  private func readback(_ texture: MTLTexture, width: Int? = nil, height: Int? = nil) throws -> [SIMD4<Float>] {
    let width = width ?? texture.width, height = height ?? texture.height
    let stride = MemoryLayout<SIMD4<Float>>.stride
    let row = width * stride
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: row * height, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
      sourceSize: .init(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
      destinationBytesPerRow: row, destinationBytesPerImage: row * height)
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: width * height))
  }
}
