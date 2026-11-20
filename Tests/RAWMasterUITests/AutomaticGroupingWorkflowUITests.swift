import AppKit
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

/// Fixed test proposals exercise the import/triage/project boundary, not grouping quality.
final class AutomaticGroupingWorkflowUITests: XCTestCase {
    struct Fixture {
        let root: URL
        let source: URL
        let library: URL
        let store: LibraryStore
        let defaults: UserDefaults
        init(names: [String] = ["01.jpg", "02.jpg", "03.jpg", "04.jpg"]) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterGroupingWorkflow-" + UUID().uuidString)
            source = root.appendingPathComponent("source")
            library = root.appendingPathComponent("library.sqlite")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZikAAAAASUVORK5CYII=")!
            for name in names { try bytes.write(to: source.appendingPathComponent(name)) }
            store = try LibraryStore(databaseURL: library)
            defaults = UserDefaults(suiteName: "RAWMasterGroupingWorkflow-" + UUID().uuidString)!
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func callback(kind: SequenceKind = .burst, ranges: [ClosedRange<Int>] = [0...1, 2...3]) -> ImportPostIngestCallback {
            let service = AutomaticGroupingService(store: store, analyzer: { input, _, _ in
                try AutomaticGroupingWorkflowUITests.analysis(input, kind: kind, ranges: ranges)
            })
            return { session, check, progress in
                await service.run(sessionID: session.id, checkCancellation: check, progress: progress)
            }
        }
    }
    static func analysis(_ input: AutomaticGroupingInput, kind: SequenceKind, ranges: [ClosedRange<Int>]) throws -> AutomaticGroupingAnalysis {
        let camera = SequenceCameraEvidence.verifiedDevice(opaqueID: "fixed-test-camera", source: "test", validationVersion: "v1")
        let manifest = try SequenceInputManifest(scopeID: "automatic-grouping/" + input.sessionID,
            sessionID: input.sessionID, orderVersion: SequenceBaseOrder.version,
            entries: input.assets.enumerated().map { index, asset in
                SequenceManifestEntry(assetID: asset.id, ordinal: index, contentHash: asset.contentHash,
                    evidenceRevision: input.assetRevisions[index], camera: camera)
            })
        let token = try SequenceAnalysisToken.make(manifest: manifest,
            versions: SequenceAnalysisVersions(extractor: "test", feature: "test", algorithm: "test", policy: "test", order: SequenceBaseOrder.version),
            policyFingerprint: SequenceFingerprint.digest(["fixed-test": 1]))
        let observations = manifest.entries.map { entry in
            SequenceAssetInput(entry: entry, evidence: SequenceCaptureEvidence(assetID: entry.assetID,
                contentHash: entry.contentHash!, extractorVersion: "test", evidenceRevision: entry.evidenceRevision,
                time: SequenceTimestampParser.parse(original: "2026:10:24 12:00:0\(entry.ordinal)", subseconds: "123", offset: nil)),
                clock: SequenceClockPartition(id: "test-clock", basis: .localCivil, derivationVersion: "test"))
        }
        let result = SequenceAnalysisResult(token: token, ranges: try ranges.map {
            SequenceDetectedRange(range: try SequenceOrdinalRange(first: $0.lowerBound, last: $0.upperBound), kind: kind,
                cameraPartitionID: camera.partitionID(manifestFingerprint: manifest.contentFingerprint)!, clockPartitionID: "test-clock")
        }, coverage: [.init(range: try SequenceOrdinalRange(first: 0, last: input.assets.count - 1), state: .complete)])
        return AutomaticGroupingAnalysis(runID: input.runID, scopeFingerprint: input.scopeFingerprint,
            manifest: manifest, result: result, observations: observations, featuresAvailable: input.assets.map { _ in true },
            sourceProofs: try input.assets.map {
                AutomaticGroupingSourceProof(assetID: $0.id, verifiedSHA256: $0.contentHash,
                    finalStamp: try AutomaticGroupingFileStamp.read(at: $0.resolvedURL), issue: nil)
            }, provenance: AutomaticGroupingProvenance(providerVersion: "fixed-test-ranges",
                analysisSHA256: try SequenceFingerprint.digest(result), associationHypothesisAssumed: false, reportPath: nil, warnings: []))
    }
    @MainActor func waitForImport(_ model: AppModel, expectingError: String? = nil) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isBusy, "Import and finite preview analysis must terminate")
        if let expectingError { XCTAssertTrue(model.errorMessage?.contains(expectingError) == true) }
        else { XCTAssertNil(model.errorMessage) }
    }
    @MainActor func start(_ fixture: Fixture, callback: @escaping ImportPostIngestCallback) async throws -> AppModel {
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: callback)
        model.startImport(source: fixture.source.path, destination: "", name: "Grouping Workflow", mode: .reference, projectID: nil)
        try await waitForImport(model)
        return model
    }

    @MainActor func testPostIngestGroupsStayInTriageThenAdmittedSearchReviewAndTagsRemainScoped() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = try await start(f, callback: f.callback())
        let session = try XCTUnwrap(model.sessions.first)
        XCTAssertTrue(model.isTriageScope); XCTAssertEqual(model.scope, .session)
        XCTAssertEqual(model.automaticGroupingRun?.state, .applied)
        XCTAssertEqual(model.triageSessionGroups.count, 2); XCTAssertTrue(model.visibleGroups.isEmpty)
        XCTAssertTrue(model.projects.isEmpty); XCTAssertFalse(model.canExport)
        let group = try XCTUnwrap(model.triageSessionGroups.first)
        model.selectTriageGroup(group.id)
        XCTAssertEqual(model.scope, .session); XCTAssertTrue(model.isTriageScope)
        XCTAssertEqual(model.scopedAssets.map(\.id), group.assetIDs)
        XCTAssertFalse(model.supportsProjectSearch)
        let excluded = try XCTUnwrap(model.scopedAssets.first)
        model.select(excluded); model.decide(.reject); model.decide(rating: 5)
        XCTAssertEqual(model.disposition(of: excluded.id), .excluded)
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.rating == 0 && $0.decision == .undecided })
        model.prepareCompletion(); model.acknowledgeManualCompletion(true)
        XCTAssertEqual(model.completionPreview?.admittedAssetIDs.count, 3, "Completion always includes the whole batch, not just the selected group")
        XCTAssertTrue(model.completeTriage())
        XCTAssertNil(model.triageGroupID); XCTAssertEqual(model.scope, .project)
        XCTAssertEqual(model.scopedAssets.count, 3)
        let publishedGroup = try XCTUnwrap(model.visibleGroups.first { $0.id == group.id })
        XCTAssertEqual(model.visibleGroupMemberCount(publishedGroup), 1)
        model.selectScope(.group, id: group.id)
        XCTAssertFalse(model.scopedAssets.contains { $0.id == excluded.id })
        let admitted = try XCTUnwrap(model.scopedAssets.first)
        model.editSearchQuery { $0.filename = admitted.filename }
        model.select(admitted); model.decide(.keep, rating: 4)
        model.prepareTagMutation(text: "reviewed", mode: .add, showSheet: false)
        XCTAssertTrue(model.applyTagMutation())
        XCTAssertTrue(model.isReviewed(admitted.id))
        XCTAssertEqual(try f.store.loadTags()[admitted.id], ["reviewed"])
        XCTAssertNil(try f.store.loadTags()[excluded.id])
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == excluded.id }?.rating, 0)
        let run = try XCTUnwrap(f.store.automaticGroupingRun(sessionID: session.id))
        model.selectScope(.project, id: session.projectID)
        XCTAssertTrue(model.previewGroup(.restore(commandID: try XCTUnwrap(run.commandID)), showSheet: false))
        let restoring = try XCTUnwrap(model.groupPreview)
        XCTAssertEqual(Set((restoring.before + restoring.after).flatMap(\.assetIDs)).count, 4, "Full-batch group restore must not trim the excluded historical member")
        XCTAssertTrue(model.applyGroupPreview())
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(try f.store.loadAdmissions().count, 3)
        XCTAssertEqual(try f.store.loadTags()[admitted.id], ["reviewed"])
        XCTAssertEqual(try f.store.loadAssets().first { $0.id == admitted.id }?.rating, 4)
        model.resume(session); try await waitForImport(model, expectingError: "初筛会话已关闭")
        XCTAssertTrue(model.groups.isEmpty, "A closed intake cannot be resumed or reapply a completed automatic pass")
        XCTAssertTrue(model.automaticGroupingSummary.contains("已撤销"))
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback())
        XCTAssertTrue(reopened.groups.isEmpty)
        reopened.selectScope(.project, id: session.projectID)
        XCTAssertEqual(reopened.scopedAssets.count, 3)
        XCTAssertEqual(reopened.projectProgress?.reviewedFiles, 1)
    }

    @MainActor func testPairPreviewAndActionsDoNotEscapeSelectedTriageGroupAndUndoFallsBackToBatch() async throws {
        let f = try Fixture(names: ["01.ARW", "01.JPG", "02.jpg", "03.jpg"]); defer { f.clean() }
        let model = try await start(f, callback: f.callback())
        let raw = try XCTUnwrap(model.assets.first { $0.filename.hasSuffix("ARW") })
        let jpeg = try XCTUnwrap(model.assets.first { $0.filename == "01.JPG" })
        _ = try f.store.confirmCapturePair(rawAssetID: raw.id, jpegAssetID: jpeg.id)
        let single = try f.store.commitGroupCommand(f.store.previewGroupCommand(.create(assetIDs: [raw.id], name: "RAW only", kind: "连拍")))
        model.reload()
        model.selectTriageGroup(try XCTUnwrap(single.after.first).id)
        XCTAssertEqual(model.browserAssets.map(\.id), [raw.id]); XCTAssertEqual(model.actionAssetIDs, [raw.id])
        XCTAssertEqual(model.previewAsset(for: raw).id, raw.id)
        model.actualPixels = true
        XCTAssertEqual(model.previewAsset(for: raw).id, raw.id)
        model.decide(.reject)
        XCTAssertEqual(model.disposition(of: raw.id), .excluded); XCTAssertEqual(model.disposition(of: jpeg.id), .pending)
        XCTAssertTrue(model.previewGroup(.restore(commandID: single.id), showSheet: false))
        XCTAssertTrue(model.applyGroupPreview())
        XCTAssertNil(model.triageGroupID); XCTAssertTrue(model.isTriageScope)
        XCTAssertEqual(model.scopedAssets.count, 4)
        XCTAssertTrue(model.selectedIDs.isSubset(of: Set(model.scopedAssets.map(\.id))))
        let session = try XCTUnwrap(model.sessions.first)
        let run = try XCTUnwrap(model.automaticGroupingRun)
        model.previewAutomaticGroupingRestore()
        XCTAssertNotNil(model.groupPreview)
        XCTAssertTrue(model.applyGroupPreview())
        XCTAssertTrue(model.groups.isEmpty)
        model.showGroupReview = false
        model.resume(session); try await waitForImport(model)
        XCTAssertTrue(model.groups.isEmpty, "Resuming an open intake does not repeat a successfully undone automatic pass")
        XCTAssertEqual(model.automaticGroupingRun?.runID, run.runID)
        XCTAssertTrue(model.automaticGroupingSummary.contains("已撤销"))
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback())
        XCTAssertTrue(reopened.isTriageScope); XCTAssertTrue(reopened.groups.isEmpty)
        reopened.resume(session); try await waitForImport(reopened)
        XCTAssertTrue(reopened.groups.isEmpty)
        XCTAssertEqual(reopened.automaticGroupingRun?.commandID, run.commandID)
    }

    @MainActor func testIntervalNecessaryMemberStillAppearsAsSequenceOnlyInWholeBatchCompletion() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = try await start(f, callback: f.callback(kind: .interval))
        let group = try XCTUnwrap(model.triageSessionGroups.first)
        model.selectTriageGroup(group.id)
        let excluded = try XCTUnwrap(model.scopedAssets.first)
        model.select(excluded); model.setTriage(.excluded)
        model.prepareCompletion(); model.acknowledgeManualCompletion(true)
        XCTAssertEqual(model.completionPreview?.admittedAssetIDs.count, 4)
        XCTAssertEqual(model.completionPreview?.sequenceOnlyAssetIDs, [excluded.id])
        XCTAssertTrue(model.completeTriage())
        XCTAssertTrue(model.isSequenceOnly(excluded.id)); XCTAssertEqual(model.projectProgress?.sequenceOnlyFiles, 1)
    }

    @MainActor func testFailedAndNoGroupPassRemainVisibleWithoutLosingImportedAssets() async throws {
        let f = try Fixture(); defer { f.clean() }
        let service = AutomaticGroupingService(store: f.store, analyzer: { _, _, _ in throw LibraryError.invalid("test metadata provider missing") })
        let failed = try await start(f, callback: { session, check, progress in
            await service.run(sessionID: session.id, checkCancellation: check, progress: progress)
        })
        XCTAssertEqual(failed.automaticGroupingRun?.state, .failed)
        XCTAssertTrue(failed.automaticGroupingSummary.contains("未完成"))
        XCTAssertTrue(failed.automaticGroupingDetails.contains("test metadata provider missing"))
        XCTAssertEqual(failed.scopedAssets.count, 4); XCTAssertTrue(failed.groups.isEmpty)
        XCTAssertTrue(failed.isTriageScope); XCTAssertFalse(failed.canRestoreAutomaticGrouping)
        let noGroups = try Fixture(); defer { noGroups.clean() }
        let completed = try await start(noGroups, callback: noGroups.callback(ranges: []))
        XCTAssertEqual(completed.automaticGroupingRun?.state, .completedNoGroups)
        XCTAssertTrue(completed.automaticGroupingSummary.contains("未生成组"))
        XCTAssertEqual(completed.scopedAssets.count, 4)
    }

    @MainActor func testAutomaticRunUsesExactRestoreStatusBeyondRecentHistoryWindow() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = try await start(f, callback: f.callback())
        let run = try XCTUnwrap(model.automaticGroupingRun)
        let commandID = try XCTUnwrap(run.commandID)
        _ = try f.store.undoGroupCommand(id: commandID)
        let assetID = try XCTUnwrap(model.assets.first).id
        let manual = try f.store.commitGroupCommand(f.store.previewGroupCommand(.create(assetIDs: [assetID], name: "Later manual group", kind: "连拍")))
        let groupID = try XCTUnwrap(manual.after.first).id
        for index in 0..<55 {
            _ = try f.store.commitGroupCommand(f.store.previewGroupCommand(.rename(groupID: groupID, name: "Later edit \(index)")))
        }
        model.reload()
        XCTAssertFalse(model.groupHistory.contains { $0.id == commandID })
        XCTAssertEqual(model.automaticGroupingCommand?.id, commandID)
        XCTAssertTrue(model.automaticGroupingSummary.contains("已撤销"))
        XCTAssertFalse(model.canRestoreAutomaticGrouping)
    }

    @MainActor func testRestartWithUnfinishedRunDoesNotClaimThisProcessIsStillGrouping() async throws {
        let f = try Fixture(); defer { f.clean() }
        let session = try await ImportService(store: f.store).importDirectory(source: f.source, destination: nil,
            projectName: "Interrupted grouping", mode: .reference, initialScreening: true, progress: { _ in })
        _ = try XCTUnwrap(f.store.claimAutomaticGrouping(sessionID: session.id))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: session.id)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.automaticGroupingRun?.state, .running)
        XCTAssertTrue(model.automaticGroupingSummary.contains("记录未完成"))
        XCTAssertFalse(model.automaticGroupingSummary.contains("正在"))
        let reopened = AppModel(libraryURL: f.library, defaults: f.defaults)
        XCTAssertEqual(reopened.scope, .session)
        XCTAssertEqual(reopened.automaticGroupingRun?.state, .running)
        XCTAssertTrue(reopened.automaticGroupingSummary.contains("记录未完成"))
        XCTAssertEqual(try f.store.automaticGroupingRun(sessionID: session.id)?.state, .running, "Presentation must not rewrite the ledger or guess another process's outcome")
        XCTAssertEqual(reopened.scopedAssets.count, 4)
    }

    @MainActor func testThirtyThousandPairedMetadataChecksStayBoundedWithManyTriageGroups() throws {
        let f = try Fixture(names: []); defer { f.clean() }
        let session = try f.store.prepareImportSession(root: f.source, destination: nil, mode: .reference,
            projectName: "Synthetic metadata only", projectID: nil, initialScreening: true)
        let pairCount = 15_000
        var pairs: [CapturePair] = []
        // Bulk-load metadata only: no files, decoding, thumbnails or grouping analysis are involved.
        try f.store.transaction {
            for index in 0..<pairCount {
                let rawID = "raw-\(index)", jpegID = "jpeg-\(index)"
                for (id, suffix) in [(rawID, "ARW"), (jpegID, "JPG")] {
                    let name = String(format: "%05d.%@", index, suffix)
                    let asset = AssetRecord(id: id, sessionID: session.id, projectID: session.projectID,
                        sourcePath: f.source.appendingPathComponent(name).path, fileSize: 1, importState: .ready)
                    try f.store.statement("INSERT INTO assets(id,session_id,source_path,data) VALUES(?,?,?,?)",
                        [id, session.id, asset.sourcePath, try f.store.json(asset)])
                }
                let pair = CapturePair(id: "pair-\(index)", sessionID: session.id, rawAssetID: rawID, jpegAssetID: jpegID, isManual: false)
                try f.store.statement("INSERT INTO capture_pairs(id,data) VALUES(?,?)", [pair.id, try f.store.json(pair)])
                pairs.append(pair)
            }
        }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        // The published group list is a synthetic UI snapshot; no group command or baseline is altered.
        model.groups = pairs.prefix(7_500).map { pair in
            CaptureGroup(id: "group-" + pair.id, projectID: session.projectID, name: "Synthetic pair", assetIDs: pair.assetIDs, includedAssetIDs: pair.assetIDs)
        }
        let crossing = CaptureGroup(id: "crossing", projectID: session.projectID, name: "Single members",
            assetIDs: [pairs[0].rawAssetID, pairs[1].rawAssetID])
        model.groups.append(crossing)
        model.selectScope(.session, id: session.id)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(model.browserAssets.count, pairCount)
        XCTAssertTrue(pairs.allSatisfy { model.pairIsEntirelyVisible($0) && model.collapses($0) })
        model.selectTriageGroup(crossing.id)
        for _ in 0..<pairCount {
            XCTAssertEqual(model.activeTriageGroup?.id, crossing.id)
            XCTAssertFalse(model.pairIsEntirelyVisible(pairs[0]))
            XCTAssertFalse(model.collapses(pairs[0]))
        }
        XCTAssertEqual(Set(model.browserAssets.map(\.id)), Set(crossing.assetIDs))
        model.selectTriageGroup(nil)
        XCTAssertTrue(model.pairIsEntirelyVisible(pairs[0]))
        let seconds = ProcessInfo.processInfo.systemUptime - start
        print("TRIAGE_PAIRED_METADATA_CHECK_SECONDS \(seconds)")
        XCTAssertLessThan(seconds, 3, "Full-session and selected-group pair checks must not rebuild 30k-member sets or scan all groups for every card")
    }

    @MainActor func testScopeGuardRejectsOtherStagingSessionAndStaleGroupPreview() async throws {
        let f = try Fixture(); defer { f.clean() }
        let model = try await start(f, callback: f.callback())
        let session = try XCTUnwrap(model.sessions.first)
        let first = try XCTUnwrap(model.triageSessionGroups.first)
        let otherSource = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherSource, withIntermediateDirectories: true)
        try Data("other test asset".utf8).write(to: otherSource.appendingPathComponent("other.jpg"))
        let other = try await ImportService(store: f.store).importDirectory(source: otherSource, destination: nil, projectName: "Other", mode: .reference, projectID: session.projectID, initialScreening: true, progress: { _ in })
        let otherAsset = try XCTUnwrap(f.store.loadAssets(sessionID: other.id).first)
        let otherGroup = try XCTUnwrap(f.store.commitGroupCommand(f.store.previewGroupCommand(.create(assetIDs: [otherAsset.id], name: "Other staging", kind: "连拍"))).after.first)
        model.reload()
        XCTAssertFalse(model.manageableGroups.contains { $0.id == otherGroup.id })
        XCTAssertFalse(model.previewGroup(.merge(groupIDs: [first.id, otherGroup.id], name: "Unsafe", kind: "连拍"), showSheet: false))
        XCTAssertTrue(model.previewGroup(.rename(groupID: first.id, name: "Prepared in A"), showSheet: false))
        model.selectScope(.session, id: other.id)
        XCTAssertFalse(model.applyGroupPreview(), "A preview cannot commit from another session")
        model.showGroupReview = false
        model.selectScope(.group, id: first.id)
        XCTAssertTrue(model.scopedAssets.isEmpty)
        model.selectedIDs = [first.assetIDs[0]]; model.focusedID = first.assetIDs[0]
        model.decide(.keep, rating: 5)
        XCTAssertTrue(try f.store.loadAssets().allSatisfy { $0.rating == 0 && $0.decision == .undecided })
    }
}
