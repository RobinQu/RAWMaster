import Foundation
import XCTest
@testable import RAWMasterCore

final class PresetExchangeTests: XCTestCase {
  private var root: URL!
  private var store: DevelopmentPresetCatalog!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("PresetExchange-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = DevelopmentPresetCatalog(root: root.appendingPathComponent("catalog"))
  }
  override func tearDownWithError() throws {
    if let root { try FileManager.default.removeItem(at: root) }
  }
  private func xmp(_ flags: String, children: String = "", type: String = "Normal") -> Data {
    let raw = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><r:RDF xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <r:Description r:about="" xmlns:c="http://ns.adobe.com/camera-raw-settings/1.0/" xmlns:foreign="urn:other"
      c:PresetType="\(type)" c:ProcessVersion="15.4" \(flags)>
    <c:Name><r:Alt><r:li xml:lang="x-default">A &amp; B</r:li></r:Alt></c:Name>
    \(children)
    </r:Description></r:RDF></x:xmpmeta>
    """
    return Data(raw.utf8)
  }
  private func write(_ name: String, _ data: Data) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
  }

  func testSparseRDFParameterRoundTripAndSourceRules() throws {
    let curve = "<c:ToneCurvePV2012Red><r:Seq><r:li>0, 0</r:li><r:li>128, 143</r:li><r:li>255, 255</r:li></r:Seq></c:ToneCurvePV2012Red>"
    let bytes = xmp("c:Exposure2012=\"1.5\" c:Shadows2012=\"0\" foreign:Saturation=\"100\"", children: curve)
    let stage = try DevelopmentPresetExchange.inspectFiles([write("a.xmp", bytes)], catalog: store)
    let row = try XCTUnwrap(stage.records.first)
    XCTAssertEqual(row.name, "A & B")
    XCTAssertEqual(row.patch.exposure, 0.75)
    XCTAssertEqual(row.patch.shadows, 0)
    XCTAssertNil(row.patch.saturation)
    XCTAssertNil(row.patch.pointBlue)
    XCTAssertEqual(row.patch.pointRed?.points.count, 3)
    XCTAssertTrue(row.blockingReasons.isEmpty)
    let projected = try CameraRawPresetMapping.export(row.patch, name: row.name, group: row.group)
    XCTAssertTrue(projected.excluded.isEmpty)
    let parsed = try DevelopmentPresetExchange.inspectFiles([write("roundtrip.xmp", projected.data)], catalog: store)
    XCTAssertEqual(parsed.records.first?.patch, row.patch)
    var partial = row.patch
    partial.blackPoint = 0.2
    XCTAssertEqual(try CameraRawPresetMapping.export(partial, name: "A", group: "B").excluded, ["blackPoint"])
    let tool = try DevelopmentPresetExchange.inspectFiles([write("x.xmp", xmp("c:Exposure2012=\"1\" c:FutureOperator=\"9\""))], catalog: store)
    let excluded = try XCTUnwrap(tool.records.first)
    XCTAssertFalse(excluded.blockingReasons.isEmpty)
    XCTAssertEqual(try DevelopmentPresetExchange.subset(for: excluded).patch.exposure, 0.5)
    XCTAssertEqual(excluded.metadata["omitted"], "FutureOperator")
    _ = try tool.commit(to: store)
    let display = try DevelopmentPresetExchange.sourceFields(for: excluded, catalog: store)
    XCTAssertTrue(display.fields.contains { $0.path == "rdf:Description/@crs:FutureOperator" && $0.value == "9" })
    let restricted = try DevelopmentPresetExchange.inspectFiles([write("camera.xmp",
      xmp("c:Exposure2012=\"1\" c:SupportsOutputReferred=\"False\""))], catalog: store)
    XCTAssertThrowsError(try DevelopmentPresetExchange.subset(for: XCTUnwrap(restricted.records.first)))
    let duplicate = xmp("c:Exposure2012=\"1\"", children: "<c:Exposure2012>2</c:Exposure2012>")
    XCTAssertThrowsError(try CameraRawXMP.read(duplicate))
    XCTAssertThrowsError(try CameraRawXMP.read(Data(("<!DOCTYPE x>" + String(decoding: bytes, as: UTF8.self)).utf8)))
  }

  func testBlankAndIndependentPointCurveChannelsNeverOverwriteDestinationChannels() throws {
    let zero = xmp("c:Exposure2012=\"0\"",
      children: "<c:ToneCurvePV2012Red><r:Seq><r:li>0, 0</r:li><r:li>255, 225</r:li></r:Seq></c:ToneCurvePV2012Red>")
    let stage = try DevelopmentPresetExchange.inspectFiles([write("zero.xmp", zero)], catalog: store)
    let record = try XCTUnwrap(stage.records.first)
    var recipe = try DevelopmentRecipe().promotingToV3()
    recipe.adjustmentsV3!.light = .init(enabled: true, exposure: 1, contrast: 0.3)
    recipe.adjustmentsV3!.curves.green.curve = .init(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 0.9)])
    let commands = try record.patch.commands(from: recipe, amount: 1)
    var foundLight = false, foundCurves = false
    for cmd in commands {
      if case let .setParameters(.light(light)) = cmd {
        foundLight = true; XCTAssertEqual(light.exposure, 0); XCTAssertEqual(light.contrast, 0.3)
      }
      if case let .setParameters(.curves(curves)) = cmd {
        foundCurves = true
        XCTAssertEqual(curves.green, recipe.adjustmentsV3!.curves.green)
        XCTAssertEqual(curves.red.curve, record.patch.pointRed)
      }
    }
    XCTAssertTrue(foundLight && foundCurves)
  }

  func testCurrentProjectionIncludesLegacyExposureAndReportsUnrepresentableEdits() throws {
    var recipe = try DevelopmentRecipe(exposureEV: 1.25).promotingToV3()
    recipe.adjustmentsV3?.light = .init(enabled: true, exposure: 0.25, blackPoint: 0.1)
    recipe.adjustmentsV3?.curves = .init(enabled: true)
    let export = try DevelopmentPresetExchange.projectedXMP(for: recipe, name: "A & B")
    let original = try CameraRawXMP.read(export.data)
    XCTAssertEqual(original.scalars["Exposure2012"], "1.75")
    XCTAssertTrue(export.included.contains("ToneCurvePV2012Blue"))
    XCTAssertEqual(Set(export.excluded), ["curves.algorithm", "light.blackPoint"])
    var onlyBlack = DevelopmentAdjustmentsV3()
    onlyBlack.light = .init(enabled: true, blackPoint: 0.4)
    XCTAssertThrowsError(try DevelopmentPresetExchange.projectedXMP(for: DevelopmentRecipe(adjustmentsV3: onlyBlack), name: "x")) {
      XCTAssertTrue($0.localizedDescription.contains("light.blackPoint"))
    }
    let displayNames = """
      <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:c="http://ns.adobe.com/camera-raw-settings/1.0/">
      <c:Name><rdf:Alt><rdf:li xml:lang="x-default">Default</rdf:li><rdf:li xml:lang="zh-Hans">简体</rdf:li></rdf:Alt></c:Name>
      </rdf:Description></rdf:RDF>
      """
    let d = try CameraRawXMP.read(Data(displayNames.utf8))
    XCTAssertEqual(d.name("Name", preferredLanguages: ["zh-Hans-CN"]), "简体")
    XCTAssertEqual(d.name("Name", preferredLanguages: ["de-DE"]), "Default")
  }

  private func mixedExposure(_ legacyEV: Double, light: Double) throws -> DevelopmentRecipe {
    let legacy = try DevelopmentRecipe(exposureEV: legacyEV).promotingToV2()
    var recipe = try legacy.promotingToV3()
    recipe.adjustmentsV3!.light = .init(enabled: true, exposure: light)
    return recipe
  }

  private func applying(_ row: DevelopmentPresetRecord, to recipe: DevelopmentRecipe) throws -> DevelopmentRecipe {
    let base = try recipe.promotingToV3()
    return try row.patch.commands(from: base, amount: 1).reduce(base) { try $0.applying($1) }
  }

  private func renderedEV(_ recipe: DevelopmentRecipe) throws -> Double {
    let p = try XCTUnwrap(recipe.adjustmentsV3)
    return (p.legacyBasis?.exposureEV ?? 0) + (p.light.enabled ? p.light.exposure * 2 : 0)
  }

  private func checkExposureRoundTrip(legacyEV: Double, light: Double, expected: Double) throws {
    let recipe = try mixedExposure(legacyEV, light: light)
    let patch = try DevelopmentPresetPatch(capturing: recipe, fields: [.exposure])
    let saved = try store.create(name: "物理曝光", group: "个人", patch: patch)
    let selected = try XCTUnwrap(store.records().first { $0.id == saved.id })
    let original = try DevelopmentPresetExchange.projectedXMP(for: recipe, name: selected.name)
    let personal = try DevelopmentPresetExchange.projectedXMP(for: selected)
    for (offset, xmp) in [original, personal].enumerated() {
      XCTAssertTrue(xmp.excluded.isEmpty)
      XCTAssertEqual(xmp.included, ["Exposure2012"])
      XCTAssertEqual(try CameraRawXMP.read(xmp.data).scalars["Exposure2012"].flatMap(Double.init), expected)
      let staged = try DevelopmentPresetExchange.inspectFiles([write("ev-\(offset).xmp", xmp.data)], catalog: store)
      let row = try XCTUnwrap(staged.records.first)
      let target = try mixedExposure(0.75, light: -0.625)
      XCTAssertEqual(try renderedEV(applying(row, to: target)), expected)
    }
  }

  func testPersonalAndPhotoXMPRoundTripCombinedLegacyAndV3Exposure() throws {
    try checkExposureRoundTrip(legacyEV: 1, light: 0.5, expected: 2)
  }

  func testPersonalAndPhotoXMPRoundTripLegacyOnlyExposure() throws {
    try checkExposureRoundTrip(legacyEV: 1, light: 0, expected: 1)
  }

  func testPersonalAndPhotoXMPRoundTripV3OnlyExposureWithoutFalseExclusions() throws {
    try checkExposureRoundTrip(legacyEV: 0, light: 0.5, expected: 1)
  }

  func testExplicitZeroResetsBothExposureStagesAndOmissionInheritsBoth() throws {
    var old = try DevelopmentRecipe(exposureEV: 1.25, whiteBalance: .temperatureTint(temperature: 5100, tint: 3),
                                    straightenDegrees: 2).promotingToV2()
    old.color!.tones.shadows = 37
    var target = try old.promotingToV3()
    target.adjustmentsV3!.light = .init(enabled: true, exposure: 0.5, shadows: 0.15)
    let bytes = xmp("c:Exposure2012=\"0\"")
    let stage = try DevelopmentPresetExchange.inspectFiles([write("zero-ev.xmp", bytes)], catalog: store)
    _ = try stage.commit(to: store)
    let zero = try XCTUnwrap(store.records().first)
    var expectedZero = target
    expectedZero.adjustmentsV3!.legacyBasis!.exposureEV = 0
    expectedZero.adjustmentsV3!.light.exposure = 0
    XCTAssertEqual(try applying(zero, to: target), expectedZero)
    XCTAssertEqual(try renderedEV(expectedZero), 0)
    let inherit = try DevelopmentPresetExchange.inspectFiles([write("inherit.xmp", xmp("c:Vibrance=\"20\""))], catalog: store)
    let result = try applying(XCTUnwrap(inherit.records.first), to: target)
    XCTAssertEqual(result.adjustmentsV3?.legacyBasis, target.adjustmentsV3?.legacyBasis)
    XCTAssertEqual(result.adjustmentsV3?.light, target.adjustmentsV3?.light)
    XCTAssertEqual(result.adjustmentsV3?.geometry, target.adjustmentsV3?.geometry)
    XCTAssertEqual(try renderedEV(result), 2.25)
    let neutral = try mixedExposure(1, light: -0.5)
    let reset = try store.create(name: "明确零", group: "个人", patch: DevelopmentPresetPatch(capturing: neutral, fields: [.exposure]))
    XCTAssertEqual(try CameraRawXMP.read(DevelopmentPresetExchange.projectedXMP(for: reset).data).scalars["Exposure2012"], "0.00")
  }

  func testLegacyExposureExportsWithOnlyActualUnmappedFieldsAndSupportsReopenedV1Index() throws {
    var old = try DevelopmentRecipe(exposureEV: 1).promotingToV2()
    old.color!.tones.shadows = 25
    let recipe = try old.promotingToV3()
    let captured = try store.create(name: "完整旧基底", group: "个人",
      patch: DevelopmentPresetPatch(capturing: recipe, fields: [.legacyBasis, .exposure]))
    let sparse = try store.create(name: "逐项旧基底", group: "个人",
      patch: DevelopmentPresetPatch(capturing: recipe, fields: [.shadows, .exposure]))
    XCTAssertEqual(try DevelopmentPresetExchange.projectedXMP(for: captured).excluded, ["legacyBasis.color.tones.shadows"])
    XCTAssertEqual(try DevelopmentPresetExchange.projectedXMP(for: recipe, name: "当前").excluded, ["legacyBasis.color.tones.shadows"])
    XCTAssertEqual(try DevelopmentPresetExchange.projectedXMP(for: sparse).excluded, ["legacyFields.tones.shadows"])
    let stage = try DevelopmentPresetExchange.inspectFiles([write("old-mapping.xmp", xmp("c:Exposure2012=\"0\""))], catalog: store)
    let id = try XCTUnwrap(stage.commit(to: store).first)
    let index = root.appendingPathComponent("catalog/index-v1.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
    var rows = try XCTUnwrap(object["records"] as? [[String: Any]])
    let offset = try XCTUnwrap(rows.firstIndex { $0["id"] as? String == id })
    var payload = try XCTUnwrap(rows[offset]["patch"] as? [String: Any])
    payload.removeValue(forKey: "legacyFields"); rows[offset]["patch"] = payload
    var metadata = try XCTUnwrap(rows[offset]["metadata"] as? [String: String])
    metadata["mappingVersion"] = "1"; rows[offset]["metadata"] = metadata
    object["records"] = rows
    try JSONSerialization.data(withJSONObject: object).write(to: index, options: .atomic)
    let reopened = DevelopmentPresetCatalog(root: root.appendingPathComponent("catalog"))
    let repaired = try XCTUnwrap(reopened.records().first { $0.id == id })
    XCTAssertEqual(repaired.patch.legacyFields?.exposureEV, 0)
    XCTAssertEqual(repaired.metadata["mappingVersion"], "2")
    XCTAssertEqual(try renderedEV(applying(repaired, to: recipe)), 0)
    XCTAssertEqual(try reopened.records().first { $0.id == captured.id }, captured)
  }

  func testDuplicateBatchOwnershipUUIDConflictsAndExactOriginalRights() throws {
    let first = xmp("c:UUID=\"ABC\" c:Exposure2012=\"1\"")
    let oneURL = try write("1.xmp", first)
    let one = try DevelopmentPresetExchange.inspectFiles([oneURL], catalog: store)
    XCTAssertEqual(try one.commit(to: store).count, 1)
    let resumed = try DevelopmentPresetExchange.inspectFiles([oneURL], catalog: store)
    XCTAssertEqual(resumed.items.first?.status, .duplicate)
    XCTAssertEqual(try resumed.commit(to: store).count, 0)
    try store.removeImportBatch(one.batchID)
    XCTAssertEqual(try store.records().count, 1)
    let conflict = try DevelopmentPresetExchange.inspectFiles([write("2.xmp", xmp("c:UUID=\"ABC\" c:Exposure2012=\"2\""))], catalog: store)
    XCTAssertEqual(conflict.items.first?.status, .conflict)
    XCTAssertEqual(try conflict.commit(to: store).count, 0)
    XCTAssertEqual(try conflict.commit(to: store, keepingConflicts: true).count, 1)
    let original = try XCTUnwrap(one.records.first)
    XCTAssertEqual(try DevelopmentPresetExchange.originalXMP(for: original, catalog: store, confirmedRights: true), first)
    XCTAssertThrowsError(try DevelopmentPresetExchange.originalXMP(for: original, catalog: store, confirmedRights: false))
    try DevelopmentPresetCatalog(root: root.appendingPathComponent("catalog")).removeImportBatch(resumed.batchID)
    XCTAssertEqual(try store.records().count, 1)
    XCTAssertEqual(try store.originalData(sha256: XCTUnwrap(original.sourceSHA256)), first)
    XCTAssertEqual(try Data(contentsOf: oneURL), first)
  }

  func testScopedMigrationAndChangedBuiltin() throws {
    let rules = try DevelopmentPresetExchange.migrationRules()
    XCTAssertEqual(rules.count, 53)
    let syst = root.appendingPathComponent("system")
    let user = root.appendingPathComponent("user")
    let bytes = xmp("c:Saturation=\"30\"")
    _ = try write("system/" + rules[0].path, bytes)
    _ = try write("system/Entirely Unrelated.xmp", bytes)
    _ = try write("user/Additional/deep.XMP", bytes)
    _ = try write("user/Notes.txt", Data())
    let outside = try write("outside.xmp", xmp("c:Saturation=\"40\""))
    try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("escape.xmp"), withDestinationURL: outside)
    let report = try DevelopmentPresetExchange.inspectAdobe(system: syst, user: user, catalog: store)
    XCTAssertEqual(report.items.filter { $0.status == .missing }.count, 52)
    XCTAssertEqual(report.items.filter { $0.status == .changed }.count, 1)
    XCTAssertEqual(report.items.filter { $0.status == .ignored }.count, 2)
    XCTAssertEqual(report.records.count, 1, String(describing: report.items))
    XCTAssertFalse(report.items.contains { $0.path.contains("Entirely") })
    XCTAssertTrue(try store.records().isEmpty)
  }

  func testZIPMembersAreBoundedAndChecksumVerifiedBeforeCommit() throws {
    let bytes = xmp("c:Contrast2012=\"25\"")
    _ = try write("nested/good.xmp", bytes)
    _ = try write("note.txt", Data("notes".utf8))
    let zip = root.appendingPathComponent("set.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-q", zip.path, "nested/good.xmp", "note.txt"]
    process.currentDirectoryURL = root
    try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    let stage = try DevelopmentPresetExchange.inspectFiles([zip], catalog: store)
    XCTAssertEqual(stage.records.first?.patch.contrast, 0.25)
    XCTAssertEqual(stage.items.filter { $0.status == .ignored }.count, 1)
    let original = try Data(contentsOf: zip)
    var tampered = original
    let directory = try XCTUnwrap(tampered.range(of: Data([0x50,0x4b,1,2])))
    tampered[directory.lowerBound + 16] ^= 1
    XCTAssertThrowsError(try PresetExchangeArchive.read(tampered))
    XCTAssertFalse(PresetExchangeLimits.safePath("../test.xmp"))
    XCTAssertFalse(PresetExchangeLimits.safePath("/outside.xmp"))
    XCTAssertTrue(try store.records().isEmpty)
  }

  func testRepeatedContentRetainsLocationsAndReportHasFinalDisposition() throws {
    let bytes = xmp("c:UUID=\"F1\" c:Highlights2012=\"25\"")
    let source = try write("first.xmp", bytes)
    let first = try DevelopmentPresetExchange.inspectFiles([source], catalog: store)
    let inserted = try first.commit(to: store)
    let second = try DevelopmentPresetExchange.inspectFiles([write("second.xmp", bytes)], catalog: store)
    XCTAssertTrue(try second.commit(to: store).isEmpty)
    let record = try XCTUnwrap(store.records().first)
    let paths = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(record.metadata["sourceLocationsV1"]).utf8))
    XCTAssertEqual(Set(paths), ["manual / first.xmp", "manual / second.xmp"])
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: first.reportData(inserted: Set(inserted))) as? [String: Any])
    XCTAssertEqual(report["addedIDs"] as? [String], inserted)
    XCTAssertEqual(report["dispositionByItemID"] as? [String: String], ["0":"inserted"])
  }

  func testUndoOrderFollowsSuccessfulCommitAcrossWindowsAndSameSecondRetries() throws {
    let a = xmp("c:Shadows2012=\"20\""), b = xmp("c:Shadows2012=\"40\"")
    let first = try XCTUnwrap(DevelopmentPresetExchange.inspectFiles([write("A.xmp", a)], catalog: store).records.first)
    let second = try XCTUnwrap(DevelopmentPresetExchange.inspectFiles([write("B.xmp", b)], catalog: store).records.first)
    let firstID = "2026-11-22T00:00:00Z-1", secondID = "2026-11-22T00:00:00Z-2"
    let secondWindow = DevelopmentPresetCatalog(root: root.appendingPathComponent("catalog"))
    let aBytes = [try XCTUnwrap(first.sourceSHA256): a], bBytes = [try XCTUnwrap(second.sourceSHA256): b]
    _ = try secondWindow.importBatch([second], originals: bBytes, batchID: secondID)
    _ = try store.importBatch([first], originals: aBytes, batchID: firstID)
    _ = try secondWindow.importBatch([second], originals: bBytes, batchID: secondID)
    XCTAssertEqual(try store.importHistory().committed, [secondID, firstID])
    try secondWindow.removeImportBatch(try XCTUnwrap(store.importHistory().committed.last))
    try store.removeImportBatch(firstID)
    XCTAssertThrowsError(try store.importBatch([first], originals: aBytes, batchID: firstID))
    XCTAssertEqual(try store.records().map(\.id), [second.id])
    XCTAssertEqual(try store.importHistory().committed, [secondID])
  }

  func testLegacyReceiptOrderRequiresExplicitChoiceUntilANewBatchCommits() throws {
    let file = try write("legacy.xmp", xmp("c:Contrast2012=\"12\""))
    let stage = try DevelopmentPresetExchange.inspectFiles([file], catalog: store)
    _ = try stage.commit(to: store)
    let index = root.appendingPathComponent("catalog/index-v1.json")
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
    object.removeValue(forKey: "batchCommitOrder")
    try JSONSerialization.data(withJSONObject: object).write(to: index, options: .atomic)
    let resumed = DevelopmentPresetCatalog(root: root.appendingPathComponent("catalog"))
    XCTAssertTrue(try resumed.importHistory().committed.isEmpty)
    XCTAssertEqual(try resumed.importHistory().unsequenced, [stage.batchID])
    let next = try DevelopmentPresetExchange.inspectFiles([file], catalog: resumed)
    _ = try next.commit(to: resumed)
    XCTAssertEqual(try resumed.importHistory().committed, [next.batchID])
    XCTAssertEqual(try resumed.importHistory().unsequenced, [stage.batchID])
    try resumed.removeImportBatch(next.batchID)
    XCTAssertEqual(try resumed.records().count, 1)
  }

  private var frozenManifest: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("specs/031-preset-browser/contracts/migration-manifest-v1.json")
  }

  func testFrozenMigrationRejectsChangedManifestAndIncompleteSelection() throws {
    var tampered = try Data(contentsOf: frozenManifest)
    tampered.append(10)
    let changed = try write("forged.json", tampered)
    XCTAssertThrowsError(try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: changed, system: root, user: root, catalog: store))
    let stage = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: frozenManifest, system: root, user: root, catalog: store)
    XCTAssertFalse(stage.frozenMigrationReady)
    XCTAssertEqual(stage.items.count, 78)
    XCTAssertEqual(stage.items.filter { $0.origin == "adobeBuiltin" && $0.status == .missing }.count, 53)
    XCTAssertEqual(stage.items.filter { $0.origin == "userImported" && $0.status == .missing }.count, 25)
    XCTAssertThrowsError(try stage.commit(to: store, keepingConflicts: true))
    XCTAssertTrue(try store.records().isEmpty)
    XCTAssertTrue(try store.importBatchIDs().isEmpty)
  }

  func testStrictBatchRejectsCompetingUUIDEvenWhenRecordAlreadyExists() throws {
    let original = xmp("c:UUID=\"ABC\" c:Exposure2012=\"1\"")
    let first = try DevelopmentPresetExchange.inspectFiles([write("A.xmp", original)], catalog: store)
    let row = try XCTUnwrap(first.records.first)
    _ = try first.commit(to: store)
    let conflict = try DevelopmentPresetExchange.inspectFiles([write("B.xmp", xmp("c:UUID=\"abc\" c:Exposure2012=\"2\""))], catalog: store)
    _ = try conflict.commit(to: store, keepingConflicts: true)
    let snapshot = try store.records()
    let batchIDs = try store.importBatchIDs()
    XCTAssertThrowsError(try store.importBatch([row], originals: [try XCTUnwrap(row.sourceSHA256): original],
        batchID: "frozen-after-inspection", requireUnambiguousUUIDs: true))
    XCTAssertEqual(try store.records(), snapshot)
    XCTAssertEqual(try store.importBatchIDs(), batchIDs)
  }

  func testFrozenInstalledReplayAndSourceDriftOnExplicitRequest() throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_CHECK_ADOBE_PRESET_FIXTURE"] == "1" else {
      throw XCTSkip("Local migration fixture is opt-in")
    }
    let host = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: frozenManifest, catalog: store)
    XCTAssertTrue(host.frozenMigrationReady)
    let system = root.appendingPathComponent("system"), user = root.appendingPathComponent("user")
    for item in host.items {
      let builtin = item.origin == "adobeBuiltin"
      let source = (builtin ? DevelopmentPresetExchange.systemRoot : DevelopmentPresetExchange.userRoot).appendingPathComponent(item.path)
      let target = (builtin ? system : user).appendingPathComponent(item.path)
      try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: source, to: target)
    }
    _ = try write("user/New Unlisted After Snapshot.xmp", xmp("c:Exposure2012=\"0.25\""))
    var patch = DevelopmentPresetPatch()
    patch.exposure = 0.2
    let personal = try store.create(name: "Before frozen import", group: "Personal", patch: patch)
    try store.toggleFavorite(personal.id)
    let scene = try XCTUnwrap(host.items.first { $0.origin == "adobeBuiltin" })
    let earlier = try DevelopmentPresetExchange.inspectFiles([system.appendingPathComponent(scene.path)], catalog: store)
    _ = try earlier.commit(to: store)
    let earlierRecord = try XCTUnwrap(earlier.records.first)
    try store.toggleFavorite(earlierRecord.id)
    let favorites = try store.favoriteIDs()
    func inspect() throws -> PresetExchangeStage {
      try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: frozenManifest, system: system, user: user, catalog: store)
    }
    let initial = try inspect()
    XCTAssertEqual(initial.batchID, host.batchID)
    XCTAssertEqual(initial.items.count, 78)
    XCTAssertEqual(initial.items.filter { $0.status == .duplicate }.count, 1)
    XCTAssertTrue(initial.frozenMigrationReady)
    XCTAssertEqual(try initial.commit(to: store).count, 77)
    let firstSnapshot = try store.records()
    XCTAssertEqual(firstSnapshot.count, 79)
    let replay = try inspect()
    XCTAssertTrue(replay.frozenMigrationReady)
    XCTAssertEqual(replay.items.filter { $0.status == .duplicate }.count, 78)
    XCTAssertTrue(try replay.commit(to: store).isEmpty)
    XCTAssertEqual(try store.records(), firstSnapshot)
    XCTAssertEqual(try store.importBatchIDs(), [earlier.batchID, initial.batchID])
    XCTAssertEqual(try store.favoriteIDs(), favorites)
    for row in replay.records {
      _ = try store.originalData(sha256: XCTUnwrap(row.sourceSHA256))
    }
    let victim = try XCTUnwrap(host.items.first { $0.origin == "userImported" })
    let path = user.appendingPathComponent(victim.path)
    var bytes = try Data(contentsOf: path)
    bytes[0] ^= 1
    try bytes.write(to: path)
    let drift = try inspect()
    XCTAssertFalse(drift.frozenMigrationReady)
    XCTAssertEqual(drift.items.filter { $0.status == .changed }.map(\.path), [victim.path])
    XCTAssertThrowsError(try drift.commit(to: store))
    XCTAssertEqual(try store.records(), firstSnapshot)
    try FileManager.default.removeItem(at: path)
    XCTAssertEqual(try inspect().items.filter { $0.status == .missing }.map(\.path), [victim.path])
    try store.removeImportBatch(initial.batchID)
    XCTAssertEqual(Set(try store.records().map(\.id)), [earlierRecord.id, personal.id])
    XCTAssertEqual(try store.favoriteIDs(), favorites)
    XCTAssertThrowsError(try replay.commit(to: store), "A user's explicit removal must survive a replay")
    XCTAssertEqual(try store.importBatchIDs(), [earlier.batchID])
    let retired = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: frozenManifest, catalog: store)
    XCTAssertTrue(retired.frozenBatchPreviouslyRemoved)
    XCTAssertFalse(retired.frozenMigrationReady)
  }

  func testFrozenLensBlurMapsOnlyAuditedOpticsAndValidatesPerPhotoDepth() throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_CHECK_ADOBE_PRESET_FIXTURE"] == "1" else {
      throw XCTSkip("Local migration fixture is opt-in")
    }
    let stage = try DevelopmentPresetExchange.inspectFrozenAdobe(manifest: frozenManifest, catalog: store)
    _ = try stage.commit(to: store)
    let active = stage.records.filter { $0.metadata["analysis"] == "perPhotoDepth" }
    XCTAssertEqual(active.count, 12)
    let sourceID = String(repeating: "a", count: 64), otherID = String(repeating: "b", count: 64)
    let depth = try DevelopmentLensBlurDepthPayloadV1(kind: .disparity, width: 2, height: 2, values: [1, 0.3, 0.4, 0])
    let scene = DevelopmentSceneDepthV1(sourceSHA256: sourceID, map: depth)
    let focus = DevelopmentSourcePoint(x: 0.25, y: 0.65)
    var baseline = try DevelopmentRecipe(exposureEV: 0.7).promotingToV3()
    baseline.adjustmentsV3?.effects = .init(enabled: true, grain: 0.36)
    var mapped = Set<String>(), omissions = Set<String>()
    for row in active {
      let assessment = try stage.lensBlurAssessment(for: row)
      XCTAssertEqual(assessment, try DevelopmentPresetExchange.lensBlurAssessment(for: row, catalog: store))
      XCTAssertFalse(row.blockingReasons.isEmpty)
      guard case .approximate(let plan) = assessment else {
        if case .unavailable(let reason) = assessment { omissions.insert(reason) }
        continue
      }
      let basename = URL(fileURLWithPath: try XCTUnwrap(row.metadata["relativePath"])).deletingPathExtension().lastPathComponent
      mapped.insert(basename)
      let attributes = try CameraRawXMP.read(store.originalData(sha256: plan.presetSHA256)).lensBlur
      let candidate = try plan.prepare(record: row, baseline: baseline, sourceID: sourceID, scene: scene, focus: focus, focusRange: 0.27)
      let full = try XCTUnwrap(candidate.patch.fullRecipe)
      let blur = try XCTUnwrap(full.adjustmentsV3?.effects?.lensBlur)
      XCTAssertEqual(blur.amount, try XCTUnwrap(Double(attributes["BlurAmount"] ?? "")) / 100)
      XCTAssertEqual(blur.catEyeAmount, try XCTUnwrap(Double(attributes["CatEyeAmount"] ?? "")) / 100)
      XCTAssertEqual(blur.bokehBoost, try XCTUnwrap(Double(attributes["HighlightsBoost"] ?? "")) / 100)
      XCTAssertEqual(blur.sceneDepth, scene)
      XCTAssertEqual(blur.bokehStyle, .circle)
      XCTAssertEqual(blur.focusX, focus.x)
      XCTAssertEqual(blur.focusRange, 0.27)
      var restored = full
      restored.adjustmentsV3?.effects?.lensBlur = nil
      XCTAssertEqual(restored, baseline)
      XCTAssertNotNil(candidate.reason(for: otherID))
      let audit = try DevelopmentPresetAdoption(record: candidate, sourceID: sourceID, amount: 1, baseline: baseline, result: full, masks: nil)
      XCTAssertEqual(audit.policy, "nativeDepthApproximation")
      XCTAssertEqual(audit.fields, ["effects.lensBlur"])
      XCTAssertNotNil(audit.omitted)
      XCTAssertThrowsError(try plan.prepare(record: row, baseline: baseline, sourceID: otherID, scene: scene, focus: focus, focusRange: 0.27))
      XCTAssertThrowsError(try plan.prepare(record: row, baseline: baseline, sourceID: sourceID, scene: nil, focus: focus, focusRange: 0.27))
      XCTAssertThrowsError(try plan.prepare(record: row, baseline: baseline, sourceID: sourceID, scene: scene, focus: nil, focusRange: nil))
      var seeded = full
      seeded.adjustmentsV3?.effects?.lensBlur?.focusX = 0.91
      seeded.adjustmentsV3?.effects?.lensBlur?.deviceDepth = try .init(kind: .depth, width: 1, height: 1, values: [0.44])
      let reused = try plan.prepare(record: row, baseline: seeded, sourceID: sourceID, scene: nil, focus: nil, focusRange: nil)
      XCTAssertEqual(reused.patch.fullRecipe, seeded)
    }
    XCTAssertEqual(mapped, ["Circle", "Circle Swirl", "Strong", "Subtle"])
    XCTAssertEqual(omissions.count, 4)
    XCTAssertEqual(try store.records(), stage.records)
  }

  func testInstalledSnapshotOnExplicitRequest() throws {
    guard ProcessInfo.processInfo.environment["RAWMASTER_CHECK_ADOBE_PRESET_FIXTURE"] == "1" else {
      throw XCTSkip("Local migration fixture is opt-in")
    }
    let stage = try DevelopmentPresetExchange.inspectAdobe(catalog: store)
    XCTAssertEqual(stage.records.count, 78)
    XCTAssertEqual(stage.visibleCount, 72)
    let types = Dictionary(grouping: stage.records, by: { $0.metadata["capability"] ?? "" }).mapValues(\.count)
    XCTAssertEqual(types, ["semanticCorrection":38, "lensBlur":13, "adaptiveProfile":2, "staticLook":6, "normalPreset":19])
    XCTAssertEqual(stage.records.filter { $0.metadata["lookResolution"] == "internal" }.count, 12)
    XCTAssertEqual(stage.records.filter { $0.metadata["lookResolution"] == "missing" }.count, 1)
    XCTAssertEqual(stage.records.filter { $0.metadata["cameraProfile"]?.isEmpty == false }.count, 6)
    XCTAssertEqual(stage.records.filter { $0.blockingReasons.isEmpty }.count, 1)
    XCTAssertEqual(stage.records.compactMap { try? DevelopmentPresetExchange.subset(for: $0) }.count, 7)
    let intents = stage.records.compactMap(DevelopmentPresetExchange.semanticIntent)
    XCTAssertEqual(intents.filter { $0.target == .subject }.count, 9)
    XCTAssertEqual(intents.filter { $0.target == .sky }.count, 9)
    let local = stage.records.compactMap { try? DevelopmentPresetExchange.semanticReconstruction(for: $0) }
    XCTAssertEqual(local.filter { $0.patch.semanticMasks?.first?.target == .subject }.count, 4)
    XCTAssertEqual(local.filter { $0.patch.semanticMasks?.first?.target == .sky }.count, 5)
    XCTAssertTrue(local.allSatisfy { $0.metadata["semanticReconstruction"] == "true" })
    let soft = try XCTUnwrap(local.first { $0.metadata["relativePath"]?.hasSuffix("/Soft.xmp") == true })
    XCTAssertEqual(try XCTUnwrap(soft.patch.semanticMasks?.first?.adjustments.texture), -0.304315, accuracy: 0.000001)
    let sunrise = try XCTUnwrap(local.first { $0.metadata["relativePath"]?.hasSuffix("/Sunrise.xmp") == true })
    XCTAssertEqual(try XCTUnwrap(sunrise.patch.semanticMasks?.first?.adjustments.temperature), 0.20192, accuracy: 0.000001)
    XCTAssertTrue(stage.records.filter { $0.metadata["capability"] == "semanticCorrection" }.allSatisfy { !$0.blockingReasons.isEmpty })
    let reset = try XCTUnwrap(stage.records.first { $0.patch.resetLensBlur == true })
    XCTAssertTrue(reset.blockingReasons.isEmpty)
    XCTAssertEqual(reset.metadata["analysis"], "noneForReset")
    XCTAssertEqual(stage.records.filter { $0.metadata["analysis"] == "perPhotoDepth" }.count, 12)
    let empty = try DevelopmentRecipe().promotingToV3()
    XCTAssertTrue(try reset.patch.commands(from: empty, amount: 1).isEmpty)
    var withBlur = empty
    withBlur.adjustmentsV3?.effects = .init(enabled: true, grain: 0.4, lensBlur: .init(enabled: true))
    let commands = try reset.patch.commands(from: withBlur, amount: 1)
    XCTAssertEqual(commands.count, 1)
    if case let .setEffects(effect) = try XCTUnwrap(commands.first) {
      XCTAssertNil(effect.lensBlur); XCTAssertEqual(effect.grain, 0.4); XCTAssertTrue(effect.enabled)
    } else { XCTFail("Expected only the effects reset") }
    XCTAssertEqual(try stage.commit(to: store).count, 78)
    let repeatScan = try DevelopmentPresetExchange.inspectAdobe(catalog: store)
    XCTAssertEqual(try repeatScan.commit(to: store).count, 0)
    for row in stage.records {
      let base = row.metadata["origin"] == "adobeBuiltin" ? DevelopmentPresetExchange.systemRoot : DevelopmentPresetExchange.userRoot
      let original = try Data(contentsOf: base.appendingPathComponent(try XCTUnwrap(row.metadata["relativePath"])))
      XCTAssertEqual(try store.originalData(sha256: XCTUnwrap(row.sourceSHA256)), original)
    }
    let builtin = try XCTUnwrap(stage.records.first { $0.metadata["origin"] == "adobeBuiltin" })
    XCTAssertThrowsError(try DevelopmentPresetExchange.originalXMP(for: builtin, catalog: store, confirmedRights: true))
    print("Preset migration fixture: 78 SHA-verified files, 72 visible, 6 hidden, 12 internal Looks, 1 missing Look, 6 camera-base references, 0 duplicate insertions.")
  }
}
