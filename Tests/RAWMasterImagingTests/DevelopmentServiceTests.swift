import AppKit
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentServiceTests: XCTestCase {
  private func fixture(orientation: Int = 1) throws -> (URL, EditingSourceSnapshot) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
    let url = directory.appendingPathComponent("source.tiff")
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let data = try Data(contentsOf: url)
    let source = EditingSourceSnapshot(projectID: "project", assetID: "asset", contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(data.count), admissionFingerprint: "admission", sourceLocation: url)
    return (directory, source)
  }
  func testOrientedTopLeftCropAndPreviewMatchFinalGeometry() async throws {
    let (directory, source) = try fixture(orientation: 6)
    let recipe = DevelopmentRecipe(crop: NormalizedCrop(x: 0, y: 0, width: 1, height: 0.5))
    let service = DevelopmentService()
    let preview = try await service.preview(source: source, recipe: recipe, maxPixel: 64)
    let output = try await service.render(source: source, recipe: recipe, format: .tiff16, destination: directory.appendingPathComponent("crop.tiff"))
    XCTAssertEqual(output.artifact.pixelWidth, 100); XCTAssertEqual(output.artifact.pixelHeight, 100)
    XCTAssertEqual(preview.pixelWidth, 64); XCTAssertEqual(preview.pixelHeight, 64)
    let image = NSBitmapImageRep(data: try Data(contentsOf: output.fileURL))!
    let color = image.colorAt(x: 50, y: 50)!.usingColorSpace(.sRGB)!
    XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertLessThan(color.blueComponent, 0.1)
  }
  func testActualTIFF16ICCAndJPEG8Policy() async throws {
    let (directory, source) = try fixture()
    let service = DevelopmentService()
    let tiff = try await service.render(source: source, recipe: .init(), format: .tiff16, destination: directory.appendingPathComponent("final.tiff"))
    let jpeg = try await service.render(source: source, recipe: .init(), format: .jpeg8, destination: directory.appendingPathComponent("final.jpg"))
    XCTAssertEqual(tiff.artifact.bitDepth, 16); XCTAssertNotNil(tiff.artifact.iccProfileSHA256)
    XCTAssertEqual(tiff.artifact.sourceEffectiveBitDepth, 8)
    XCTAssertEqual(jpeg.artifact.bitDepth, 8); XCTAssertNotNil(jpeg.artifact.iccProfileSHA256)
    XCTAssertEqual(jpeg.artifact.alphaPolicy, .compositedWhite)
    let inspected = try await service.inspect(fileURL: jpeg.fileURL)
    XCTAssertEqual(inspected.alphaPolicy, .opaque)
  }
  func testStraightenUsesSameNativeFieldOfViewForPreview() async throws {
    let (directory, source) = try fixture()
    let service = DevelopmentService(), recipe = DevelopmentRecipe(straightenDegrees: 12, crop: .init(x: 0.1, y: 0.15, width: 0.8, height: 0.75))
    let preview = try await service.preview(source: source, recipe: recipe, maxPixel: 0)
    let output = try await service.render(source: source, recipe: recipe, format: .png16, destination: directory.appendingPathComponent("rotation.png"))
    XCTAssertEqual(preview.pixelWidth, output.artifact.pixelWidth); XCTAssertEqual(preview.pixelHeight, output.artifact.pixelHeight)
    XCTAssertLessThan(output.artifact.pixelWidth, 200); XCTAssertLessThan(output.artifact.pixelHeight, 100)
  }
  func testStaleSourceAndDestinationConflictDoNotOverwrite() async throws {
    let (directory, source) = try fixture()
    let service = DevelopmentService(), output = directory.appendingPathComponent("exists.jpg")
    let sentinel = Data("existing output".utf8); try sentinel.write(to: output)
    do { _ = try await service.render(source: source, recipe: .init(), format: .jpeg8, destination: output); XCTFail("must reject existing") } catch DevelopmentError.outputExists {}
    XCTAssertEqual(try Data(contentsOf: output), sentinel)
    var data = try Data(contentsOf: source.sourceLocation); data[data.count-1] ^= 1; try data.write(to: source.sourceLocation)
    do { _ = try await service.preview(source: source, recipe: .init()); XCTFail("must reject replacement") } catch EditingError.staleSource {}
  }
  func testProtectedDirectoryRejectsExport() async throws {
    let (directory, source) = try fixture()
    do {
      _ = try await DevelopmentService().render(source: source, recipe: .init(), format: .jpeg8, destination: directory.appendingPathComponent("blocked.jpg"), protectedURLs: [directory])
      XCTFail("must protect source root")
    } catch DevelopmentError.protectedDestination {}
  }
  func testOptInRealRAWRecipeAndPrecision() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["RAWMASTER_TEST_RAW"], let evidence = env["RAWMASTER_TEST_RAW_EVIDENCE"] else { throw XCTSkip("Explicit authorized RAW path required") }
    let url = URL(fileURLWithPath: path), directory = URL(fileURLWithPath: evidence)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let hash = try RenderFiles.hash(url)
    let size = (try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.size] as! NSNumber).int64Value
    let source = EditingSourceSnapshot(projectID: "isolated-real-raw", assetID: "real-raw", contentSHA256: hash, byteCount: size, admissionFingerprint: "evaluation", sourceLocation: url)
    let recipe = DevelopmentRecipe(exposureEV: 0.25, straightenDegrees: 1.2, crop: .init(x: 0.04, y: 0.04, width: 0.92, height: 0.92))
    let service = DevelopmentService()
    let preview = try await service.preview(source: source, recipe: recipe, maxPixel: 1600)
    let jpeg = try await service.render(source: source, recipe: recipe, format: .jpeg8, destination: directory.appendingPathComponent("raw-input.jpg"))
    let tiff = try await service.render(source: source, recipe: recipe, format: .tiff16, destination: directory.appendingPathComponent("raw-final.tiff"))
    XCTAssertEqual(jpeg.artifact.bitDepth, 8); XCTAssertEqual(tiff.artifact.bitDepth, 16)
    XCTAssertNotNil(tiff.artifact.iccProfileSHA256); XCTAssertEqual(jpeg.artifact.pixelWidth, tiff.artifact.pixelWidth)
    XCTAssertNil(tiff.artifact.sourceEffectiveBitDepth)
    XCTAssertEqual(Double(preview.pixelWidth) / Double(preview.pixelHeight), Double(tiff.artifact.pixelWidth) / Double(tiff.artifact.pixelHeight), accuracy: 0.003)
    XCTAssertEqual(try RenderFiles.hash(url), hash)
    let work = PhotoWork(source: source)
    let version = EditingVersion(workID: work.id, parentVersionID: work.originalVersionID, kind: .development, source: source, recipe: recipe)
    let archive = try EditingArchive(root: directory.appendingPathComponent("archive"), protectedRoots: [url])
    let ai = try await service.prepareAIInput(work: work, version: version, archive: archive, destination: directory.appendingPathComponent("raw-ai-input.png"))
    XCTAssertEqual(ai.artifact.bitDepth, 8); XCTAssertLessThanOrEqual(ai.artifact.pixelWidth * ai.artifact.pixelHeight, 1_048_576)
    XCTAssertEqual(ai.artifact.nativePixelWidth, tiff.artifact.pixelWidth); XCTAssertEqual(ai.artifact.alphaPolicy, .compositedWhite)
    XCTAssertFalse(ai.artifact.resamplingChain.isEmpty)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(source).write(to: directory.appendingPathComponent("source.json"))
    try encoder.encode(recipe).write(to: directory.appendingPathComponent("recipe.json"))
    try encoder.encode(jpeg.artifact).write(to: directory.appendingPathComponent("jpeg-metadata.json"))
    try encoder.encode(tiff.artifact).write(to: directory.appendingPathComponent("tiff-metadata.json"))
    try encoder.encode(ai.artifact).write(to: directory.appendingPathComponent("ai-input-metadata.json"))
  }

  func testUnknownRawPrecisionSurvivesArchivedExportAndAIInput() async throws {
    let (directory, source) = try fixture()
    let service = DevelopmentService(), work = PhotoWork(source: source)
    let rendered = try await service.render(source: source, recipe: .init(), format: .png16, destination: directory.appendingPathComponent("raw-container.png"))
    var artifact = rendered.artifact; artifact.sourceEffectiveBitDepth = nil
    let archive = try EditingArchive(root: directory.appendingPathComponent("archive"), protectedRoots: [source.sourceLocation])
    let version = EditingVersion(workID: work.id, parentVersionID: work.originalVersionID, kind: .development, source: source, artifact: artifact)
    let receipt = try archive.publish(fileURL: rendered.fileURL, version: version)
    let exported = try await RenderExportService().export(work: work, version: receipt.version, archive: archive, destination: directory.appendingPathComponent("copy.tiff"), format: .tiff16)
    let input = try await service.prepareAIInput(work: work, version: receipt.version, archive: archive, destination: directory.appendingPathComponent("ai.png"))
    XCTAssertNil(exported.artifact.sourceEffectiveBitDepth); XCTAssertNil(input.artifact.sourceEffectiveBitDepth)
    XCTAssertEqual(exported.artifact.bitDepth, 16); XCTAssertEqual(input.artifact.bitDepth, 8)
  }

  func testCompatibilityGraphExportMatchesExistingRendererForAllRecipeSchemas() async throws {
    let (directory, source) = try fixture(orientation: 6)
    var work = PhotoWork(source: source)
    work.liveRecipe = DevelopmentRecipe(exposureEV: 4)
    let archive = try EditingArchive(root: directory.appendingPathComponent("archive"), protectedRoots: [source.sourceLocation])
    let original = DevelopmentRecipe(exposureEV: -0.25, crop: .init(x: 0, y: 0.2, width: 1, height: 0.6))
    let recipes = [original, try original.promotingToV2(), try original.promotingToV3()]
    let developer = DevelopmentService(), exporter = RenderExportService()
    for recipe in recipes {
      let schema = recipe.schemaVersion
      let version = EditingVersion(workID: work.id, parentVersionID: work.originalVersionID, kind: .development,
        source: source, recipe: recipe)
      let expected = try await developer.render(source: source, recipe: recipe, format: .png16,
        destination: directory.appendingPathComponent("baseline-\(schema).png"))
      let rendered = try await exporter.export(work: work, version: version, archive: archive,
        destination: directory.appendingPathComponent("projected-\(schema).png"), format: .png16)
      XCTAssertEqual(try Data(contentsOf: expected.fileURL), try Data(contentsOf: rendered.fileURL))
      XCTAssertEqual(expected.artifact, rendered.artifact)
      XCTAssertEqual(recipe, version.recipe)
    }
  }

  func testExportPreparationFailureRetainsOwnedStageAndNeverPublishes() async throws {
    final class Capture: @unchecked Sendable {
      let lock = NSLock(); var stage: URL?; var artifact: RenderArtifact?
      func record(_ url: URL, _ value: RenderArtifact) { lock.lock(); defer { lock.unlock() }; stage = url; artifact = value }
    }
    enum ExpectedFailure: Error { case afterPreparation }
    let (directory, source) = try fixture(), captured = Capture()
    let work = PhotoWork(source: source), target = directory.appendingPathComponent("durable.tiff")
    let version = EditingVersion(workID: work.id, parentVersionID: nil, kind: .original, source: source)
    let archive = try EditingArchive(root: directory.appendingPathComponent("archive"), protectedRoots: [source.sourceLocation])
    do {
      _ = try await RenderExportService().export(work: work, version: version, archive: archive, destination: target, format: .tiff16,
        preparePublication: { stage, destination, artifact in
          XCTAssertEqual(destination, target); captured.record(stage, artifact); throw ExpectedFailure.afterPreparation
        })
      XCTFail("callback failure must block publication")
    } catch ExpectedFailure.afterPreparation {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    let stage = try XCTUnwrap(captured.stage), artifact = try XCTUnwrap(captured.artifact)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path)); XCTAssertEqual(try RenderFiles.hash(stage), artifact.sha256)
    XCTAssertEqual(artifact.bitDepth, 16)
  }

}
