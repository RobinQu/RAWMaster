import CryptoKit
import Foundation
import RAWMasterCore
import XCTest

final class DevelopmentPresetTests: XCTestCase {
    private let source = String(repeating: "a", count: 64)

    private func project(_ patch: DevelopmentPresetPatch, on base: DevelopmentRecipe, amount: Double = 1) throws -> DevelopmentRecipe {
        let commands = try patch.commands(from: base, amount: amount)
        guard !commands.isEmpty else { return base }
        return try commands.reduce(base.promotingToV3()) { try $0.applying($1) }
    }

    func testSparseExplicitZeroAndSingleAdobeCurveKeepUnselectedFieldsAndMasks() throws {
        var p = DevelopmentAdjustmentsV3(light: .init(enabled: true, exposure: 0.7, shadows: -0.2),
            color: .init(enabled: true, saturation: 0.4), curves: .init(enabled: true),
            masks: [.init(name: "压暗前景", kind: .linear, adjustments: .init(exposure: -0.2))])
        p.curves.blue.curve = .init(points: [.init(x: 0, y: 0), .init(x: 0.3, y: 0.5), .init(x: 1, y: 1)])
        p.curves.red.inputBlack = 0.09
        let base = DevelopmentRecipe(adjustmentsV3: p)
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0
        patch.pointRed = .init(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)])
        let after = try XCTUnwrap(project(patch, on: base).adjustmentsV3)
        p.light.exposure = 0
        p.curves.red.curve = try XCTUnwrap(patch.pointRed)
        XCTAssertEqual(after, p)
        XCTAssertEqual(try project(patch, on: base, amount: 0), base)
    }

    func testCurvesAndWarmGradingCanBeCapturedAndMixedAcrossLegacyExposure() throws {
        var source = DevelopmentAdjustmentsV3()
        source.curves = .init(enabled: true, rgb: .init(curve: .init(points: [
            .init(x: 0,y: 0), .init(x: 0.5,y: 0.72), .init(x: 1,y: 1)])), algorithm: .naturalCubicGamma512LumaV1)
        source.legacyBasis = .init(version: .v2, color: .init(grading: .init(global: .init(hueDegrees: 45, saturation: 30))))
        let patch = try DevelopmentPresetPatch(capturing: .init(adjustmentsV3: source), fields: [.curves, .grading])
        var destination = DevelopmentRecipe(exposureEV: 1.3)
        destination.crop = .init(x: 0.1, y: 0, width: 0.8, height: 1)
        XCTAssertTrue(patch.supportsAmount(from: destination))
        let mixed = try XCTUnwrap(project(patch, on: destination, amount: 0.5).adjustmentsV3)
        XCTAssertEqual(mixed.curves.rgb.curve.points[1].y, 0.61, accuracy: 1e-12)
        XCTAssertEqual(mixed.legacyBasis?.color?.grading.global.hueDegrees, 45)
        XCTAssertEqual(mixed.legacyBasis?.color?.grading.global.saturation, 15)
        XCTAssertEqual(mixed.legacyBasis?.exposureEV, 1.3)
        XCTAssertEqual(mixed.geometry.crop, destination.crop)
        XCTAssertEqual(try project(patch, on: destination, amount: 0), destination)
    }

    func testLegacyExposureAndToneStaySparseInTheOriginalRenderStage() throws {
        var old = try DevelopmentRecipe(exposureEV: 1.5).promotingToV2()
        old.color?.tones.highlights = -35
        old.color?.tones.shadows = 40
        let patch = try DevelopmentPresetPatch(capturing: old, fields: [.exposure, .highlights])
        XCTAssertEqual(patch.fields, [.exposure, .highlights])
        XCTAssertEqual(patch.exposure, 0)
        var destination = try DevelopmentRecipe(exposureEV: -0.5).promotingToV2()
        destination.color?.tones.shadows = -16
        let after = try XCTUnwrap(project(patch, on: destination, amount: 0.5).adjustmentsV3)
        XCTAssertEqual(after.legacyBasis?.exposureEV, 0.5)
        XCTAssertEqual(after.legacyBasis?.color?.tones.highlights, -17.5)
        XCTAssertEqual(after.legacyBasis?.color?.tones.shadows, -16)
        XCTAssertEqual(after.light, .init())
        XCTAssertEqual(try project(patch, on: destination, amount: 0), destination)
    }

    func testCapturePromotedLegacyAndActiveV3StagesWithoutEnablingDormantGroups() throws {
        var old = try DevelopmentRecipe(exposureEV: 1).promotingToV2()
        old.color?.curves.red = .init(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.7), .init(x: 1, y: 1)])
        let promoted = try old.promotingToV3().applying(.setParameters(.color(.init(enabled: true, saturation: 0.3))))
        let fields: Set<DevelopmentPresetField> = [.exposure, .curves]
        let fromOld = try DevelopmentPresetPatch(capturing: old, fields: fields)
        let fromPromoted = try DevelopmentPresetPatch(capturing: promoted, fields: fields)
        XCTAssertEqual(fromOld, fromPromoted)
        let neutral = DevelopmentRecipe()
        XCTAssertEqual(try project(fromOld, on: neutral), try project(fromPromoted, on: neutral))
        var active = promoted
        active.adjustmentsV3?.light = .init(enabled: true, exposure: 0.5)
        let both = try DevelopmentPresetPatch(capturing: active, fields: fields)
        var destination = try DevelopmentRecipe(exposureEV: -1).promotingToV2()
        destination.color?.tones.shadows = 23
        let mixed = try XCTUnwrap(project(both, on: destination, amount: 0.5).adjustmentsV3)
        XCTAssertEqual(mixed.light.exposure, 0.25)
        XCTAssertEqual(mixed.legacyBasis?.exposureEV, 0)
        XCTAssertEqual(mixed.legacyBasis?.color?.tones.shadows, 23)
        var dormant = try destination.promotingToV3()
        dormant.adjustmentsV3?.light = .init(enabled: false, exposure: 0.9, shadows: -0.4)
        let zeroV3 = try XCTUnwrap(project(fromPromoted, on: dormant).adjustmentsV3)
        XCTAssertFalse(zeroV3.light.enabled)
        XCTAssertEqual(zeroV3.light.exposure, 0)
        XCTAssertEqual(zeroV3.light.shadows, -0.4)
    }

    func testConcurrentCatalogInstancesDoNotLoseUserRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    var patch = DevelopmentPresetPatch()
                    patch.exposure = Double(i) / 16
                    _ = try DevelopmentPresetCatalog(root: root).create(name: "风格 " + String(i), group: "试样", patch: patch)
                }
            }
            try await group.waitForAll()
        }
        let records = try DevelopmentPresetCatalog(root: root).records()
        XCTAssertEqual(records.count, 16)
        XCTAssertEqual(Set(records.map(\.id)).count, 16)
    }

    func testCatalogNativeRoundTripRevisionConflictsAndFrozenRecipeReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = DevelopmentPresetCatalog(root: root)
        let second = DevelopmentPresetCatalog(root: root)
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.65
        let original = try first.create(name: "打样", group: "用户", patch: patch)
        let applied = try project(original.patch, on: .init(exposureEV: -1))
        let document = try first.nativeData(for: original)
        XCTAssertEqual(try second.importNative(document), original)
        try first.toggleFavorite(original.id)
        let revised = try second.revise(original, name: "阴天", group: "旅行", patch: patch)
        XCTAssertEqual(revised.id, original.id)
        XCTAssertEqual(revised.version, 2)
        XCTAssertEqual(try first.favoriteIDs(), [original.id])
        XCTAssertThrowsError(try first.revise(original, name: "过期", group: "旅途", patch: patch))
        XCTAssertThrowsError(try second.importNative(document))
        let copy = try first.create(name: original.name, group: original.group, patch: patch, copiedFrom: revised)
        XCTAssertEqual(copy.metadata["parentID"], original.id)
        XCTAssertNotEqual(copy.id, original.id)
        try second.delete(revised)
        XCTAssertTrue(try first.favoriteIDs().isEmpty)
        let replay = try DevelopmentRecipe.decodeJSON(JSONEncoder().encode(applied))
        XCTAssertEqual(replay, applied)
        XCTAssertEqual(try first.importNative(document), original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: document) as? [String: Any])
        var row = try XCTUnwrap(json["preset"] as? [String: Any])
        var values = try XCTUnwrap(row["patch"] as? [String: Any])
        values["futureChannel"] = 42
        row["patch"] = values
        json["preset"] = row
        XCTAssertThrowsError(try first.importNative(JSONSerialization.data(withJSONObject: json)))
    }

    func testOverlappingAtomicImportReceiptsAndImmutableOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DevelopmentPresetCatalog(root: root)
        let bytes = Data("sample XMP".utf8), extra = Data("different XMP".utf8)
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        var row = DevelopmentPresetRecord(id: "first", name: "同名", group: "Imported", kind: .imported,
            patch: .init(), sourceSHA256: hash(bytes), blockingReasons: ["配置依赖"], metadata: ["uuid": "same"])
        let other = DevelopmentPresetRecord(id: "late", name: "同名", group: "Imported", kind: .look,
            patch: .init(), sourceSHA256: hash(extra), metadata: ["uuid": "same"])
        XCTAssertThrowsError(try store.importBatch([row, other], originals: [hash(bytes): bytes, hash(extra): extra], batchID: "failed"))
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertThrowsError(try store.importBatch([row], originals: [hash(bytes): extra], batchID: "wrong"))
        XCTAssertEqual(try store.importBatch([row], originals: [hash(bytes): bytes], batchID: "one"), [row.id])
        row.metadata["exchangeBatchID"] = "two"
        XCTAssertTrue(try store.importBatch([row], originals: [:], batchID: "two").isEmpty)
        XCTAssertEqual(try store.importBatchIDs(), ["one", "two"])
        try store.removeImportBatch("one")
        XCTAssertEqual(try store.records().count, 1)
        XCTAssertThrowsError(try store.removeBatch(ids: [row.id], expectedHashes: [row.id: hash(bytes)]))
        try store.removeImportBatch("two")
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertEqual(try store.originalData(sha256: hash(bytes)), bytes)
        _ = try store.importBatch([row], originals: [:])
        _ = try store.importBatch([row], originals: [:], batchID: "legacy-and-new")
        try store.removeImportBatch("legacy-and-new")
        XCTAssertEqual(try store.records(), [row])
    }

    func testFullPresetRequiresOriginalSourceAndRejectsAISubjectPayload() throws {
        let patch = try DevelopmentPresetPatch(fullRecipe: .init(exposureEV: 1), sourceID: source)
        let row = DevelopmentPresetRecord(id: "same-source", name: "本张", group: "个人", kind: .user, patch: patch)
        XCTAssertNil(row.reason(for: source))
        XCTAssertNotNil(row.reason(for: String(repeating: "b", count: 64)))
        XCTAssertFalse(patch.supportsAmount(from: .init()))
        let withSubject = DevelopmentRecipe(adjustmentsV3: .init(masks: [.init(kind: .subject, subjectPNG: Data([1, 2, 3]))]))
        XCTAssertThrowsError(try DevelopmentPresetPatch(fullRecipe: withSubject, sourceID: source))
        XCTAssertEqual(try DevelopmentPresetPatch(capturing: withSubject, fields: [.exposure]).fullRecipe, nil)
    }
}
