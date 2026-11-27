import Metal
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentScenePhotographicV1Tests: XCTestCase {
  private func read(_ texture: MTLTexture) throws -> [SIMD4<Float>] {
    let bytes = texture.width * 16, stride = (bytes + 255) / 256 * 256
    let buffer = try XCTUnwrap(texture.device.makeBuffer(length: stride * texture.height, options: .storageModeShared))
    let command = try XCTUnwrap(texture.device.makeCommandQueue()?.makeCommandBuffer())
    let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
      sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer,
      destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
    blit.endEncoding(); command.commit(); command.waitUntilCompleted(); XCTAssertEqual(command.status, .completed)
    return (0..<texture.height).flatMap { y in
      Array(UnsafeBufferPointer(start: buffer.contents().advanced(by: y * stride).assumingMemoryBound(to: SIMD4<Float>.self), count: texture.width))
    }
  }

  func testRealCalibratedNativeRectangleMatchesPhotographicIdentityAndDoublesAtOneStop() throws {
    guard let name = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Requires the fixed 24 MP RAW") }
    let url = URL(fileURLWithPath: name), device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let decoder = try DevelopmentSceneRAWV1(device: device), raw = try decoder.prepare(url)
    let region = MTLRegionMake2D(Int(raw.sensor.size.x) / 3, Int(raw.sensor.size.y) / 3, 17, 11)
    let base = try read(decoder.develop(raw, sampling: .native(region)).image.texture)
    XCTAssertGreaterThan(base.map(\.x).max() ?? 0, 0.01)
    let identity = try DevelopmentScenePhotographicV1(.init(), capture: url, mosaic: raw, decoder: decoder)
    let actual = try read(identity.render(.native(region), maximumBytes: 16 << 20).texture)
    let error = zip(base, actual).map { max(abs($0.x - $1.x), abs($0.y - $1.y), abs($0.z - $1.z)) }.max() ?? .infinity
    XCTAssertLessThan(error, 0.003, "First signed scene samples \(base[0]), \(actual[0])")
    let brighter = try DevelopmentScenePhotographicV1(.init(light: .init(enabled: true, exposure: 0.5)), capture: url, mosaic: raw, decoder: decoder)
    let next = try read(brighter.render(.native(region), maximumBytes: 16 << 20).texture)
    var photo = DevelopmentAdjustmentsV3(); photo.color = .init(enabled: true, saturation: 0.23)
    let color = try DevelopmentScenePhotographicV1(photo, capture: url, mosaic: raw, decoder: decoder)
    let fit = try read(color.render(.fit(width: 160, height: 240), maximumBytes: 16 << 20).texture)
    XCTAssertGreaterThan(fit.map(\.x).max() ?? 0, 0.1)
    XCTAssertTrue(fit.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && (0...1).contains($0.w) })
    XCTAssertLessThan(zip(base, next).map { abs($0.x * 2 - $1.x) }.max() ?? .infinity, 0.005)
  }
  func testRealRAWPhotographicToolsChangeNativeSignedPixelsAndMonochromeRetainsColorControls() throws {
    guard let name = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Requires the fixed 24 MP RAW") }
    let capture = URL(fileURLWithPath: name), device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let decoder = try DevelopmentSceneRAWV1(device: device), mosaic = try decoder.prepare(capture)
    let rect = MTLRegionMake2D(Int(mosaic.sensor.size.x) / 3, Int(mosaic.sensor.size.y) / 3, 64, 47)
    func sample(_ p: DevelopmentAdjustmentsV3, at region: MTLRegion? = nil) throws -> [SIMD4<Float>] {
      try read(DevelopmentScenePhotographicV1(p, capture: capture, mosaic: mosaic, decoder: decoder)
        .render(.native(region ?? rect), maximumBytes: 2 << 20).texture)
    }
    func distance(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
      zip(a,b).map { max(abs($0.x - $1.x), abs($0.y - $1.y), abs($0.z - $1.z)) }.max() ?? 0
    }
    let reference = try sample(.init())
    var color = DevelopmentAdjustmentsV3(); color.color = .init(enabled: true, saturation: 0.7, vibrance: 0.6)
    var white = DevelopmentAdjustmentsV3(); white.whiteBalance = .init(enabled: true, adjustment: .temperatureTint(temperature: 8500, tint: -15))
    var detail = DevelopmentAdjustmentsV3(); detail.definition = .init(enabled: true, amount: 0.7)
    var optics = DevelopmentAdjustmentsV3(); optics.vignette = .init(enabled: true, strength: 0.8)
    let recipes = [("color",color),("white balance",white),("definition",detail)]
    for (tool, recipe) in recipes {
      let changed = try sample(recipe), delta = distance(reference, changed)
      XCTAssertGreaterThan(delta, 0.00001, tool)
      XCTAssertTrue(changed.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, tool)
      print("Native photographic", tool, "maximum channel delta", delta)
    }
    let nearCorner = MTLRegionMake2D(80, 100, 64, 47)
    let cornerDelta = try distance(sample(.init(), at: nearCorner), sample(optics, at: nearCorner))
    XCTAssertGreaterThan(cornerDelta, 0.00001)
    print("Native photographic vignette corner delta", cornerDelta)
    var mono = DevelopmentAdjustmentsV3()
    mono.blackAndWhite.enabled = true; mono.blackAndWhite.placement = .afterPhotographicColorV1
    let neutral = try sample(mono)
    mono.color = color.color
    let adjusted = try sample(mono)
    XCTAssertGreaterThan(distance(neutral, adjusted), 0.001)
    XCTAssertLessThan(adjusted.map { max(abs($0.x - $0.y), abs($0.y - $0.z)) }.max() ?? .infinity, 0.001)
    var lifted = color; lifted.light = .init(enabled: true, exposure: 1)
    let highlights = try sample(lifted)
    XCTAssertGreaterThan(highlights.map(\.x).max() ?? 0, 1)
  }

}
