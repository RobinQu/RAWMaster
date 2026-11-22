import Foundation
import XCTest
@testable import RAWMasterCore

final class DevelopmentColorLUTTests: XCTestCase {
  private let identity = """
    # red changes fastest
    TITLE "Identity"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1
    0 0 0
    1 0 0
    0 1 0
    1 1 0
    0 0 1
    1 0 1
    0 1 1
    1 1 1
    """
  private func cube(_ source: String) throws -> DevelopmentColorLUT {
    try .parse(Data(source.utf8), filename: "fallback.cube")
  }

  func testFormatFingerprintAndTamperDetection() throws {
    let value = try cube(identity)
    XCTAssertEqual(value.dimension, 2)
    XCTAssertEqual(value.name, "Identity")
    XCTAssertEqual(value.rgb.count, 96)
    let renamed = try cube(identity.replacingOccurrences(of: "Identity", with: "another"))
    XCTAssertEqual(value.id, renamed.id)
    let newDomain = try cube(identity.replacingOccurrences(of: "DOMAIN_MAX 1 1 1", with: "DOMAIN_MAX 1 1 2"))
    XCTAssertNotEqual(value.id, newDomain.id)
    let shifted = try cube(identity.replacingOccurrences(of: "1 1 1\n0 0 0", with: "1 1 1\n0.25 0 0"))
    XCTAssertNotEqual(value.id, shifted.id)
    let data = try JSONEncoder().encode(value)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["lutCubeRGB32"] = Data(repeating: 0, count: 96).base64EncodedString()
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentColorLUT.self, from: JSONSerialization.data(withJSONObject: object)))
    for invalid in [identity + "\n1 0 0", identity.replacingOccurrences(of: "0 1 1\n", with: ""),
                    identity.replacingOccurrences(of: "1 0 0\n", with: "nan 0 0\n"),
                    identity.replacingOccurrences(of: "DOMAIN_MAX 1 1 1", with: "DOMAIN_MAX 0 1 1"),
                    identity.replacingOccurrences(of: "LUT_3D_SIZE 2", with: "LUT_3D_SIZE 65")] {
      XCTAssertThrowsError(try cube(invalid))
    }
  }

  func testStackValidationAndPortableRecipeIncludingMask() throws {
    let id = UUID()
    let first = DevelopmentLUTLayer(id: id, cube: try cube(identity), amount: 35)
    let second = DevelopmentLUTLayer(cube: .warm, amount: 60)
    let base = DevelopmentRecipe(adjustmentsV3: .init())
    let edited = try base.applying(.setGradingLUTs(.init(layers: [first, second])))
    let masked = try edited.applying(.setMasks([.init(kind: .radial, adjustments: .init(gradingLUT: .init(cube: .monochrome)))]))
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(masked)), masked)
    let old = try JSONEncoder().encode(base)
    XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("gradingLUT"))
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(old), base)
    XCTAssertEqual(try masked.applying(.resetAll), base)
    XCTAssertThrowsError(try base.applying(.setGradingLUTs(.init(layers: [first, first]))))
    XCTAssertThrowsError(try base.applying(.setGradingLUTs(.init(layers: (0..<4).map { _ in .init(cube: .warm) }))))
    XCTAssertThrowsError(try base.applying(.setGradingLUTs(.init(layers: [.init(cube: .warm, amount: .nan)]))))
  }

  func test64DivisionCubeCanReopenAboveLegacyMetadataLimit() throws {
    let count = 64 * 64 * 64
    let source = "LUT_3D_SIZE 64\nLUT_3D_INPUT_RANGE -1 1\n" + String(repeating: "0.5 0.25 0.125\n", count: count)
    let cube = try self.cube(source)
    XCTAssertEqual(cube.dimension, 64)
    XCTAssertEqual(cube.domainMin, SIMD3(repeating: -1))
    let recipe = DevelopmentRecipe(adjustmentsV3: .init(gradingLUTs: .init(layers: [.init(cube: cube)])))
    let data = try JSONEncoder().encode(recipe)
    XCTAssertGreaterThan(data.count, DevelopmentLocalEditLimits.maximumRecipeJSONBytes)
    let reopened = try DevelopmentRecipe.decodeJSON(data)
    XCTAssertEqual(reopened, recipe)
    XCTAssertEqual(reopened.adjustmentsV3?.gradingLUTs?.layers.first?.cube.rgb, cube.rgb)
  }

  func testZIPImportLibraryReopenAndRecipeReplayAfterLibraryRemoval() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let first = root.appendingPathComponent("title [01].cube"), second = folder.appendingPathComponent("second.CUBE")
    try Data(identity.utf8).write(to: first)
    try Data(identity.replacingOccurrences(of: "DOMAIN_MAX 1 1 1", with: "DOMAIN_MAX 2 1 1").utf8).write(to: second)
    let zip = root.appendingPathComponent("looks.zip")
    let packer = Process()
    packer.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    packer.arguments = ["-q", zip.path, first.lastPathComponent, "nested/second.CUBE"]
    packer.currentDirectoryURL = root
    try packer.run(); packer.waitUntilExit()
    XCTAssertEqual(packer.terminationStatus, 0)
    let dir = root.appendingPathComponent("library")
    let catalog = DevelopmentLUTLibrary(directory: dir)
    let imported = try await catalog.importFile(zip)
    XCTAssertEqual(imported.count, 2)
    _ = try await catalog.importFile(first)
    let reopened = DevelopmentLUTLibrary(directory: dir)
    let entries = try await reopened.entries()
    XCTAssertEqual(entries.count, 2)
    let selected = try await reopened.load(entries[1])
    XCTAssertEqual(selected.id, imported[1].id)
    let recipe = DevelopmentRecipe(adjustmentsV3: .init(gradingLUTs: .init(layers: [.init(cube: selected)])))
    let bytes = try JSONEncoder().encode(recipe)
    try FileManager.default.removeItem(at: dir)
    try FileManager.default.removeItem(at: first)
    try FileManager.default.removeItem(at: second)
    XCTAssertEqual(try DevelopmentRecipe.decodeJSON(bytes).adjustmentsV3?.gradingLUTs?.layers.first?.cube.rgb, selected.rgb)
  }
}
