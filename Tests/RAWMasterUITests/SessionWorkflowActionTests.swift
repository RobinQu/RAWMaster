import AppKit
import Combine
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class SessionWorkflowActionTests: XCTestCase {
    private actor Gate {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { if released { return }; await withCheckedContinuation { waiter = $0 } }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }
    private actor Probe {
        var counts: [Int] = []
        func record(_ count: Int) { counts.append(count) }
    }
    @MainActor private func waitForIdle(_ model: AppModel) async throws {
        let end = Date().addingTimeInterval(15)
        while model.isBusy && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isBusy, "Session task must join its worker")
        XCTAssertNil(model.sessionTask)
    }
    private func ingest(_ f: AutomaticGroupingWorkflowUITests.Fixture) async throws -> ImportSession {
        try await ImportService(store: f.store, postIngest: f.callback()).importDirectory(source: f.source,
            destination: nil, projectName: "Session actions", mode: .reference, initialScreening: true, progress: { _ in })
    }

    @MainActor func testExplicitRegroupUsesWholeBatchWhileBrowsingSubgroupAndKeepsTriageDecisions() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        let session = try await ingest(f), probe = Probe()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback(), regroupAnalyzer: { input, _, _ in
            await probe.record(input.assets.count)
            return try AutomaticGroupingWorkflowUITests.analysis(input, kind: .interval, ranges: [0...3])
        })
        model.selectScope(.session, id: session.id)
        let beforeIDs = Set(model.groups.map(\.id)), subgroup = try XCTUnwrap(model.triageSessionGroups.first)
        model.selectTriageGroup(subgroup.id)
        let excluded = try XCTUnwrap(model.scopedAssets.first)
        model.select(excluded); model.setTriage(.excluded)
        XCTAssertEqual(model.scopedAssets.count, 2); XCTAssertEqual(model.sessionBatchCounts(sessionID: session.id).fileCount, 4)
        XCTAssertNil(model.regroupDisabledReason(sessionID: session.id))
        model.regroup(sessionID: session.id)
        XCTAssertEqual(model.sessionTask?.kind, .grouping); XCTAssertEqual(model.sessionTask?.sessionID, session.id)
        try await waitForIdle(model)
        let counts = await probe.counts
        XCTAssertEqual(counts, [4]); XCTAssertEqual(model.groups.count, 1)
        XCTAssertTrue(beforeIDs.isDisjoint(with: model.groups.map(\.id)))
        XCTAssertEqual(model.disposition(of: excluded.id), .excluded)
        XCTAssertEqual(model.sessionBatchCounts(sessionID: session.id).excludedCount, 1)
        XCTAssertEqual(model.scope, .session); XCTAssertEqual(model.scopeID, session.id)
        XCTAssertNil(model.triageGroupID, "A replaced subgroup returns to the intact whole batch")
        XCTAssertEqual(model.undoCount, 2, "Triage edit and explicit regroup are two ordered actions")
        model.undo()
        XCTAssertEqual(Set(model.groups.map(\.id)), beforeIDs)
        XCTAssertEqual(model.disposition(of: excluded.id), .excluded, "The first undo restores groups, not the earlier triage decision")
        XCTAssertEqual(model.undoCount, 1)
        model.undo()
        XCTAssertEqual(model.disposition(of: excluded.id), .pending); XCTAssertEqual(model.undoCount, 0)
    }

    @MainActor func testEmptyReplacementHasRuntimeUndoButTrueNoopAddsNoUndoEntry() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        let session = try await ingest(f), oldIDs = Set(try f.store.loadGroups().map(\.id))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback(), regroupAnalyzer: { input, _, _ in
            try AutomaticGroupingWorkflowUITests.analysis(input, kind: .burst, ranges: [])
        })
        model.selectScope(.session, id: session.id)
        let photo = try XCTUnwrap(model.scopedAssets.first)
        model.select(photo); model.setTriage(.passed)
        model.regroup(sessionID: session.id); try await waitForIdle(model)
        XCTAssertTrue(model.groups.isEmpty); XCTAssertEqual(model.undoCount, 2)
        XCTAssertEqual(model.automaticGroupingRun?.state, .completedNoGroups)
        XCTAssertNotNil(model.automaticGroupingRun?.commandID, "Empty deletion still has a committed undo command")
        model.undo()
        XCTAssertEqual(Set(model.groups.map(\.id)), oldIDs)
        XCTAssertEqual(model.disposition(of: photo.id), .passed)
        model.undo(); XCTAssertEqual(model.disposition(of: photo.id), .pending)
        let history = try f.store.loadGroupCommands().count
        // Manual undo protects the restored group structures; an empty rerun now changes no group.
        model.regroup(sessionID: session.id); try await waitForIdle(model)
        XCTAssertNil(model.automaticGroupingRun?.commandID)
        XCTAssertEqual(model.undoCount, 0); XCTAssertEqual(try f.store.loadGroupCommands().count, history)
        XCTAssertEqual(Set(model.groups.map(\.id)), oldIDs)
    }

    @MainActor func testCancelledRegroupRemainsBusyUntilWorkerJoinsAndRetainsPreviousRestoreReference() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        let session = try await ingest(f)
        let old = try XCTUnwrap(f.store.automaticGroupingRun(sessionID: session.id)), oldIDs = Set(try f.store.loadGroups().map(\.id))
        let gate = Gate(), entered = expectation(description: "regroup analyzer entered")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback(), regroupAnalyzer: { input, check, _ in
            entered.fulfill(); await gate.wait(); try check()
            return try AutomaticGroupingWorkflowUITests.analysis(input, kind: .burst, ranges: [0...3])
        })
        model.selectScope(.session, id: session.id); model.regroup(sessionID: session.id)
        await fulfillment(of: [entered], timeout: 5)
        model.cancelSessionTask()
        XCTAssertTrue(model.isBusy); XCTAssertTrue(model.sessionTask?.isCancelling == true)
        XCTAssertEqual(model.sessionTask?.kind, .grouping)
        XCTAssertTrue(model.regroupDisabledReason(sessionID: session.id)?.contains("停止") == true)
        XCTAssertEqual(Set(try f.store.loadGroups().map(\.id)), oldIDs)
        await gate.release(); try await waitForIdle(model)
        XCTAssertEqual(model.automaticGroupingRun?.state, .cancelled)
        XCTAssertEqual(model.automaticGroupingRun?.lastSuccess?.commandID, old.commandID)
        XCTAssertEqual(model.automaticGroupingCommand?.id, old.commandID)
        XCTAssertTrue(model.canRestoreAutomaticGrouping, "Latest cancellation does not hide the retained successful command")
        XCTAssertEqual(Set(try f.store.loadGroups().map(\.id)), oldIDs)
    }

    @MainActor func testDefaultPostIngestUsesTypedGroupingStageThenStartsQualityAfterIntakeJoins() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        let entered = expectation(description: "post-ingest callback entered"), gate = Gate(), callback = f.callback()
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: { session, check, progress in
            entered.fulfill(); await gate.wait(); await callback(session, check, progress)
        })
        var kinds: [SessionTaskKind] = []
        var qualityStartedAfterImportJoin = false
        let observation = model.$sessionTask.sink { task in
            if let task { kinds.append(task.kind); if task.kind == .quality { qualityStartedAfterImportJoin = model.runningImportSessionID == nil } }
        }
        model.startImport(source: f.source.path, destination: "", name: "Typed stages", mode: .reference, projectID: nil)
        await fulfillment(of: [entered], timeout: 5)
        let deadline = Date().addingTimeInterval(2)
        while model.sessionTask?.kind != .grouping && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(model.sessionTask?.kind, .grouping)
        XCTAssertEqual(model.sessionTask?.sessionID, model.sessions.first?.id)
        XCTAssertEqual(model.sessionPresentation(try XCTUnwrap(model.sessions.first)).primaryAction, .cancelGrouping)
        await gate.release(); try await waitForIdle(model)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(kinds.contains(.intake)); XCTAssertTrue(kinds.contains(.grouping)); XCTAssertTrue(kinds.contains(.quality))
        XCTAssertTrue(qualityStartedAfterImportJoin)
    }

    @MainActor func testIncompleteIntakeOffersContinueAndCompletionReviewButCannotRegroup() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        var session = try await ingest(f)
        session.status = "partial"; session.scanCompleted = false; try f.store.saveSession(session)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback())
        model.selectScope(.session, id: session.id)
        XCTAssertTrue(model.canContinueIntake(sessionID: session.id)); XCTAssertFalse(model.canRescanSource(sessionID: session.id))
        XCTAssertTrue(model.canFinishSession(sessionID: session.id), "Completion review remains available to resolve excluded/unverified cases")
        XCTAssertTrue(model.regroupDisabledReason(sessionID: session.id)?.contains("继续接入") == true)
        let previous = model.automaticGroupingRun?.runID
        model.regroup(sessionID: session.id)
        XCTAssertFalse(model.isBusy); XCTAssertNil(model.sessionTask)
        model.continueIntake(sessionID: session.id); try await waitForIdle(model)
        XCTAssertFalse(model.canContinueIntake(sessionID: session.id)); XCTAssertTrue(model.canRescanSource(sessionID: session.id))
        XCTAssertNil(model.regroupDisabledReason(sessionID: session.id))
        XCTAssertEqual(model.automaticGroupingRun?.runID, previous, "Continue uses the default once-success callback, not explicit rerun")
    }

    @MainActor func testRescanFromCatalogRegistersNewSourceWithoutImplicitRegroupAndPreservesDisposition() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        let session = try await ingest(f), oldIDs = Set(try f.store.loadGroups().map(\.id))
        let oldRun = try XCTUnwrap(f.store.automaticGroupingRun(sessionID: session.id))
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: f.callback(), regroupAnalyzer: { _, _, _ in
            XCTFail("Source rescan must not invoke explicit regroup"); throw LibraryError.cancelled
        })
        model.selectScope(.session, id: session.id)
        let selected = try XCTUnwrap(model.assets.first)
        model.select(selected); model.setTriage(.passed)
        try FileManager.default.copyItem(at: selected.resolvedURL, to: f.source.appendingPathComponent("05.jpg"))
        model.openImportCatalog(); model.rescanSource(sessionID: session.id)
        XCTAssertEqual(model.scope, .session); XCTAssertEqual(model.scopeID, session.id)
        try await waitForIdle(model)
        XCTAssertEqual(model.sessionBatchCounts(sessionID: session.id).fileCount, 5)
        XCTAssertEqual(model.disposition(of: selected.id), .passed)
        XCTAssertEqual(Set(model.groups.map(\.id)), oldIDs)
        XCTAssertEqual(model.automaticGroupingRun?.runID, oldRun.runID)
    }

    @MainActor func testExplicitlyExcludedUnverifiedFileCanStillCloseAndClosedHistoryCannotRegroup() async throws {
        let f = try AutomaticGroupingWorkflowUITests.Fixture(); defer { f.clean() }
        var session = try await ImportService(store: f.store).importDirectory(source: f.source, destination: nil,
            projectName: "Excluded failure", mode: .reference, initialScreening: true, progress: { _ in })
        var failed = try XCTUnwrap(f.store.loadAssets().first)
        failed.importState = .failed; failed.contentHash = nil; failed.availability = .missing; failed.error = "Synthetic unverified file"
        try f.store.saveImportAsset(failed)
        session.status = "partial"; session.failed = 1; session.completed -= 1; try f.store.saveSession(session)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: { _, _, _ in })
        model.selectScope(.session, id: session.id); model.select(failed); model.setTriage(.excluded)
        XCTAssertTrue(model.canFinishSession(sessionID: session.id))
        model.prepareCompletion()
        var draft = try XCTUnwrap(model.sealDraft)
        draft.confirmedFailures = true
        model.updateSealDraft(draft); model.acknowledgeManualCompletion(true)
        XCTAssertTrue(try XCTUnwrap(model.completionPreview).canCommit, model.errorMessage ?? "")
        XCTAssertTrue(model.completeTriage(), model.errorMessage ?? "")
        model.selectScope(.session, id: session.id)
        XCTAssertTrue(model.isHistoryScope); XCTAssertFalse(model.canContinueIntake(sessionID: session.id))
        XCTAssertFalse(model.canRescanSource(sessionID: session.id)); XCTAssertNotNil(model.regroupDisabledReason(sessionID: session.id))
        model.regroup(sessionID: session.id); XCTAssertFalse(model.isBusy)
    }

    @MainActor func testInterruptedLegacyImportCanContinueWithoutGainingExplicitRegroupPermission() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        var session = try await f.populate("Legacy", screening: true)
        try f.store.writeWorkflow(SessionWorkflow(sessionID: session.id, projectID: session.projectID, isNewProject: false, phase: .legacyHistory))
        session.status = "partial"; session.scanCompleted = false; try f.store.saveSession(session)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults, postIngest: { _, _, _ in })
        model.selectScope(.session, id: session.id)
        XCTAssertTrue(model.isHistoryScope); XCTAssertTrue(model.canContinueIntake(sessionID: session.id))
        XCTAssertEqual(model.sessionPresentation(session).primaryAction, .continueIntake)
        XCTAssertNotNil(model.regroupDisabledReason(sessionID: session.id)); XCTAssertFalse(model.canRescanSource(sessionID: session.id))
        model.continueIntake(sessionID: session.id); try await waitForIdle(model)
        XCTAssertEqual(model.sessions.first { $0.id == session.id }?.status, "completed")
        XCTAssertFalse(model.canContinueIntake(sessionID: session.id)); XCTAssertNotNil(model.regroupDisabledReason(sessionID: session.id))
    }
}
