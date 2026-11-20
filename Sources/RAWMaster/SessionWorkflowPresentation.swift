import Foundation
import RAWMasterCore

/// Presentation only: all counters describe the whole intake, never its current subgroup.
struct SessionWorkflowPresentation {
    enum Action: Equatable {
        case continueIntake, pauseIntake, cancelGrouping, cancelQuality, cancelPairing, finish, openProject
        var title: String {
            switch self {
            case .continueIntake: return "继续接入"
            case .pauseIntake: return "暂停接入"
            case .cancelGrouping: return "取消分组"
            case .cancelQuality: return "取消检查"
            case .cancelPairing: return "取消关联检查"
            case .finish: return "完成整批初筛…"
            case .openProject: return "打开项目"
            }
        }
    }
    let sessionID: String
    let title: String
    let stageTitle: String
    let primaryAction: Action
    let primaryEnabled: Bool
    let primaryTitle: String
    let counts: SessionBatchCounts
    let regroupDisabledReason: String?
    let hasCurrentTask: Bool
    let isHistory: Bool
    let activityMessage: String?
    let activityCompleted: Int?
    let activityTotal: Int?
    let groupingOutcomeText: String?

    init(session: ImportSession, workflow: SessionWorkflow?, counts: SessionBatchCounts,
         task: SessionTaskState?, progress: TaskProgress?, qualityMessage: String,
         canContinue: Bool, canFinish: Bool, canOpenProject: Bool, regroupDisabledReason: String?,
         groupingState: AutomaticGroupingRunState? = nil, automaticGroupCount: Int = 0) {
        sessionID = session.id
        let folder = session.effectiveSourceURL.lastPathComponent
        title = folder.isEmpty ? session.projectName : folder
        self.counts = counts; self.regroupDisabledReason = regroupDisabledReason
        isHistory = workflow == nil || workflow?.phase == .closed || workflow?.phase == .legacyHistory
        let currentTask = task.flatMap { $0.sessionID == session.id ? $0 : nil }
        hasCurrentTask = currentTask != nil
        let action: Action
        let enabled: Bool
        if let currentTask {
            switch currentTask.kind {
            case .intake: stageTitle = currentTask.isCancelling ? "正在暂停接入" : "正在接入"; action = .pauseIntake
            case .grouping: stageTitle = currentTask.isCancelling ? "正在取消分组" : "正在分析分组"; action = .cancelGrouping
            case .quality: stageTitle = currentTask.isCancelling ? "正在取消检查" : "正在检查预览风险"; action = .cancelQuality
            case .pairing: stageTitle = currentTask.isCancelling ? "正在取消关联检查" : "正在检查 RAW+JPEG 关联"; action = .cancelPairing
            }
            enabled = !currentTask.isCancelling
            primaryTitle = currentTask.isCancelling ? stageTitle + "…" : action.title
            if currentTask.kind == .quality {
                activityMessage = currentTask.isCancelling ? "取消请求已发送，正在等待当前任务结束。" : qualityMessage
                activityCompleted = nil; activityTotal = nil
            } else {
                activityMessage = currentTask.isCancelling ? "取消请求已发送，正在等待当前任务结束。" : progress?.message
                if let progress, progress.total > 0 {
                    activityCompleted = progress.completed; activityTotal = progress.total
                } else { activityCompleted = nil; activityTotal = nil }
            }
        } else {
            activityMessage = nil; activityCompleted = nil; activityTotal = nil
            if isHistory && (canContinue || workflow?.phase == .legacyHistory && session.status != "completed") {
                stageTitle = "旧版接入未完成"
                action = .continueIntake; enabled = canContinue
            } else if isHistory {
                stageTitle = workflow?.phase == .closed ? "初筛已完成 · 历史只读" : "旧版记录 · 初筛状态未知"
                action = .openProject; enabled = canOpenProject
            } else if session.scanCompleted != true || session.status != "completed" || counts.readyCount != counts.fileCount {
                stageTitle = counts.failedCount > 0 ? "接入需处理" : "接入未完成"
                action = .continueIntake; enabled = canContinue
            } else {
                stageTitle = "待初筛确认"
                action = .finish; enabled = canFinish
            }
            primaryTitle = action.title
        }
        primaryAction = action; primaryEnabled = enabled
        switch groupingState {
        case .applied: groupingOutcomeText = "上次分组完成 · \(automaticGroupCount) 个自动组，待人工复核"
        case .completedNoGroups: groupingOutcomeText = "上次分组完成 · 未识别到新的自动组"
        case .failed: groupingOutcomeText = "上次分组未完成 · 已有拍摄组保留，可重新扫描分组"
        case .cancelled: groupingOutcomeText = "分组已取消 · 已有拍摄组保留"
        case .running: groupingOutcomeText = currentTask?.kind == .grouping ? nil : "上次分组未结束，可重新扫描分组"
        case nil: groupingOutcomeText = nil
        }
    }

    var batchSummary: String {
        var parts = ["整批 \(counts.fileCount) 个文件", "已就绪 \(counts.readyCount)"]
        if counts.failedCount > 0 { parts.append("接入异常 \(counts.failedCount)") }
        if !isHistory {
            parts.append(contentsOf: ["待处理 \(counts.pendingCount)", "通过 \(counts.passedCount)", "排除 \(counts.excludedCount)", "待复核 \(counts.reviewCount)"])
        }
        parts.append("拍摄组 \(counts.groupCount)")
        return parts.joined(separator: " · ")
    }
}

extension AppModel {
    func sessionPresentation(_ session: ImportSession) -> SessionWorkflowPresentation {
        SessionWorkflowPresentation(session: session, workflow: workflows.first { $0.sessionID == session.id },
            counts: sessionBatchCounts(sessionID: session.id), task: sessionTask, progress: progress,
            qualityMessage: qualityAnalysisMessage, canContinue: canContinueIntake(sessionID: session.id),
            canFinish: canFinishSession(sessionID: session.id), canOpenProject: canOpenSessionProject(sessionID: session.id),
            regroupDisabledReason: regroupDisabledReason(sessionID: session.id),
            groupingState: automaticGroupingRun?.state, automaticGroupCount: automaticGroupingRun?.groupIDs.count ?? 0)
    }
}
