import Darwin
import Foundation
import Metal
import XCTest
@testable import RAWMasterImaging

/// Opt-in spike: can the scene Bayer path decode DNG files whose color matrices come from the file
/// (including two illuminants) instead of the decoder database?
///
/// Set `RAWMASTER_SCENE_DNG_FIXTURES` to a comma-separated list of DNG paths. Each file is decoded
/// twice, once with matrix index 0 (Standard Light A on the Q3/DJI files) and once with index 1
/// (D65), so the test also reports how much the choice changes the pixels.
final class DevelopmentSceneDNGSpikeTests: XCTestCase {
  private struct Difference {
    let mean: Float
    let p95: Float
    let maximum: Float
    let aboveOnePercent: Int
    let count: Int
    let maxFirst: SIMD4<Float>
    let maxSecond: SIMD4<Float>
  }

  func testOptInDNGFileMatricesDecodeInScenePath() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let list = environment["RAWMASTER_SCENE_DNG_FIXTURES"], !list.isEmpty else {
      throw XCTSkip("Set RAWMASTER_SCENE_DNG_FIXTURES to comma-separated DNG paths")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let decoder = try DevelopmentSceneRAWV1(device: device)
    setenv("RAWMASTER_SCENE_DNG", "1", 1)
    defer {
      unsetenv("RAWMASTER_SCENE_DNG")
      unsetenv("RAWMASTER_SCENE_MATRIX")
    }

    for path in list.split(separator: ",").map(String.init) {
      let url = URL(fileURLWithPath: path)
      let first = try renderTiles(decoder, url: url, matrix: 0)
      let second = try renderTiles(decoder, url: url, matrix: 1)
      let difference = compare(first, second)
      print("DNG spike \(url.lastPathComponent): mean0 \(mean(first)) mean1 \(mean(second)) " +
        "meanAbsDiff \(difference.mean) p95 \(difference.p95) max \(difference.maximum) " +
        "above0.01 \(difference.aboveOnePercent)/\(difference.count) " +
        "maxPair \(difference.maxFirst) vs \(difference.maxSecond)")

      XCTAssertFalse(first.isEmpty)
      XCTAssertTrue(first.allSatisfy { $0.w == 1 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
        "scene output must be finite RGBA with opaque alpha")
      XCTAssertTrue(second.allSatisfy { $0.w == 1 && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite },
        "scene output must be finite RGBA with opaque alpha")
      XCTAssertGreaterThanOrEqual(difference.mean, 0)
    }
  }

  private func renderTiles(_ decoder: DevelopmentSceneRAWV1, url: URL,
                           matrix: Int) throws -> [SIMD4<Float>] {
    setenv("RAWMASTER_SCENE_MATRIX", String(matrix), 1)
    let mosaic = try decoder.prepare(url)
    let crop = mosaic.sensor.crop
    let side = min(256, Int(crop.z), Int(crop.w))
    guard side > 0 else { return [] }
    let fractions: [Double] = [0.15, 0.5, 0.85]
    var pixels: [SIMD4<Float>] = []
    for fy in fractions {
      for fx in fractions {
        let x = Int(crop.x) + Int((Double(Int(crop.z) - side) * fx).rounded())
        let y = Int(crop.y) + Int((Double(Int(crop.w) - side) * fy).rounded())
        let region = MTLRegionMake2D(x, y, side, side)
        let result = try decoder.develop(mosaic, sampling: .native(region))
        pixels.append(contentsOf: try read(result.image.texture))
      }
    }
    return pixels
  }

  private func compare(_ first: [SIMD4<Float>], _ second: [SIMD4<Float>]) -> Difference {
    let count = min(first.count, second.count)
    guard count > 0 else {
      return Difference(mean: 0, p95: 0, maximum: 0, aboveOnePercent: 0, count: 0,
        maxFirst: .zero, maxSecond: .zero)
    }
    var differences: [Float] = []
    differences.reserveCapacity(count)
    var total: Float = 0
    var above = 0
    var maxValue: Float = 0
    var maxFirst = SIMD4<Float>.zero
    var maxSecond = SIMD4<Float>.zero
    for index in 0..<count {
      let a = first[index], b = second[index]
      let value = max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
      differences.append(value)
      total += value
      if value > 0.01 { above += 1 }
      if value > maxValue {
        maxValue = value
        maxFirst = a
        maxSecond = b
      }
    }
    differences.sort()
    let p95 = differences[min(count - 1, Int(Double(count) * 0.95))]
    return Difference(mean: total / Float(count), p95: p95, maximum: differences[count - 1],
      aboveOnePercent: above, count: count, maxFirst: maxFirst, maxSecond: maxSecond)
  }

  private func mean(_ values: [SIMD4<Float>]) -> SIMD3<Float> {
    guard !values.isEmpty else { return .zero }
    let total = values.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.x, $1.y, $1.z) }
    return total / Float(values.count)
  }

  private func read<T>(_ texture: MTLTexture) throws -> [T] {
    let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
    let row = region.size.width * MemoryLayout<T>.stride
    let total = row * region.size.height
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: total, options: .storageModeShared))
    let queue = try XCTUnwrap(texture.device.makeCommandQueue())
    let command = try XCTUnwrap(queue.makeCommandBuffer())
    let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
    encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin,
      sourceSize: region.size, to: buffer, destinationOffset: 0, destinationBytesPerRow: row,
      destinationBytesPerImage: total)
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw DevelopmentSceneRAWV1.Color.Failure.gpuExecutionFailed }
    return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: T.self),
      count: region.size.width * region.size.height))
  }
}
