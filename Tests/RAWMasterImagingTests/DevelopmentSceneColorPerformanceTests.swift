import Foundation
import Metal
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneColorPerformanceTests: XCTestCase {
  private struct Sample: Encodable {
    let onePassMs, twoPassMs, identityMs: Double
  }

  private struct Workload: Encodable {
    let width, height, bytesPerSurface: Int
    let samples: [Sample]
    let onePassP50Ms, onePassP95Ms, twoPassP50Ms, twoPassP95Ms, identityP50Ms, identityP95Ms: Double
    let medianPairedRatio: Double
  }

  private struct Report: Encodable {
    let device, os, operatorVersion, referenceConfigSHA256: String
    let setupMs: Double
    let workloads: [Workload]
  }

  func testOptInPairedMetalSceneColor() throws {
    guard let output = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_COLOR_PERFORMANCE_JSON"], !output.isEmpty else {
      throw XCTSkip("Set RAWMASTER_SCENE_COLOR_PERFORMANCE_JSON to a new report path")
    }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let (renderer, setup) = try time { try DevelopmentSceneMetalV1(device: device) }
    let workloads = try [(960, 640), (3000, 2000)].map { width, height in
      try measure(renderer, device: device, width: width, height: height)
    }
    let report = Report(device: device.name, os: ProcessInfo.processInfo.operatingSystemVersionString,
      operatorVersion: DevelopmentSceneColorV1.operatorVersion,
      referenceConfigSHA256: DevelopmentSceneColorV1.referenceConfigSHA256, setupMs: setup, workloads: workloads)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: [.withoutOverwriting])
    for value in workloads {
      print("037 \(value.width)x\(value.height): one-pass p50/p95 \(value.onePassP50Ms)/\(value.onePassP95Ms) ms; two-pass \(value.twoPassP50Ms)/\(value.twoPassP95Ms) ms; identity \(value.identityP50Ms)/\(value.identityP95Ms) ms; paired ratio \(value.medianPairedRatio)")
      XCTAssertLessThan(value.medianPairedRatio, 0.80, "Fusion must save at least 20% at the paired median")
      XCTAssertLessThanOrEqual(value.onePassP95Ms, value.twoPassP95Ms, "Fusion must not regress p95 against the staged reference")
    }
  }

  private func measure(_ renderer: DevelopmentSceneMetalV1, device: MTLDevice, width: Int, height: Int) throws -> Workload {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    let pattern: [SIMD4<Float>] = [.init(0.18, 0.18, 0.18, 1), .init(2, -0.25, 0.5, 1),
      .init(8, 4, 1, 0.75), .init(-0.125, 0.5, 2, 0.4)]
    let input = (0..<(width * height)).map { pattern[$0 % pattern.count] }
    let rowBytes = width * MemoryLayout<SIMD4<Float>>.stride
    input.withUnsafeBytes { bytes in
      texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
        withBytes: bytes.baseAddress!, bytesPerRow: rowBytes)
    }
    let source = DevelopmentSceneMetalV1.Image(texture: texture,
      port: .init(space: .linearRec709, reference: .sceneLinear(scaleToSceneReference: 1), alpha: .straight))
    let normalized = try renderer.render(source)
    let actions: [() throws -> DevelopmentSceneMetalV1.Image] = [
      { try renderer.render(source, exposureEV: 2) },
      { try renderer.render(renderer.render(source), exposureEV: 2) },
      { try renderer.render(normalized) }
    ]
    for _ in 0..<5 { for action in actions { _ = try autoreleasepool(invoking: action) } }
    var samples: [Sample] = []
    for index in 0..<30 {
      var times = [0.0, 0.0, 0.0]
      for lane in 0..<3 {
        let action = (index + lane) % actions.count
        times[action] = try time { try autoreleasepool(invoking: actions[action]) }.1
      }
      samples.append(Sample(onePassMs: times[0], twoPassMs: times[1], identityMs: times[2]))
    }
    return Workload(width: width, height: height, bytesPerSurface: rowBytes * height, samples: samples,
      onePassP50Ms: percentile(samples.map(\.onePassMs), 0.50), onePassP95Ms: percentile(samples.map(\.onePassMs), 0.95),
      twoPassP50Ms: percentile(samples.map(\.twoPassMs), 0.50), twoPassP95Ms: percentile(samples.map(\.twoPassMs), 0.95),
      identityP50Ms: percentile(samples.map(\.identityMs), 0.50), identityP95Ms: percentile(samples.map(\.identityMs), 0.95),
      medianPairedRatio: percentile(samples.map { $0.onePassMs / $0.twoPassMs }, 0.50))
  }

  private func percentile(_ values: [Double], _ q: Double) -> Double {
    values.sorted()[Int(ceil(Double(values.count) * q)) - 1]
  }

  private func time<T>(_ action: () throws -> T) rethrows -> (T, Double) {
    let start = DispatchTime.now().uptimeNanoseconds
    let value = try action()
    return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
  }
}
