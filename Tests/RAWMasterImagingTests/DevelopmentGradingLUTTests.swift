import AppKit
import CoreImage
import Foundation
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentGradingLUTTests: XCTestCase {
  private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
  private lazy var context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf.rawValue])
  private let input = SIMD4<Float>(0.09, 0.38, 0.7, 1)

  private func cube(domain: String = "", mapping: (Float, Float, Float) -> SIMD3<Float>) throws -> DevelopmentColorLUT {
    var lines = ["LUT_3D_SIZE 2", domain]
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
      let v = mapping(Float(r), Float(g), Float(b))
      lines.append("\(v.x) \(v.y) \(v.z)")
    } } }
    return try .parse(Data(lines.joined(separator: "\n").utf8), filename: "test.cube")
  }
  private func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: 16 * pixels.count,
            size: CGSize(width: pixels.count, height: 1), format: .RGBAf, colorSpace: space)
  }
  private func read(_ image: CIImage) -> [SIMD4<Float>] {
    let width = Int(image.extent.width)
    var pixels = Array(repeating: SIMD4<Float>.zero, count: width * Int(image.extent.height))
    context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
    return pixels
  }
  private func equal(_ pixel: SIMD4<Float>, _ expected: SIMD4<Float>, file: StaticString = #filePath, line: UInt = #line) {
    for c in 0..<4 { XCTAssertEqual(pixel[c], expected[c], accuracy: 0.0002, file: file, line: line) }
  }

  func testIdentityRedFastestAsymmetricChannelsPremultipliedAlphaAndMix() throws {
    let identity = try cube { SIMD3($0, $1, $2) }
    let permutation = try cube { SIMD3($2, $0, $1) }
    let transparent = SIMD4<Float>(repeating: 0)
    let half = input * 0.5
    let source = image([input, half, transparent])
    let reference = read(source)
    let identical = read(try DevelopmentGradingLUTEngine.apply(.init(cube: identity), to: source))
    for i in reference.indices { equal(identical[i], reference[i]) }
    let mapped = SIMD4(input.z, input.x, input.y, 1)
    for amount in [0.0, 35, 100] {
      let pixels = read(try DevelopmentGradingLUTEngine.apply(.init(cube: permutation, amount: amount), to: source))
      let expected = input + (mapped - input) * Float(amount / 100)
      equal(pixels[0], expected); equal(pixels[1], expected * 0.5); equal(pixels[2], transparent)
    }
  }

  func testDomainMappingOrderAndEye() throws {
    let domain = try cube(domain: "DOMAIN_MIN 0.25 0.0 0.5\nDOMAIN_MAX 0.75 1.0 0.8") { SIMD3($0, $1, $2) }
    let src = image([input])
    func encode(_ x: Float) -> Float { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1/2.4) - 0.055 }
    func decode(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055)/1.055, 2.4) }
    let red = decode(min(1, max(0, (encode(input.x) - 0.25)/0.5)))
    let blue = decode(min(1, max(0, (encode(input.z) - 0.5)/0.3)))
    equal(read(try DevelopmentGradingLUTEngine.apply(.init(cube: domain), to: src))[0], .init(red, input.y, blue, 1))
    let a = DevelopmentLUTLayer(cube: .warm), b = DevelopmentLUTLayer(cube: .monochrome)
    let direct = try DevelopmentGradingLUTEngine.apply(b, to: DevelopmentGradingLUTEngine.apply(a, to: src))
    let forward = read(try DevelopmentGradingLUTEngine.apply(.init(layers: [a, b]), to: src))[0]
    let reverse = read(try DevelopmentGradingLUTEngine.apply(.init(layers: [b, a]), to: src))[0]
    equal(forward, read(direct)[0])
    XCTAssertGreaterThan(abs(reverse.z - forward.z), 0.002)
    XCTAssertTrue(try DevelopmentGradingLUTEngine.apply(.init(enabled: false, layers: [a, b]), to: src) === src)
  }

  func testMaskedApplicationAndFittedProxy() throws {
    let layer = DevelopmentLUTLayer(cube: try cube { .init($2, $0, $1) }, amount: 70)
    let source = image(Array(repeating: input, count: 8))
    let mask = DevelopmentMaskLayerV3(kind: .radial, center: .init(x: 0.25, y: 0.5), radiusX: 0.2, radiusY: 1,
                                      feather: 0, adjustments: .init(gradingLUT: layer))
    let direct = read(try DevelopmentMaskEngineV3.apply([mask], to: source, context: context))
    let changed = read(try DevelopmentGradingLUTEngine.apply(layer, to: source))
    equal(direct[2], changed[2]); equal(direct[7], input)
    var payload = DevelopmentAdjustmentsV3(masks: [mask])
    func proxy() throws -> [SIMD4<Float>] {
      read(try PreviewInteractiveProxyV3.suffix(payload, source: source, sourceIsRAW: false, nativeSize: source.extent.size,
                                                 scale: 1, context: context, check: {}))
    }
    let proxyMasked = try proxy()
    for i in direct.indices { equal(proxyMasked[i], direct[i]) }
    payload.masks = []
    payload.gradingLUTs = .init(layers: [layer])
    let proxyGlobal = try proxy()
    for i in changed.indices { equal(proxyGlobal[i], changed[i]) }
  }

  func testPersistedRecipeThroughShippingPreviewAnd16BitExport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.png")
    let sourceImage = image(Array(repeating: input, count: 8))
    let cg = try XCTUnwrap(context.createCGImage(sourceImage, from: sourceImage.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
    let sourceData = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
    try sourceData.write(to: sourceURL)
    let source = EditingSourceSnapshot(projectID: "LUT", assetID: "export", contentSHA256: try RenderFiles.hash(sourceURL),
                                        byteCount: Int64(sourceData.count), admissionFingerprint: "test", sourceLocation: sourceURL)
    let original = DevelopmentRecipe(adjustmentsV3: .init())
    let mask = DevelopmentMaskLayerV3(kind: .radial, center: .init(x: 0.25, y: 0.5), radiusX: 0.2, radiusY: 1,
                                      feather: 0, adjustments: .init(gradingLUT: .init(cube: .monochrome)))
    let edited = try original.applying(.setGradingLUTs(.init(layers: [.init(cube: .warm)]))).applying(.setMasks([mask]))
    let reopened = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(edited))
    let service = DevelopmentService()
    let base = try await service.preview(source: source, recipe: original)
    let graded = try await service.preview(source: source, recipe: reopened)
    func pixel(_ preview: DevelopmentPreview, at x: Int) throws -> NSColor {
      let rep = try XCTUnwrap(preview.image.representations.first as? NSBitmapImageRep)
      return try XCTUnwrap(rep.colorAt(x: x, y: 0)?.usingColorSpace(.sRGB))
    }
    XCTAssertGreaterThan(abs(try pixel(base, at: 2).redComponent - pixel(graded, at: 2).redComponent), 0.03)
    let file = try await service.render(source: source, recipe: reopened, format: .png16,
                                         destination: root.appendingPathComponent("graded.png"))
    XCTAssertEqual(file.artifact.bitDepth, 16)
    let exported = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file.fileURL)))
    for x in [2, 7] {
      let target = try pixel(graded, at: x)
      let restored = try XCTUnwrap(exported.colorAt(x: x, y: 0)?.usingColorSpace(.sRGB))
      XCTAssertEqual(target.redComponent, restored.redComponent, accuracy: 0.013)
      XCTAssertEqual(target.blueComponent, restored.blueComponent, accuracy: 0.013)
    }
  }
}
