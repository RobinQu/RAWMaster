import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class SessionWorkflowPresentationTests: XCTestCase {
    private func session(status: String = "completed", scanCompleted: Bool = true) -> ImportSession {
        ImportSession(id: "batch", projectID: "project", projectName: "秋季拍摄", sourcePath: "/photos/山谷日落与云层间隔拍摄",
            mode: .reference, status: status, discovered: 240, completed: 240, failed: status == "partial" ? 2 : 0, scanCompleted: scanCompleted)
    }
    private var counts: SessionBatchCounts {
        SessionBatchCounts(fileCount: 240, readyCount: 240, pendingCount: 36, passedCount: 188, excludedCount: 12, reviewCount: 4, groupCount: 2)
    }
    private func state(session: ImportSession? = nil, phase: TriagePhase = .screening,
                       counts: SessionBatchCounts? = nil, task: SessionTaskState? = nil,
                       canContinue: Bool = false, canFinish: Bool = true, regroupReason: String? = nil,
                       outcome: AutomaticGroupingRunState? = nil) -> SessionWorkflowPresentation {
        let source = session ?? self.session()
        return SessionWorkflowPresentation(session: source,
            workflow: SessionWorkflow(sessionID: source.id, projectID: source.projectID, isNewProject: true, phase: phase),
            counts: counts ?? self.counts, task: task,
            progress: TaskProgress(title: "This unrelated localized title must never determine the task", completed: 30, total: 240, message: "正在读取整批拍摄信息"),
            qualityMessage: "正在检查预览风险 · 30 / 240", canContinue: canContinue, canFinish: canFinish,
            canOpenProject: true, regroupDisabledReason: regroupReason, groupingState: outcome, automaticGroupCount: 2)
    }

    func testReadyHeaderHasOneWholeBatchCompletionActionAndNoInventedCompletionPercentage() {
        let value = state()
        XCTAssertEqual(value.primaryAction, .finish); XCTAssertEqual(value.primaryTitle, "完成整批初筛…")
        XCTAssertTrue(value.primaryEnabled); XCTAssertNil(value.regroupDisabledReason)
        XCTAssertTrue(value.batchSummary.contains("整批 240 个文件")); XCTAssertTrue(value.batchSummary.contains("待处理 36"))
        XCTAssertTrue(value.batchSummary.contains("待复核 4")); XCTAssertFalse(value.batchSummary.contains("%"))
        XCTAssertFalse(value.hasCurrentTask); XCTAssertNil(value.activityMessage)
    }

    func testIncompleteIntakeKeepsContinuePrimaryAndAccurateRegroupReasonWithoutDiscardingCompletionCapability() {
        let reason = "来源扫描尚未完成，请先继续接入。"
        let value = state(session: session(status: "partial", scanCompleted: false), canContinue: true,
                          canFinish: true, regroupReason: reason)
        XCTAssertEqual(value.primaryAction, .continueIntake); XCTAssertTrue(value.primaryEnabled)
        XCTAssertEqual(value.regroupDisabledReason, reason)
        XCTAssertFalse(value.isHistory)
    }

    func testPrimaryCancellationUsesTypedJobAndStaysDisabledWhileCancelling() {
        let actions: [(SessionTaskKind, SessionWorkflowPresentation.Action)] = [(.intake, .pauseIntake), (.grouping, .cancelGrouping), (.quality, .cancelQuality), (.pairing, .cancelPairing)]
        for (kind, expected) in actions {
            let active = state(task: SessionTaskState(kind: kind, sessionID: "batch"))
            XCTAssertEqual(active.primaryAction, expected); XCTAssertTrue(active.primaryEnabled)
            let cancelling = state(task: SessionTaskState(kind: kind, sessionID: "batch", isCancelling: true))
            XCTAssertFalse(cancelling.primaryEnabled); XCTAssertTrue(cancelling.hasCurrentTask)
            XCTAssertTrue(cancelling.primaryTitle.contains("正在"))
        }
    }

    func testOtherBatchTaskCannotMasqueradeAsCurrentGroupingOrProgress() {
        let value = state(task: SessionTaskState(kind: .grouping, sessionID: "other-batch"), canFinish: false,
                          regroupReason: "其他任务正在运行，请等待结束。")
        XCTAssertEqual(value.primaryAction, .finish); XCTAssertFalse(value.primaryEnabled)
        XCTAssertFalse(value.hasCurrentTask); XCTAssertNil(value.activityCompleted)
    }

    func testHistoryOpensProjectButInterruptedLegacyStillOffersSupportedContinue() {
        let history = state(phase: .closed, canFinish: false, regroupReason: "会话已关闭，历史记录只读。")
        XCTAssertTrue(history.isHistory); XCTAssertEqual(history.primaryAction, .openProject)
        XCTAssertFalse(history.batchSummary.contains("待处理"))
        let legacy = state(session: session(status: "cancelled", scanCompleted: false), phase: .legacyHistory,
                           canContinue: true, canFinish: false, regroupReason: "旧版记录不支持重新分组。")
        XCTAssertEqual(legacy.primaryAction, .continueIntake); XCTAssertTrue(legacy.primaryEnabled)
    }

    func testFinishedGroupingRetainsConciseSuccessFailureAndCancellationOutcomes() {
        XCTAssertTrue(state(outcome: .applied).groupingOutcomeText?.contains("2 个自动组") == true)
        XCTAssertTrue(state(outcome: .completedNoGroups).groupingOutcomeText?.contains("未识别到新的自动组") == true)
        XCTAssertTrue(state(outcome: .failed).groupingOutcomeText?.contains("已有拍摄组保留") == true)
        XCTAssertTrue(state(outcome: .cancelled).groupingOutcomeText?.contains("已取消") == true)
        XCTAssertNil(state(task: SessionTaskState(kind: .grouping, sessionID: "batch"), outcome: .running).groupingOutcomeText)
    }

    @MainActor func testGroupFilterLeavesPresentationCountsAtWholeBatchScope() async throws {
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let source = try await f.populate("SessionCounts", filenames: (1...8).map { "\($0).jpg" }, screening: true)
        let ids = try f.store.loadAssets().map(\.id)
        try f.store.createGroup(ids: Array(ids.prefix(3)), name: "子组", kind: "延时")
        let group = try XCTUnwrap(try f.store.loadGroups().first)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: source.id)
        let before = model.sessionPresentation(source)
        model.selectTriageGroup(group.id)
        model.triageFilter = .review
        let after = model.sessionPresentation(source)
        XCTAssertEqual(before.counts, after.counts)
        XCTAssertEqual(after.counts.fileCount, 8); XCTAssertEqual(model.scopedAssets.count, 3)
        XCTAssertTrue(model.filteredAssets.isEmpty)
        XCTAssertEqual(after.primaryAction, .finish)
    }

    @MainActor func testOptionalNativeSessionHeaderCaptures() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SESSION_WORKFLOW_CAPTURE_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_SESSION_WORKFLOW_CAPTURE_OUTPUT for session header state and narrow layout evidence")
        }
        _ = NSApplication.shared
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let source = try await f.populate("山谷日落与云层间隔拍摄", filenames: (1...12).map { "\($0).jpg" }, screening: true)
        let ids = try f.store.loadAssets().map(\.id)
        try f.store.createGroup(ids: Array(ids.prefix(3)), name: "日落子组", kind: "延时")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.session, id: source.id)
        let group = try XCTUnwrap(model.triageSessionGroups.first)
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let realCounts = model.sessionBatchCounts(sessionID: source.id)
        let workflow = try XCTUnwrap(model.activeWorkflow)
        func snapshot(_ session: ImportSession, task: SessionTaskState? = nil, history: Bool = false,
                      reason: String? = nil, outcome: AutomaticGroupingRunState? = .applied) -> SessionWorkflowPresentation {
            var stage = workflow
            if history { stage.phase = .closed }
            return SessionWorkflowPresentation(session: session, workflow: stage, counts: realCounts, task: task,
                progress: TaskProgress(title: "grouping", completed: 5, total: 12, message: "正在读取整批拍摄信息"),
                qualityMessage: "正在检查预览风险", canContinue: session.status != "completed", canFinish: true,
                canOpenProject: history, regroupDisabledReason: reason, groupingState: outcome, automaticGroupCount: 1)
        }
        try await capture(model, session: source, state: snapshot(source), width: 900, name: "ready", output: output)
        model.selectTriageGroup(group.id)
        try await capture(model, session: source, state: snapshot(source), width: 540, name: "group-filtered-narrow", output: output)
        model.selectTriageGroup(nil)
        var partial = source; partial.status = "partial"; partial.scanCompleted = false
        try await capture(model, session: partial, state: snapshot(partial, reason: "来源扫描尚未完成，请先继续接入。", outcome: nil), width: 540, name: "incomplete", output: output)
        try await capture(model, session: source, state: snapshot(source, task: SessionTaskState(kind: .grouping, sessionID: source.id), reason: "整批分组正在运行。", outcome: .running), width: 540, name: "grouping", output: output)
        try await capture(model, session: source, state: snapshot(source, task: SessionTaskState(kind: .grouping, sessionID: source.id, isCancelling: true), reason: "正在取消，请等待任务结束。", outcome: .running), width: 540, name: "cancelling", output: output)
        try await capture(model, session: source, state: snapshot(source, history: true, reason: "会话已关闭，历史记录只读。"), width: 540, name: "history", output: output)
    }

    @MainActor private func capture(_ model: AppModel, session: ImportSession, state: SessionWorkflowPresentation, width: CGFloat, name: String, output: URL) async throws {
        let content = VStack(spacing: 0) {
            SessionWorkflowHeader(session: session, presentation: state).padding(.horizontal, 18)
            Divider()
            if !state.isHistory { TriageStatusStrip() }
        }.environmentObject(model).frame(width: width, height: 390, alignment: .topLeading).background(AppPalette.panel)
        let host = NSHostingView(rootView: content.preferredColorScheme(.light))
        host.appearance = NSAppearance(named: .aqua); host.frame = NSRect(x: 0, y: 0, width: width, height: 390)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .windowBackgroundColor; window.contentView = host
        window.makeKeyAndOrderFront(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 30_000_000)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
