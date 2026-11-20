import XCTest
import Foundation
@testable import RAWMasterCore

final class DevelopmentColorModelsTests: XCTestCase {
  private struct Goldens: Decodable { let entries: [Golden] }
  private struct Golden: Decodable { let label: String; let json: String; let fingerprint: String }
  private let oldEncoderFixture = #"""
{
  "entries": [
    {
      "fingerprint": "81491478172785c23a3a28b851aa76ba2c5138d4bd7e0b9d67dbdcf7c295167b",
      "json": "{\"crop\":{\"height\":1,\"width\":1,\"x\":0,\"y\":0},\"engineVersion\":\"core-image-v1\",\"exposureEV\":0,\"schemaVersion\":1,\"straightenDegrees\":0,\"whiteBalance\":{\"asShot\":{}}}",
      "label": "v1-neutral"
    },
    {
      "fingerprint": "d2768226ea4cc18b83eb29da81bf746cf6b5cc503a679c8c7db61119afe40dc0",
      "json": "{\"crop\":{\"height\":0.6,\"width\":0.7,\"x\":0.1,\"y\":0.15},\"engineVersion\":\"core-image-v1\",\"exposureEV\":0.75,\"schemaVersion\":1,\"straightenDegrees\":2.5,\"whiteBalance\":{\"temperatureTint\":{\"temperature\":5700,\"tint\":-12}}}",
      "label": "v1-adjusted"
    },
    {
      "fingerprint": "6b64b49d3ba18e886bee52323eb5575d0e8a11d7b952e322cd94b422698c3d79",
      "json": "{\"artifact\":{\"alphaPolicy\":\"opaque\",\"bitDepth\":16,\"byteCount\":6789,\"colorSpace\":\"sRGB\",\"encoding\":\"png\",\"nativePixelHeight\":600,\"nativePixelWidth\":900,\"pixelHeight\":600,\"pixelWidth\":900,\"relativePath\":\"versions/golden.png\",\"resamplingChain\":[],\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"configuration\":{\"fixture\":\"legacy\"},\"createdAt\":1000,\"id\":\"golden-version\",\"kind\":\"development\",\"parentVersionID\":\"golden-original\",\"recipe\":{\"crop\":{\"height\":0.6,\"width\":0.7,\"x\":0.1,\"y\":0.15},\"engineVersion\":\"core-image-v1\",\"exposureEV\":0.75,\"schemaVersion\":1,\"straightenDegrees\":2.5,\"whiteBalance\":{\"temperatureTint\":{\"temperature\":5700,\"tint\":-12}}},\"source\":{\"admissionFingerprint\":\"golden-admission\",\"assetID\":\"golden-asset\",\"byteCount\":12345,\"contentSHA256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"projectID\":\"golden-project\",\"sourceLocation\":\"file:///golden/original.ARW\"},\"workID\":\"golden-work\"}",
      "label": "v1-nested-version"
    },
    {
      "fingerprint": "ca993eb8578aca36a027838c470f417f01fc8c30be36cf1ee7f25993a5baa57b",
      "json": "{\"configuration\":{\"seed\":\"42\"},\"inputArtifact\":{\"alphaPolicy\":\"opaque\",\"bitDepth\":16,\"byteCount\":6789,\"colorSpace\":\"sRGB\",\"encoding\":\"png\",\"nativePixelHeight\":600,\"nativePixelWidth\":900,\"pixelHeight\":600,\"pixelWidth\":900,\"relativePath\":\"versions/golden.png\",\"resamplingChain\":[],\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"inputFileURL\":\"file:///golden/input.png\",\"inputVersionID\":\"golden-version\",\"profile\":{\"acceptedForUse\":true,\"capabilities\":{\"capabilityID\":\"golden-v1\",\"supportedOutputEncodings\":[\"png\"],\"supportsCancellation\":false,\"supportsMask\":false,\"supportsReconciliation\":false,\"supportsReferences\":false,\"supportsStrength\":false},\"configuration\":{},\"displayName\":\"Local\",\"endpoint\":\"http://127.0.0.1:8188\",\"experimental\":false,\"id\":\"golden-provider\",\"kind\":\"localComfy\",\"model\":\"golden-model\"},\"prompt\":\"Natural edit\",\"recipe\":{\"crop\":{\"height\":0.6,\"width\":0.7,\"x\":0.1,\"y\":0.15},\"engineVersion\":\"core-image-v1\",\"exposureEV\":0.75,\"schemaVersion\":1,\"straightenDegrees\":2.5,\"whiteBalance\":{\"temperatureTint\":{\"temperature\":5700,\"tint\":-12}}},\"source\":{\"admissionFingerprint\":\"golden-admission\",\"assetID\":\"golden-asset\",\"byteCount\":12345,\"contentSHA256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"projectID\":\"golden-project\",\"sourceLocation\":\"file:///golden/original.ARW\"},\"workID\":\"golden-work\"}",
      "label": "v1-nested-ai-request"
    },
    {
      "fingerprint": "0d9886151bac4bd67ca244a62c675f56740b3de80707f59ffd1a415cf3fbb17d",
      "json": "{\"attemptID\":\"golden-attempt\",\"id\":\"golden-receipt\",\"jobID\":\"golden-job\",\"publishedAt\":2000,\"runID\":\"golden-run\",\"version\":{\"artifact\":{\"alphaPolicy\":\"opaque\",\"bitDepth\":16,\"byteCount\":6789,\"colorSpace\":\"sRGB\",\"encoding\":\"png\",\"nativePixelHeight\":600,\"nativePixelWidth\":900,\"pixelHeight\":600,\"pixelWidth\":900,\"relativePath\":\"versions/golden.png\",\"resamplingChain\":[],\"sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"configuration\":{\"fixture\":\"legacy\"},\"createdAt\":1000,\"id\":\"golden-version\",\"kind\":\"development\",\"parentVersionID\":\"golden-original\",\"recipe\":{\"crop\":{\"height\":0.6,\"width\":0.7,\"x\":0.1,\"y\":0.15},\"engineVersion\":\"core-image-v1\",\"exposureEV\":0.75,\"schemaVersion\":1,\"straightenDegrees\":2.5,\"whiteBalance\":{\"temperatureTint\":{\"temperature\":5700,\"tint\":-12}}},\"source\":{\"admissionFingerprint\":\"golden-admission\",\"assetID\":\"golden-asset\",\"byteCount\":12345,\"contentSHA256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"projectID\":\"golden-project\",\"sourceLocation\":\"file:///golden/original.ARW\"},\"workID\":\"golden-work\"}}",
      "label": "v1-nested-archive-receipt"
    }
  ],
  "origin": "Pre-020 compiled RAWMasterCore.o encoder; no new Core implementation",
  "capturedAt": "2026-10-31T09:50:37.799223+08:00",
  "oldCoreObjectSHA256": "cc92ddb2ef6ebcb49c3cdb443da35ee45bb92773a5c636d608f42e3226288313",
  "probeSourceSHA256": "4520775f6ea38027507db6523748d57f3e879ff6e26e90b979457ba4e530b0d6",
  "baselineCoreSourceSHA256": "dcf115718dcf43605784ad0ef1547423e0e70d53c5e3129e10ed7c7af9df8e04"
}
"""#
  private func compare<T: Codable>(_ type: T.Type, _ golden: Golden) throws {
    let value = try JSONDecoder().decode(type, from: Data(golden.json.utf8))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    XCTAssertEqual(String(decoding: try encoder.encode(value), as: UTF8.self), golden.json, golden.label)
    XCTAssertEqual(try EditingFingerprint.of(value), golden.fingerprint, golden.label)
  }
  func testFiveFrozenActualOldEncoderGoldensAreByteAndFingerprintIdentical() throws {
    let fixture = try JSONDecoder().decode(Goldens.self, from: Data(oldEncoderFixture.utf8))
    XCTAssertEqual(fixture.entries.count, 5)
    for golden in fixture.entries {
      switch golden.label {
      case "v1-neutral", "v1-adjusted": try compare(DevelopmentRecipe.self, golden)
      case "v1-nested-version": try compare(EditingVersion.self, golden)
      case "v1-nested-ai-request": try compare(AIEditRequest.self, golden)
      case "v1-nested-archive-receipt": try compare(ArchivePublicationReceipt.self, golden)
      default: XCTFail("Unexpected old fixture")
      }
    }
  }
  func testPromotionIsExplicitIdempotentAndDoesNotMutateLegacyValue() throws {
    let original = DevelopmentRecipe(exposureEV: 0.5, whiteBalance: .temperatureTint(temperature: 5000, tint: 3), straightenDegrees: 1)
    let promoted = try original.promotingToV2()
    XCTAssertEqual(original.schemaVersion, 1); XCTAssertNil(original.color)
    XCTAssertEqual(promoted.schemaVersion, 2); XCTAssertEqual(promoted.engineVersion, "rawmaster-color-v2")
    XCTAssertEqual(promoted.exposureEV, original.exposureEV); XCTAssertEqual(promoted.whiteBalance, original.whiteBalance)
    XCTAssertTrue(promoted.color!.isNeutral); XCTAssertEqual(try promoted.promotingToV2(), promoted)
    XCTAssertNotEqual(try EditingFingerprint.of(original), try EditingFingerprint.of(promoted))
    XCTAssertEqual(try JSONDecoder().decode(DevelopmentRecipe.self, from: JSONEncoder().encode(promoted)), promoted)
  }
  func testUnknownPairsFieldsPartialAndNullColorAreRejected() throws {
    let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DevelopmentRecipe())) as! [String: Any]
    let promoted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DevelopmentRecipe().promotingToV2())) as! [String: Any]
    var cases: [[String: Any]] = []
    var object = original; object["engineVersion"] = "future"; cases.append(object)
    object = original; object["schemaVersion"] = 99; cases.append(object)
    object = original; object["color"] = NSNull(); cases.append(object)
    object = original; object["extra"] = 1; cases.append(object)
    object = promoted; object.removeValue(forKey: "color"); cases.append(object)
    object = promoted; object["color"] = NSNull(); cases.append(object)
    object = promoted; object["engineVersion"] = "core-image-v1"; cases.append(object)
    object = promoted; object["color"] = ["tones": [:]]; cases.append(object)
    object = promoted
    var color = object["color"] as! [String: Any], tones = color["tones"] as! [String: Any]
    tones["unknown"] = 0; color["tones"] = tones; object["color"] = color; cases.append(object)
    object = original; object["whiteBalance"] = ["asShot": ["ignored": 1]]; cases.append(object)
    object = original; object["crop"] = ["x":0,"y":0,"width":1,"height":1,"ignored":0]; cases.append(object)
    for bad in cases { XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentRecipe.self, from: JSONSerialization.data(withJSONObject: bad))) }
  }
  func testNonfiniteRangesAndOversizedOrDegenerateCurvesReject() throws {
    var recipe = try DevelopmentRecipe().promotingToV2()
    for bad in [Double.nan, .infinity, -.infinity, 100.01, -100.01] {
      recipe.color!.tones.contrast = bad; XCTAssertThrowsError(try recipe.validate()); XCTAssertThrowsError(try JSONEncoder().encode(recipe))
    }
    recipe.color = .init(); recipe.color!.grading.global.hueDegrees = 360; XCTAssertThrowsError(try recipe.validate())
    let badCurves: [DevelopmentCurve] = [ .init(points: []), .init(points: [.init(x:0,y:0)]),
      .init(points: (0...16).map { .init(x:Double($0)/16,y:Double($0)/16) }),
      .init(points: [.init(x:0,y:0),.init(x:0.5,y:1),.init(x:0.50001,y:0),.init(x:1,y:1)]),
      .init(points: [.init(x:0,y:0),.init(x:0,y:1),.init(x:1,y:1)]),
      .init(points: [.init(x:0,y:0),.init(x:1,y:Double.nan)]) ]
    for bad in badCurves { XCTAssertThrowsError(try bad.validate()); XCTAssertThrowsError(try bad.segments()) }
    let tooMany = "{\"points\":[" + (0...16).map { "{\"x\":\(Double($0)/16),\"y\":0}" }.joined(separator: ",") + "]}"
    XCTAssertThrowsError(try JSONDecoder().decode(DevelopmentCurve.self, from: Data(tooMany.utf8)))
  }
  func testPCHIPInterpolatesPointsHasContinuousDerivativeAndNoIntervalOvershoot() throws {
    let curves: [DevelopmentCurve] = [.init(), .init(points: [.init(x:0,y:1),.init(x:1,y:0)]),
      .init(points: [.init(x:0,y:0),.init(x:0.2,y:0.8),.init(x:0.6,y:0.1),.init(x:1,y:1)]),
      .init(points: [.init(x:0,y:0),.init(x:0.499,y:0.1),.init(x:0.49911,y:0.9),.init(x:1,y:1)])]
    for curve in curves {
      let pieces = try curve.segments()
      for (index,piece) in pieces.enumerated() {
        let a = curve.points[index], b = curve.points[index+1]
        XCTAssertEqual(try curve.value(at: a.x), a.y, accuracy: 1e-12)
        for step in 0...100 {
          let x = a.x+(b.x-a.x)*Double(step)/100, y = try curve.value(at:x)
          XCTAssertGreaterThanOrEqual(y, min(a.y,b.y)-1e-12); XCTAssertLessThanOrEqual(y,max(a.y,b.y)+1e-12)
        }
        if index+1 < pieces.count {
          let derivative = (3*piece.a+2*piece.b+piece.c)/(piece.upperX-piece.lowerX), next = pieces[index+1]
          XCTAssertEqual(derivative, next.c/(next.upperX-next.lowerX), accuracy: 1e-8)
        }
      }
      XCTAssertEqual(try curve.value(at: -1), -1+curve.points[0].y, accuracy: 1e-12)
      XCTAssertEqual(try curve.value(at: 2), 1+curve.points.last!.y, accuracy: 1e-12)
    }
  }
  func testInvalidConstructedRecipeCannotPublishArchiveIntent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-recipe-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try EditingArchive(root: root, protectedRoots: [])
    let source = EditingSourceSnapshot(projectID: "p",assetID: "a",contentSHA256:String(repeating:"a",count:64),byteCount:1,admissionFingerprint:"a",sourceLocation: root.appendingPathComponent("source.ARW"))
    var recipe = DevelopmentRecipe(); recipe.engineVersion = "future"
    let input = root.appendingPathComponent("real-valid-bytes.png"); try Data("valid-core-artifact-bytes".utf8).write(to:input)
    let artifact = RenderArtifact(sha256:try FileSafety.hash(input),byteCount:try FileSafety.stat(input).size,pixelWidth:1,pixelHeight:1,encoding:"png",bitDepth:8,colorSpace:"sRGB")
    var version = EditingVersion(workID:"w",parentVersionID:"p",kind:.development,source:source,recipe:recipe,artifact:artifact)
    XCTAssertThrowsError(try archive.publish(fileURL:input,version:version)) { error in
      guard case EditingError.invalidRecipe = error else { return XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("receipts").path).isEmpty)
    version.recipe = .init(); let valid = try archive.publish(fileURL:input,version:version)
    try archive.validate(valid)
  }
  func testRecognizedPendingReceiptWithFutureRecipeOrUnknownFieldThrowsWithoutPublication() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("future-receipt-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let archive = try EditingArchive(root:root,protectedRoots:[])
    let input = root.appendingPathComponent("input.png"); try Data("valid-pending-pixels".utf8).write(to:input)
    let source = EditingSourceSnapshot(projectID:"p",assetID:"a",contentSHA256:String(repeating:"a",count:64),byteCount:1,admissionFingerprint:"a",sourceLocation:root.appendingPathComponent("source.ARW"))
    let artifact = RenderArtifact(sha256:try FileSafety.hash(input),byteCount:try FileSafety.stat(input).size,pixelWidth:1,pixelHeight:1,encoding:"png",bitDepth:8,colorSpace:"sRGB")
    let version = EditingVersion(workID:"w",parentVersionID:"p",kind:.development,source:source,artifact:artifact)
    let receipt = try archive.publish(fileURL:input,version:version)
    let final = try archive.artifactURL(receipt.version.artifact!), receiptURL = root.appendingPathComponent("receipts/\(receipt.id).json")
    let original = try Data(contentsOf:receiptURL)
    try FileManager.default.removeItem(at:final)
    for mutation in ["futureEngine","unknownField"] {
      var json = try JSONSerialization.jsonObject(with:original) as! [String:Any]
      var v = json["version"] as! [String:Any], recipe = v["recipe"] as! [String:Any]
      if mutation == "futureEngine" { recipe["engineVersion"] = "future"; recipe["schemaVersion"] = 99 }
      else { recipe["futureTone"] = 1 }
      v["recipe"] = recipe; json["version"] = v
      let damaged = try JSONSerialization.data(withJSONObject:json,options:[.sortedKeys]); try damaged.write(to:receiptURL)
      XCTAssertThrowsError(try archive.recoverPublications())
      XCTAssertFalse(FileManager.default.fileExists(atPath:final.path)); XCTAssertEqual(try Data(contentsOf:receiptURL),damaged)
    }
    try original.write(to:receiptURL)
    try Data("{\"note\":\"not a receipt\"}".utf8).write(to:root.appendingPathComponent("receipts/unrelated.json"))
    let recovered = try archive.recoverPublications(); XCTAssertEqual(recovered.count,1); try archive.validate(recovered[0])
    XCTAssertEqual(try FileSafety.hash(final),artifact.sha256)
  }

  func testMinimumGapUsesRepresentableAdditionBoundaryAndRejectsTheNextLowerValue() throws {
    let valid = DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0.4999,y:0),.init(x:0.5,y:1),.init(x:1,y:1)])
    XCTAssertNoThrow(try valid.validate()); XCTAssertNoThrow(try valid.segments())
    var below = valid; below.points[2].x = (below.points[1].x+1e-4).nextDown
    XCTAssertThrowsError(try below.validate())
  }

}
