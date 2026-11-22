import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class FlashRawMetalConversionTests: XCTestCase {
  func testAllEXIFOrientationsPreserveFullResolutionHalfSamples() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device required") }
    let converter = try FlashRawMetalConverter(device: device)
    let values = (1...6).flatMap { [Float16($0), Float16($0) / 16, -Float16($0)] }
    let source = try XCTUnwrap(values.withUnsafeBytes {
      device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
    })
    let oriented = [[1,2,3,4,5,6], [3,2,1,6,5,4], [6,5,4,3,2,1], [4,5,6,1,2,3],
                    [1,4,2,5,3,6], [4,1,5,2,6,3], [6,3,5,2,4,1], [3,6,2,5,1,4]]
    for (index, expected) in oriented.enumerated() {
      let width = index < 4 ? 3 : 2, height = index < 4 ? 2 : 3
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
        width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = [.shaderWrite, .shaderRead]
      let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
      try converter.convert(source, sourceWidth: 3, sourceHeight: 2, orientation: index + 1,
        into: texture, outputSize: CGSize(width: width, height: height))
      var result = [Float16](repeating: 0, count: 24)
      result.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
          from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
      }
      XCTAssertEqual(result, expected.flatMap { [Float16($0), Float16($0) / 16, -Float16($0), 1] }, "EXIF \(index + 1)")
    }
  }

  func testPersistedDecoderSurvivesEditsAndNoiseControls() throws {
    var p = DevelopmentAdjustmentsV3()
    let old = DevelopmentRecipe(adjustmentsV3: p)
    XCTAssertFalse(DevelopmentRAWSourcePolicy.usesFlashRaw(p, experiment: false))
    let legacy = try JSONEncoder().encode(old)
    XCTAssertNil(try DevelopmentRecipe.decodeJSON(legacy).adjustmentsV3?.rawDecoder)
    p.rawDecoder = .flashRaw031
    let tagged = DevelopmentRecipe(adjustmentsV3: p)
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(tagged)), tagged)
    XCTAssertEqual(try tagged.applying(.resetAll).adjustmentsV3?.rawDecoder, .flashRaw031)
    XCTAssertTrue(DevelopmentRAWSourcePolicy.usesFlashRaw(p, experiment: false))
    p.noiseReduction = .init(enabled: true, sourceCapability: .raw, luminanceNoise: 0.4)
    XCTAssertTrue(DevelopmentRAWSourcePolicy.usesFlashRaw(p, experiment: false))
    var legacyNoise = p
    legacyNoise.rawDecoder = nil
    XCTAssertFalse(DevelopmentRAWSourcePolicy.usesFlashRaw(legacyNoise, experiment: true))
    p.noiseReduction = .init(enabled: true, sourceCapability: .raw, luminanceContrast: 0.4)
    XCTAssertTrue(DevelopmentRAWSourcePolicy.usesFlashRaw(p, experiment: false))
    XCTAssertNotEqual(try EditingFingerprint.of(old), try EditingFingerprint.of(tagged))
  }
}
