import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct NativeEditingInspector: View {
    @ObservedObject var editing: EditingController
    var body: some View {
        VStack(spacing: EditingLayout.panelSpacing) {
            if editing.stage == .development, editing.work != nil, !editing.loading {
                Group {
                    if editing.recipe.sceneGraph != nil {
                        EditingSceneGraphToolbar(editing: editing)
                    } else if EditingCompatibilityGraphPanel.isEnabled {
                        EditingCompatibilityGraphToolbar(editing: editing)
                    }
                }
                .frame(maxWidth: .infinity)
                .floatingSelectionSurface()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editing.rail.nodes")
            }
            inspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .floatingSelectionSurface()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editing.rail.parameters")
        }
        .environment(\.developmentNumberInputOwner, editing.developmentNumberInputOwner)
        .onChange(of: editing.stage) { _, _ in editing.previewContextChanged() }
    }

    @ViewBuilder private var inspector: some View {
        if editing.loading {
            ProgressView("准备照片…").padding()
        } else if editing.work == nil {
            Text("选择资料库中的照片开始编辑。").foregroundStyle(.secondary).padding()
        } else if editing.stage == .development && editing.sourceReady {
            PhotosDevelopmentInspector(editing: editing)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label(editing.selectedVersion?.editingTitle ?? "已有编辑结果", systemImage: "photo")
                    .font(.headline)
                if editing.sourceReady {
                    Button("返回当前编辑") { editing.returnToCurrentEdit() }
                        .accessibilityIdentifier("editing.returnToAdjustments")
                } else {
                    Text("原片当前不可用。可以在「快照」菜单中查看已归档的成片。")
                        .font(.caption).foregroundStyle(.secondary)
                    if editing.sourceNeedsRevalidation {
                        Button(editing.revalidatingSource ? "正在验证原片…" : "重新验证原片") { editing.revalidatePreviewSource() }
                            .disabled(editing.revalidatingSource).accessibilityIdentifier("editing.revalidate")
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EditingJobSummary: View {
    @ObservedObject var editing: EditingController
    let job: ProcessingJob
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(job.state.editingTitle).font(.caption.weight(.semibold))
                Spacer()
                if !job.state.isTerminal && job.state != .outcomeUnknown { ProgressView().controlSize(.small) }
            }
            Text(job.request.profile.displayName + " · " + job.request.profile.model).font(.caption2).foregroundStyle(.secondary)
            Text("实际输入 \(job.request.inputArtifact.pixelWidth) × \(job.request.inputArtifact.pixelHeight) · \(job.request.inputArtifact.bitDepth) 位 · \(job.request.inputArtifact.colorSpace)").font(.caption2).foregroundStyle(.secondary)
            if let quick = job.request.quickPrompt {
                DisclosureGroup("快速 Prompt · \(quick.selection == nil ? "整张当前构图" : "局部范围")") {
                    Text(job.request.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let receipt = job.currentAttempt.receivedOutput?.configuration, let count = receipt["usage.generated_images"] {
                        Text("方舟回执 · 生成 \(count) 张 · \(receipt["usage.output_tokens"] ?? "—") 输出 tokens")
                            .foregroundStyle(.secondary)
                    } else if job.request.profile.kind == .seedream {
                        Text(job.currentAttempt.submissionIntentAt == nil ? "尚未提交方舟" : "方舟用量待核对").foregroundStyle(.secondary)
                    }
                }.font(.caption)
            }
            if let text = editing.jobMessages[job.id]?.message { Text(text).font(.caption2).foregroundStyle(.secondary) }
            if let error = job.currentAttempt.error { Text(error).font(.caption2).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
            HStack {
                if editing.canResumeSaving(job), !job.state.isTerminal {
                    Button("恢复保存") { editing.resumeSaving(job) }
                    Text("不会重新提交生成").font(.caption2).foregroundStyle(.secondary)
                } else if job.state == .outcomeUnknown {
                    Button("核对结果") { editing.reconcile(job) }
                    if job.currentAttempt.workerJoined && job.request.quickPrompt == nil { Button("重新生成…") { editing.unknownRetryJobID = job.id } }
                } else if (job.state == .failed || job.state == .cancelled) && job.currentAttempt.workerJoined && job.request.quickPrompt == nil {
                    Button("重试") { editing.retry(job) }
                } else if !job.state.isTerminal && job.state != .cancelRequested {
                    Button("取消") { editing.cancel(job) }
                }
                if job.request.quickPrompt != nil && job.request.workID == editing.work?.id {
                    Button("回到本张 Prompt") { editing.reopenQuickPromptTask(job) }.disabled(!editing.canOpenQuickPrompt)
                }
                if job.resultVersionID != nil { Text("结果保留为候选").font(.caption2).foregroundStyle(.secondary) }
            }.font(.caption).buttonStyle(.borderless)
            ForEach(job.attempts.filter { $0.id != job.currentAttempt.id && $0.resultVersionID == nil && ($0.receivedOutput != nil || $0.pendingReceivedOutput != nil) }) { attempt in
                HStack {
                    Text("较早尝试 \(attempt.number) · 结果待保存").font(.caption2).foregroundStyle(.secondary)
                    Button("恢复保存") { editing.resumeSaving(job, attemptID: attempt.id) }.font(.caption).buttonStyle(.borderless)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("editing.job." + job.id)
    }
}

struct EditingJobsSheet: View {
    @ObservedObject var editing: EditingController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("制作任务与导出").font(.title2.weight(.semibold)); Spacer(); Button("完成") { editing.showJobs = false }.keyboardShortcut(.cancelAction) }
            Text("任务独立于当前照片。结果保存后仍需检查并明确采用。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if editing.jobs.isEmpty && editing.renderedExports.isEmpty { Text("暂无单张制作任务或导出记录").foregroundStyle(.secondary).padding(.vertical, 24) }
                    WorkbenchDeliveryHistoryList()
                    ForEach(editing.jobs) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("照片 " + String(job.request.source.assetID.prefix(8)) + " · " + job.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            EditingJobSummary(editing: editing, job: job)
                        }
                    }
                    if !editing.renderedExports.isEmpty {
                        Divider().padding(.vertical, 4)
                        HStack { Text("成片导出").font(.headline); Spacer(); Button("核对导出") { editing.reconcileExports() }.font(.caption) }
                        ForEach(editing.renderedExports) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(record.targetURL.lastPathComponent).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(record.state.nativeTitle).font(.caption).foregroundStyle(record.state == .succeeded ? AppPalette.keep : AppPalette.warning)
                                }
                                Text("版本 " + String(record.versionID.prefix(6)) + " · " + record.format.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Text(record.targetURL.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                if let error = record.error { Text(error).font(.caption2).foregroundStyle(AppPalette.warning) }
                                if record.state == .succeeded { Button("在 Finder 中显示") { editing.revealExport(record) }.font(.caption).buttonStyle(.borderless) }
                                else { Button(record.state == .cancelled ? "核对状态" : "核对并恢复保存") { editing.reconcileExports() }.font(.caption).buttonStyle(.borderless) }
                            }.padding(10).background(AppPalette.thumbnailWell, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                }
            }
        }.padding(22).frame(width: 580, height: 580)
    }
}

extension RenderedExportState {
    var nativeTitle: String {
        switch self { case .queued: return "等待渲染"; case .prepared: return "准备发布"; case .succeeded: return "已导出"; case .needsAttention: return "需要核对"; case .cancelled: return "已取消" }
    }
}
