import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class TriageWorkflowUITests: XCTestCase {
    struct Fixture {
        let root: URL
        let source: URL
        let library: URL
        let store: LibraryStore
        let defaults: UserDefaults
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterTriageUI-" + UUID().uuidString)
            source = root.appendingPathComponent("source")
            library = root.appendingPathComponent("library.sqlite")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            store = try LibraryStore(databaseURL: library)
            defaults = UserDefaults(suiteName: "RAWMasterTriageUI-" + UUID().uuidString)!
        }
        func populate(names: [String] = ["001.jpg", "002.jpg", "003.jpg"], projectID: String? = nil) async throws -> ImportSession {
            let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZikAAAAASUVORK5CYII=")!
            for name in names { try data.write(to: source.appendingPathComponent(name)) }
            return try await ImportService(store: store).importDirectory(source: source, destination: nil, projectName: "Triage", mode: .reference, projectID: projectID, initialScreening: true, progress: { _ in })
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor func testStagingIsolatedAndCompletionPreservesFineDecisionsAndHistoryRecovery() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(model.scopedAssets.isEmpty)
        XCTAssertFalse(model.canExport)
        model.selectScope(.project, id: session.projectID)
        XCTAssertTrue(model.scopedAssets.isEmpty)
        model.selectScope(.session, id: session.id)
        XCTAssertTrue(model.isTriageScope)
        let excluded = try XCTUnwrap(model.scopedAssets.first)
        model.select(excluded); model.decide(.reject)
        XCTAssertEqual(model.disposition(of: excluded.id), .excluded)
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == excluded.id }?.decision, .undecided)
        model.undo()
        XCTAssertEqual(model.disposition(of: excluded.id), .pending)
        model.setTriage(.excluded)
        model.prepareCompletion()
        XCTAssertFalse(try XCTUnwrap(model.completionPreview).canCommit)
        model.acknowledgeManualCompletion(true)
        XCTAssertEqual(model.completionPreview?.admittedAssetIDs.count, 2)
        XCTAssertTrue(model.completeTriage())
        XCTAssertEqual(model.scope, .project)
        XCTAssertEqual(model.scopedAssets.count, 2)
        XCTAssertTrue(model.scopedAssets.allSatisfy { $0.decision == .undecided && $0.rating == 0 })
        XCTAssertTrue(model.activeSessions.isEmpty)
        XCTAssertEqual(model.historicalSessions.map(\.id), [session.id])
        let kept = try XCTUnwrap(model.scopedAssets.first)
        model.select(kept); model.decide(.keep, rating: 5); model.updateTags("wildlife, trip")
        model.selectScope(.session, id: session.id)
        XCTAssertTrue(model.isHistoryScope)
        XCTAssertFalse(model.canExport)
        model.select(excluded); model.decide(.keep, rating: 1)
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == excluded.id }?.decision, .undecided)
        model.restoreSelectedFromHistory()
        XCTAssertEqual(model.scope, .project)
        XCTAssertEqual(model.scopedAssets.count, 3)
        XCTAssertEqual(model.assets.first { $0.id == kept.id }?.rating, 5)
        XCTAssertEqual(model.assetTags[kept.id], ["trip", "wildlife"])
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.scopedAssets.count, 3)
        XCTAssertTrue(reopened.activeSessions.isEmpty)
    }

    @MainActor func testPairCollapsedActionAndExpandedSingleFileExceptionsRemainExplicit() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["SHOT.ARW", "SHOT.JPG"])
        let assets = try f.store.loadAssets()
        let raw = try XCTUnwrap(assets.first { $0.filename.hasSuffix("ARW") })
        let jpeg = try XCTUnwrap(assets.first { $0.filename.hasSuffix("JPG") })
        let pair = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        XCTAssertEqual(model.scopeCaptureCount, 1)
        XCTAssertEqual(model.scopedAssets.count, 2)
        XCTAssertEqual(model.browserAssets.map(\.id), [jpeg.id])
        model.select(jpeg)
        XCTAssertEqual(Set(model.actionAssetIDs), Set([raw.id, jpeg.id]))
        XCTAssertEqual(model.previewAsset(for: jpeg).id, jpeg.id)
        model.actualPixels = true
        XCTAssertEqual(model.previewAsset(for: jpeg).id, raw.id)
        model.actualPixels = false
        model.setTriage(.passed)
        XCTAssertTrue(try f.store.loadTriageRecords().allSatisfy { $0.disposition == .passed })
        model.decide(rating: 5)
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.rating == 0 })
        model.togglePair(pair)
        XCTAssertEqual(model.browserAssets.count, 2)
        model.select(raw); model.setTriage(.excluded)
        XCTAssertEqual(model.disposition(of: raw.id), .excluded)
        XCTAssertEqual(model.disposition(of: jpeg.id), .passed)
        XCTAssertTrue(model.pairHasConflict(pair))
        model.triageFilter = .excluded
        XCTAssertEqual(model.browserAssets.map(\.id), [raw.id])
        XCTAssertEqual(model.actionAssetIDs, [raw.id])
    }

    @MainActor func testReviewCountAndStaleSummaryRequireNewExplicitAcknowledgement() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        model.setTriage(.review)
        model.prepareCompletion(); model.acknowledgeManualCompletion(true)
        XCTAssertEqual(model.completionPreview?.reviewAssetIDs.count, 1)
        let other = try XCTUnwrap(model.scopedAssets.last)
        _ = try f.store.updateTriage(ids: [other.id], disposition: .excluded)
        XCTAssertFalse(model.completeTriage())
        XCTAssertTrue(model.isTriageScope)
        model.prepareCompletion()
        XCTAssertFalse(try XCTUnwrap(model.completionPreview).manualAnalysisAcknowledged)
    }

    @MainActor func testTriageNumberKeysAndModalKeysDoNotWriteFineSelection() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        func key(_ text: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0)!
        }
        XCTAssertFalse(model.handleKey(key("5")))
        model.showCompletion = true
        XCTAssertFalse(model.handleKey(key("x")))
        model.showCompletion = false
        XCTAssertTrue(model.handleKey(key("p")))
        XCTAssertEqual(model.disposition(of: try XCTUnwrap(model.focusedID)), .passed)
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.rating == 0 && $0.decision == .undecided })
    }
    @MainActor func testRiskReviewPreservesAllHumanDispositionsAndNecessarySequenceInputs() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg"])
        let assets = try f.store.loadAssets()
        _ = try f.store.updateTriage(ids: [assets[0].id], disposition: .passed)
        _ = try f.store.updateTriage(ids: [assets[1].id], disposition: .excluded)
        _ = try f.store.updateTriage(ids: [assets[2].id], disposition: .review)
        try f.store.createGroup(ids: [assets[3].id], name: "Necessary", kind: "间隔")
        for asset in assets {
            try f.store.saveQualityEvidence(TriageQualityEvidence(assetID: asset.id, contentHash: asset.contentHash, fileSize: asset.fileSize,
                source: "synthetic-test", methodVersion: "test-1", status: .risk, reasons: ["synthetic-risk"]))
        }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        model.applyRiskReview()
        XCTAssertEqual(model.disposition(of: assets[0].id), .passed)
        XCTAssertEqual(model.disposition(of: assets[1].id), .excluded)
        XCTAssertEqual(model.disposition(of: assets[2].id), .review)
        XCTAssertEqual(model.disposition(of: assets[3].id), .pending)
        XCTAssertEqual(model.disposition(of: assets[4].id), .review)
    }

    @MainActor func testProjectPreviewAndActionsDoNotPullUnadmittedPairMember() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["SHOT.ARW", "SHOT.JPG"])
        let assets = try f.store.loadAssets()
        let raw = try XCTUnwrap(assets.first { $0.filename.hasSuffix("ARW") })
        let jpeg = try XCTUnwrap(assets.first { $0.filename.hasSuffix("JPG") })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        _ = try f.store.updateTriage(ids: [raw.id], disposition: .excluded)
        _ = try f.store.commitCompletion(f.store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID)
        XCTAssertEqual(model.browserAssets.map(\.id), [jpeg.id])
        model.select(jpeg); model.actualPixels = true
        XCTAssertEqual(model.previewAsset(for: jpeg).id, jpeg.id)
        XCTAssertEqual(model.actionAssetIDs, [jpeg.id])
        model.decide(.keep, rating: 4)
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == raw.id }?.rating, 0)
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == jpeg.id }?.rating, 4)
    }

    @MainActor func testComparisonSwitchesCollapsedPairsToRAWWithoutChangingSelectionAndHonoursExpandedFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["A.ARW", "A.JPG", "B.ARW", "B.JPG"])
        let assets = try f.store.loadAssets()
        func asset(_ name: String) throws -> AssetRecord { try XCTUnwrap(assets.first { $0.filename == name }) }
        let rawA = try asset("A.ARW"), jpegA = try asset("A.JPG")
        let rawB = try asset("B.ARW"), jpegB = try asset("B.JPG")
        let pairA = try f.store.confirmCapturePair(rawAssetID: rawA.id, jpegAssetID: jpegA.id)
        _ = try f.store.confirmCapturePair(rawAssetID: rawB.id, jpegAssetID: jpegB.id)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        model.select(jpegA); model.select(jpegB, modifiers: .command); model.setMode(.compare)
        let selection = model.selectedIDs, focus = model.focusedID
        XCTAssertEqual(Set(model.comparisonPanels.map { $0.imageAsset.id }), [jpegA.id, jpegB.id])
        model.actualPixels = true
        XCTAssertEqual(Set(model.comparisonPanels.map { $0.imageAsset.id }), [rawA.id, rawB.id])
        XCTAssertEqual(Set(model.comparisonPanels.map(\.id)), selection)
        XCTAssertEqual(model.selectedIDs, selection)
        XCTAssertEqual(model.focusedID, focus)
        model.togglePair(pairA)
        XCTAssertEqual(model.comparisonPanels.first { $0.id == jpegA.id }?.imageAsset.id, jpegA.id,
                       "An explicitly expanded JPEG is an independent file, even in original-pixel comparison")
        XCTAssertEqual(model.comparisonPanels.first { $0.id == jpegB.id }?.imageAsset.id, rawB.id)
        XCTAssertEqual(model.selectedIDs, selection)
        XCTAssertEqual(model.focusedID, focus)
    }

    @MainActor func testPairScanRefreshMapsSingleSelectionToVisibleRepresentative() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["SHOT.ARW", "SHOT.JPG"])
        let assets = try f.store.loadAssets()
        let raw = try XCTUnwrap(assets.first { $0.filename.hasSuffix("ARW") })
        let jpeg = try XCTUnwrap(assets.first { $0.filename.hasSuffix("JPG") })
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id); model.select(raw)
        // A newly detected relation is persisted after the model's last snapshot.
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        model.scanPairs()
        for _ in 0..<200 where model.isBusy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.browserAssets.map(\.id), [jpeg.id])
        XCTAssertEqual(model.focusedID, jpeg.id)
        XCTAssertEqual(model.selectedIDs, [jpeg.id])
    }

    @MainActor func testFilterRoundTripMapsSingleCaptureButKeepsMultipleExplicitFilesVisible() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["A.ARW", "A.JPG", "B.ARW", "B.JPG"])
        let assets = try f.store.loadAssets()
        func asset(_ name: String) throws -> AssetRecord { try XCTUnwrap(assets.first { $0.filename == name }) }
        let rawA = try asset("A.ARW"), jpegA = try asset("A.JPG")
        let rawB = try asset("B.ARW"), jpegB = try asset("B.JPG")
        _ = try f.store.confirmCapturePair(rawAssetID: rawA.id, jpegAssetID: jpegA.id)
        _ = try f.store.confirmCapturePair(rawAssetID: rawB.id, jpegAssetID: jpegB.id)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        model.triageFilter = .pending; model.select(rawA); model.triageFilter = .all
        XCTAssertEqual(model.selectedIDs, [jpegA.id])
        XCTAssertEqual(model.focusedID, jpegA.id)
        model.triageFilter = .pending
        model.select(rawA); model.select(rawB, modifiers: .command)
        let selected = model.selectedIDs
        model.triageFilter = .all
        XCTAssertEqual(model.selectedIDs, selected)
        XCTAssertTrue(Set(model.browserAssets.map(\.id)).isSuperset(of: selected))
        XCTAssertEqual(Set(model.actionAssetIDs), selected, "Explicit multiple-file selections must not silently widen to both combinations")
        _ = try f.store.commitCompletion(f.store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true))
        model.reload(); model.selectScope(.project, id: session.projectID)
        model.expandedPairIDs.removeAll()
        model.filter = .undecided; model.select(rawA); model.filter = .all
        XCTAssertEqual(model.selectedIDs, [jpegA.id])
        XCTAssertEqual(model.focusedID, jpegA.id)
    }

    @MainActor func testSelectedOriginalFormatExportUsesCollapsedCombinationAndExpandedFileScope() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await f.populate(names: ["SHOT.ARW", "SHOT.JPG"])
        let assets = try f.store.loadAssets()
        let raw = try XCTUnwrap(assets.first { $0.filename.hasSuffix("ARW") })
        let jpeg = try XCTUnwrap(assets.first { $0.filename.hasSuffix("JPG") })
        let pair = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        _ = try f.store.commitCompletion(f.store.previewCompletion(sessionID: session.id, acknowledgeManualAnalysis: true))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: session.projectID); model.select(jpeg)
        let collapsed = try XCTUnwrap(model.exportSelection(ids: model.selectedExportAssets.map(\.id), formats: .allOriginals))
        XCTAssertEqual(Set(collapsed.assetIDs), Set([raw.id, jpeg.id]))
        XCTAssertEqual(collapsed.totalBytes, raw.fileSize + jpeg.fileSize)
        model.togglePair(pair); model.select(raw)
        let expanded = try XCTUnwrap(model.exportSelection(ids: model.selectedExportAssets.map(\.id), formats: .allOriginals))
        XCTAssertEqual(expanded.assetIDs, [raw.id])
        XCTAssertEqual(expanded.totalBytes, raw.fileSize)
    }

}
