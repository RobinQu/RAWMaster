import CSQLite
import Foundation
import XCTest
@testable import RAWMasterCore

final class ProjectReviewTests: XCTestCase {
  var root: URL!
  var database: URL!
  var store: LibraryStore!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectReview-" + UUID().uuidString)
    database = root.appendingPathComponent("library.sqlite")
    store = try LibraryStore(databaseURL: database)
  }
  override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }
  func batch(_ name: String = "Project", count: Int = 3, admitted: Bool = true) throws -> (ProjectRecord, [AssetRecord]) {
    let project = ProjectRecord(name: name)
    try store.saveProject(project)
    let session = ImportSession(projectID: project.id, projectName: name, sourcePath: root.appendingPathComponent(name).path, mode: .reference, status: "completed", discovered: count, completed: count, scanCompleted: true)
    try store.saveSession(session)
    if !admitted { try store.beginTriage(session, isNewProject: true) }
    let assets = try (0..<count).map { i in
      try store.register(AssetRecord(sessionID: session.id, projectID: project.id, sourcePath: root.appendingPathComponent("\(session.id)/\(i).JPG").path,
                                    filename: "Shot\(i).JPG", capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i * 3600)), camera: "Camera A", importState: .ready))
    }
    return (project, assets)
  }
  func testSearchCombinesEveryConditionAndNeverLeaksUnadmittedFiles() throws {
    let (_, assets) = try batch()
    let (_, staging) = try batch("Staging", count: 1, admitted: false)
    _ = try store.updateSelection(ids: [assets[1].id, staging[0].id], decision: .keep, rating: 4)
    try store.setTags(ids: [assets[1].id], tags: ["Bird", "Trip"])
    try store.markReviewed(ids: [assets[1].id], reviewed: true)
    var q = ProjectSearchQuery(filename: "shot1", camera: "camera a", minimumRating: 4, maximumRating: 5, tags: ["bird", "trip"], decision: .keep, availability: .available, review: .reviewed)
    XCTAssertEqual(try store.searchAssets(query: q).map(\.id), [assets[1].id])
    q.tags = ["Bird", "Missing"]
    XCTAssertTrue(try store.searchAssets(query: q).isEmpty)
    q.tagMatch = .any
    XCTAssertEqual(try store.searchAssets(query: q).map(\.id), [assets[1].id])
    XCTAssertEqual(try store.searchAssets(query: ProjectSearchQuery()).count, 3)
    XCTAssertThrowsError(try store.markReviewed(ids: [staging[0].id], reviewed: true))
    XCTAssertThrowsError(try store.previewTagMutation(ids: [staging[0].id], tags: ["No"]))
  }
  func testMissingMetadataDoesNotMatchAndPairMembersCannotSharePredicates() throws {
    let (_, assets) = try batch(count: 2)
    var raw = assets[0]; raw.filename = "Pair.DNG"; raw.rating = 5; raw.capturedAt = nil; raw.camera = nil
    try store.transaction { try store.changeAsset(raw, action: "fixture-metadata") }
    _ = try store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: assets[1].id)
    _ = try store.updateSelection(ids: [raw.id], decision: .keep, rating: 5)
    try store.setTags(ids: [assets[1].id], tags: ["Bird"])
    XCTAssertTrue(try store.searchAssets(query: ProjectSearchQuery(minimumRating: 5, tags: ["Bird"])).isEmpty)
    XCTAssertFalse(try store.searchAssets(query: ProjectSearchQuery(camera: "Camera A")).contains { $0.id == raw.id })
    XCTAssertFalse(try store.searchAssets(query: ProjectSearchQuery(capturedFrom: Date(timeIntervalSince1970: 0))).contains { $0.id == raw.id })
  }
  func testDateRangeIncludesWholeEndDayAndHonoursDSTWithoutInventingTimestamp() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
    let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 3, day: 8)))
    var query = ProjectSearchQuery()
    try query.setDateRange(startDay: day, endDay: day, timeZone: zone)
    XCTAssertEqual(query.capturedBefore!.timeIntervalSince(query.capturedFrom!), 23 * 3600)
    let (_, assets) = try batch(count: 3)
    var examples = assets
    examples[0].capturedAt = query.capturedFrom
    examples[1].capturedAt = query.capturedBefore!.addingTimeInterval(-0.001)
    examples[2].capturedAt = query.capturedBefore
    XCTAssertEqual(try AssetSearchEngine.filter(assets: examples, query: query, tags: [:], reviewedIDs: []).map(\.id), Array(assets.prefix(2)).map(\.id))
    var invalid = query; invalid.capturedFrom = invalid.capturedBefore
    XCTAssertThrowsError(try invalid.validate())
    var invalidDraft = query
    XCTAssertThrowsError(try invalidDraft.setDateRange(startDay: Date(timeIntervalSince1970: .nan), endDay: day, timeZone: zone))
    XCTAssertEqual(invalidDraft, query)
  }
  func testCameraPaddingAndWidthUseSameCanonicalRuleAsQuery() throws {
    let (_, values) = try batch(count: 1)
    var asset = values[0]; asset.camera = " ＳＯＮＹ Ａ１\u{0000}\n"
    XCTAssertEqual(AssetSearchEngine.cameraKey(asset.camera!), AssetSearchEngine.cameraKey("sony a1"))
    XCTAssertEqual(try AssetSearchEngine.filter(assets: [asset], query: ProjectSearchQuery(camera: "sony a1 "), tags: [:], reviewedIDs: []).count, 1)
  }
  func testNaturalAndMetadataSortRemainStableAndMissingTimeLast() throws {
    let (_, values) = try batch(count: 3)
    var assets = values
    assets[0].filename = "Shot10.JPG"; assets[1].filename = "Shot2.JPG"; assets[2].filename = "Shot1.JPG"
    assets[0].capturedAt = nil; assets[1].capturedAt = Date(timeIntervalSince1970: 2); assets[2].capturedAt = Date(timeIntervalSince1970: 1)
    XCTAssertEqual(try AssetSearchEngine.filter(assets: assets, query: ProjectSearchQuery(), tags: [:], reviewedIDs: [], sort: .original).map(\.id), assets.map(\.id))
    XCTAssertEqual(try AssetSearchEngine.filter(assets: assets, query: ProjectSearchQuery(), tags: [:], reviewedIDs: [], sort: .filename).map(\.id), [assets[2].id, assets[1].id, assets[0].id])
    XCTAssertEqual(try AssetSearchEngine.filter(assets: assets, query: ProjectSearchQuery(), tags: [:], reviewedIDs: [], sort: .capturedDescending).map(\.id), [assets[1].id, assets[2].id, assets[0].id])
  }
  func testReviewIsIndependentAndExplicitFineActionsPersistWithoutUndoingSeen() throws {
    let (project, assets) = try batch()
    _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5)
    XCTAssertTrue(try store.loadReviewRecords().isEmpty, "Legacy values are not proof of review")
    let changes = try store.updateSelection(ids: [assets[1].id], decision: .keep, rating: 3, markReviewed: true)
    try store.undoSelection(changes)
    XCTAssertTrue(try store.loadReviewRecords()[0].reviewed)
    XCTAssertEqual(try store.reviewProgress(projectID: project.id).reviewedFiles, 1)
    // Same-value explicit action still counts as a review.
    _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5, markReviewed: true)
    try store.markReviewed(ids: [assets[1].id], reviewed: false)
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.reviewProgress(projectID: project.id).reviewedFiles, 1)
    XCTAssertEqual(try store.loadAssets().first { $0.id == assets[0].id }?.rating, 5)
  }
  func testReviewProgressRequiresEveryPairMemberAndCountsSequenceRoleSeparately() throws {
    let (project, assets) = try batch(count: 2)
    var raw = assets[0]; raw.filename = "Pair.DNG"; try store.transaction { try store.changeAsset(raw, action: "fixture-format") }
    _ = try store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: assets[1].id)
    try store.markReviewed(ids: [raw.id], reviewed: true)
    let partial = try store.reviewProgress(projectID: project.id)
    XCTAssertEqual(partial.totalCaptures, 1); XCTAssertEqual(partial.reviewedCaptures, 0); XCTAssertEqual(partial.partiallyReviewedCaptures, 1)
    try store.markReviewed(ids: [assets[1].id], reviewed: true)
    XCTAssertEqual(try store.reviewProgress(projectID: project.id).reviewedCaptures, 1)
    try store.unlinkCapturePair(id: try XCTUnwrap(store.loadCapturePairs().first).id)
    XCTAssertEqual(try store.reviewProgress(projectID: project.id).reviewedCaptures, 2)
  }
  func testProjectStatesAreSeparateCASProtectedAndDropOutsideReferences() throws {
    let (a, aa) = try batch("A", count: 2), (b, bb) = try batch("B", count: 1)
    let stateA = ProjectReviewState(projectID: a.id, query: ProjectSearchQuery(filename: "Shot1"), sort: .ratingDescending, mode: "compare", focusedAssetID: aa[1].id, selectedAssetIDs: [aa[0].id, aa[1].id, bb[0].id])
    let saved = try store.saveProjectReviewState(stateA)
    XCTAssertEqual(Set(saved.selectedAssetIDs), Set(aa.map(\.id)))
    XCTAssertThrowsError(try store.saveProjectReviewState(stateA))
    _ = try store.saveProjectReviewState(ProjectReviewState(projectID: b.id, query: ProjectSearchQuery(minimumRating: 4), focusedAssetID: bb[0].id))
    store = nil; store = try LibraryStore(databaseURL: database)
    XCTAssertEqual(try store.loadProjectReviewState(projectID: a.id)?.query.filename, "Shot1")
    XCTAssertEqual(try store.loadProjectReviewState(projectID: b.id)?.query.minimumRating, 4)
    XCTAssertTrue(try store.loadReviewRecords().isEmpty)
  }
  func testBatchTagsPreserveUniqueValuesAndExposeCommonMixedWithExactPreview() throws {
    let (_, assets) = try batch(count: 2)
    try store.setTags(ids: [assets[0].id], tags: ["a", "b"])
    try store.setTags(ids: [assets[1].id], tags: ["b", "c"])
    let preview = try store.previewTagMutation(ids: assets.map(\.id), mode: .add, tags: ["d"])
    XCTAssertEqual(preview.commonTags, ["b"]); XCTAssertEqual(preview.mixedTags, ["a", "c"])
    _ = try store.commitTagMutation(preview)
    XCTAssertEqual(try store.loadTags()[assets[0].id], ["a", "b", "d"])
    XCTAssertEqual(try store.loadTags()[assets[1].id], ["b", "c", "d"])
    _ = try store.commitTagMutation(store.previewTagMutation(ids: assets.map(\.id), mode: .remove, tags: ["B"]))
    XCTAssertEqual(try store.loadTags()[assets[0].id], ["a", "d"])
    XCTAssertEqual(try store.loadTags()[assets[1].id], ["c", "d"])
    _ = try store.commitTagMutation(store.previewTagMutation(ids: assets.map(\.id), mode: .replace, tags: []))
    XCTAssertTrue(try store.loadTags().values.allSatisfy(\.isEmpty))
  }
  func testTagMutationCASRejectsAtomicBatchAfterLegacyAPIOrABAWrites() throws {
    let (_, assets) = try batch(count: 2)
    try store.setTags(ids: assets.map(\.id), tags: ["old"])
    let stale = try store.previewTagMutation(ids: assets.map(\.id), tags: ["new"])
    try store.setTags(ids: [assets[1].id], tags: ["other"])
    try store.setTags(ids: [assets[1].id], tags: ["old"])
    XCTAssertThrowsError(try store.commitTagMutation(stale))
    XCTAssertEqual(try store.loadTags()[assets[0].id], ["old"])
    XCTAssertEqual(try store.loadTags()[assets[1].id], ["old"])
  }
  func testTagIdempotenceAndContinuousLIFOUndoPersistAcrossRestart() throws {
    let (_, assets) = try batch(count: 1)
    let first = try store.commitTagMutation(store.previewTagMutation(ids: [assets[0].id], tags: ["a"]))
    let secondPreview = try store.previewTagMutation(ids: [assets[0].id], tags: ["b"])
    let second = try store.commitTagMutation(secondPreview)
    XCTAssertEqual(try store.commitTagMutation(secondPreview).id, second.id)
    XCTAssertEqual(try store.loadTagCommands().count, 2)
    store = nil; store = try LibraryStore(databaseURL: database)
    try store.undoTagMutation(commandID: second.id)
    try store.undoTagMutation(commandID: first.id)
    XCTAssertEqual(try store.loadTags()[assets[0].id], [])
    XCTAssertEqual(try store.tagDomain(assets[0].id).revision, 4)
    let c = try store.commitTagMutation(store.previewTagMutation(ids: [assets[0].id], tags: ["a"]))
    try store.setTags(ids: [assets[0].id], tags: ["b"])
    try store.setTags(ids: [assets[0].id], tags: ["a"])
    XCTAssertThrowsError(try store.undoTagMutation(commandID: c.id))
  }
  func testNoopReceiptIsIdempotentWithoutUndoEntryOrVersionChange() throws {
    let (_, assets) = try batch(count: 1)
    let preview = try store.previewTagMutation(ids: [assets[0].id], tags: [])
    _ = try store.commitTagMutation(preview)
    XCTAssertTrue(try store.loadTagCommands().isEmpty)
    XCTAssertEqual(try store.tagDomain(assets[0].id).revision, 0)
    try store.setTags(ids: [assets[0].id], tags: ["later"])
    store = nil; store = try LibraryStore(databaseURL: database)
    _ = try store.commitTagMutation(preview)
    XCTAssertEqual(try store.loadTags()[assets[0].id], ["later"])
  }
  func testUnicodeTagIdentityAndVocabularyAreScopedWithoutCleaningOldValues() throws {
    let (_, assets) = try batch(count: 1)
    try store.setTags(ids: [assets[0].id], tags: ["Bird", "é"])
    let before = try store.loadTags()[assets[0].id]
    let p = try store.previewTagMutation(ids: [assets[0].id], tags: [" bird ", "e\u{301}"])
    XCTAssertTrue(p.changedAssetIDs.isEmpty)
    _ = try store.commitTagMutation(p)
    XCTAssertEqual(try store.loadTags()[assets[0].id], before)
    XCTAssertEqual(try store.tagVocabulary(prefix: "bi"), ["Bird"])
    XCTAssertEqual(try store.searchAssets(query: ProjectSearchQuery(tags: ["E\u{301}"])).count, 1)
  }
  func testSchemaFourMigrationPreservesOldTagsAndDecisionsWithoutInventingReview() throws {
    let (_, assets) = try batch(count: 1)
    _ = try store.updateSelection(ids: [assets[0].id], decision: .keep, rating: 5)
    try store.setTags(ids: [assets[0].id], tags: ["Legacy"])
    let assetBefore = try store.rows("SELECT data FROM assets")
    let tagsBefore = try store.rows("SELECT data FROM asset_tags")
    try removeEditingSchemaForLegacyFixture(store)
    for table in ["asset_color_labels", "review_records", "project_review_states", "tag_commands", "tag_domains"] { try store.exec("DROP TABLE \(table)") }
    try store.exec("PRAGMA user_version=4")
    store = nil; store = try LibraryStore(databaseURL: database)
    let backup = try XCTUnwrap(store.lastMigrationBackupURL)
    var snapshot: OpaquePointer?
    XCTAssertEqual(sqlite3_open_v2(backup.path, &snapshot, SQLITE_OPEN_READONLY, nil), SQLITE_OK); defer { sqlite3_close(snapshot) }
    XCTAssertEqual(try DatabaseSchema.strings(snapshot, "PRAGMA user_version"), ["4"])
    XCTAssertEqual(try store.rows("SELECT data FROM assets"), assetBefore)
    XCTAssertEqual(try store.rows("SELECT data FROM asset_tags"), tagsBefore)
    XCTAssertTrue(try store.loadReviewRecords().isEmpty)
    XCTAssertTrue(try store.loadTagCommands().isEmpty)
    XCTAssertEqual(try store.tagDomain(assets[0].id), TagDomain())
    XCTAssertEqual(try DatabaseSchema.strings(store.db, "PRAGMA user_version"), ["7"])
  }
  func testThirtyThousandMetadataSearchAndPairedProgressRemainBounded() throws {
    let count = 30_000
    let assets = (0..<count).map { i in AssetRecord(id: "a\(i)", sessionID: "session", projectID: "project", sourcePath: "/unopened/\(i).JPG", filename: "Shot\(i).JPG", camera: i % 2 == 0 ? "A" : "B", rating: i % 6) }
    let tags = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset % 3 == 0 ? ["Bird"] : []) })
    let ids = Set(assets.map(\.id)), reviewed = Set(assets.prefix(count / 2).map(\.id))
    let pairs = stride(from: 0, to: count, by: 2).map { i in CapturePair(id: "p\(i)", sessionID: "session", rawAssetID: "a\(i)", jpegAssetID: "a\(i+1)", isManual: true) }
    let start = Date()
    let found = try AssetSearchEngine.filter(assets: assets, query: ProjectSearchQuery(camera: "A", minimumRating: 3, tags: ["Bird"]), tags: tags, reviewedIDs: reviewed)
    let progress = ReviewProgress.calculate(assetIDs: ids, reviewedIDs: reviewed, pairs: pairs)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertEqual(found.count, 0, "Multiples of six have zero stars; predicates cannot be unioned")
    XCTAssertEqual(progress.totalCaptures, 15_000)
    XCTAssertEqual(progress.reviewedCaptures, 7_500)
    XCTAssertEqual(progress.reviewedFiles, 15_000)
    print("007 metadata 30k files/15k pairs filter+progress: \(elapsed) seconds; no image IO")
  }
  func testAllowedExportFormatsCannotExpandToNonMatchingCompanionAndNilStaysCompatible() throws {
    let (_, assets) = try batch(count: 2)
    var raw = assets[0]; raw.filename = "Pair.DNG"
    try store.transaction { try store.changeAsset(raw, action: "fixture-format") }
    _ = try store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: assets[1].id)
    XCTAssertEqual(Set(try store.exportSelection(ids: [assets[1].id], formats: .both).assetIDs), Set(assets.map(\.id)))
    let scoped = try store.exportSelection(ids: [assets[1].id], formats: .both, allowedAssetIDs: [assets[1].id])
    XCTAssertEqual(scoped.assetIDs, [assets[1].id])
    XCTAssertEqual(scoped.missingFormats.count, 1)
    XCTAssertTrue(scoped.missingFormats[0].contains("当前交付范围没有RAW"))
    XCTAssertTrue(try store.exportSelection(ids: [assets[1].id], formats: .rawOnly, allowedAssetIDs: [assets[1].id]).assetIDs.isEmpty)
    XCTAssertTrue(try store.exportSelection(ids: [raw.id], formats: .jpegOnly, allowedAssetIDs: [raw.id]).assetIDs.isEmpty)
    XCTAssertThrowsError(try store.exportSelection(ids: [raw.id], formats: .both, allowedAssetIDs: [assets[1].id]))
  }
  func testAllowedExportRejectsManifestBypassAndClipsPersistedGroupContext() async throws {
    let (_, assets) = try batch(count: 2)
    var raw = assets[0]; raw.filename = "Pair.DNG"
    try store.transaction { try store.changeAsset(raw, action: "fixture-format") }
    _ = try store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: assets[1].id)
    try store.createGroup(ids: assets.map(\.id), name: "Pair group", kind: "连拍")
    let out = root.appendingPathComponent("delivery")
    do {
      _ = try await ExportService(store: store).exportAssets(ids: [assets[1].id], destination: out, manifestIDs: assets.map(\.id), formats: .both, allowedAssetIDs: [assets[1].id], progress: { _ in })
      XCTFail("Nonmatching companion must not leak through the manifest")
    } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: out.path)) }
    try FileManager.default.createDirectory(at: assets[1].resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("JPEG-original-bytes".utf8).write(to: assets[1].resolvedURL)
    let report = try await ExportService(store: store).exportAssets(ids: [assets[1].id], destination: out, manifestIDs: [assets[1].id], formats: .both, allowedAssetIDs: [assets[1].id], progress: { _ in })
    XCTAssertEqual(report.copied, 1); XCTAssertEqual(report.failed, 1)
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: URL(fileURLWithPath: report.manifestPath)))
    XCTAssertEqual(manifest.items.map(\.asset.id), [assets[1].id])
    XCTAssertEqual(manifest.allowedAssetIDs, [assets[1].id])
    XCTAssertEqual(manifest.groups.flatMap(\.assetIDs), [assets[1].id])
    XCTAssertEqual(manifest.groups.flatMap(\.includedAssetIDs), [assets[1].id])
  }
}
